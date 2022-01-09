//
//  PeripheralManager.swift
//  xDripG5
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import os.log

class PeripheralManager: NSObject {

    // TODO: Make private
    let log = OSLog(category: "PeripheralManager")

    ///
    /// This is mutable, because CBPeripheral instances can seemingly become invalid, and need to be periodically re-fetched from CBCentralManager
    var peripheral: CBPeripheral {
        didSet {
            guard oldValue !== peripheral else {
                return
            }

            log.error("Replacing peripheral reference %{public}@ -> %{public}@", oldValue, peripheral)

            oldValue.delegate = nil
            peripheral.delegate = self

            queue.sync {
                self.needsConfiguration = true
            }
        }
    }

    var dataQueue: [Data] = []
    var dataEvent: (() -> Void)?
    var cmdQueue: [Data] = []
    var cmdEvent: (() -> Void)?
    let queueLock = NSCondition()

    /// The dispatch queue used to serialize operations on the peripheral
    let queue = DispatchQueue(label: "com.loopkit.PeripheralManager.queue", qos: .unspecified)

    private let sessionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.randallknutson.OmniBLE.OmnipodDevice.sessionQueue"
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    /// The condition used to signal command completion
    let commandLock = NSCondition()

    /// The required conditions for the operation to complete
    private var commandConditions = [CommandCondition]()

    /// Any error surfaced during the active operation
    private var commandError: Error?

    private(set) weak var central: CBCentralManager?

    let configuration: Configuration

    // Confined to `queue`
    private var needsConfiguration = true

    weak var delegate: PeripheralManagerDelegate? {
        didSet {
            queue.sync {
                needsConfiguration = true
            }
        }
    }

    init(peripheral: CBPeripheral, configuration: Configuration, centralManager: CBCentralManager) {
        self.peripheral = peripheral
        self.central = centralManager
        self.configuration = configuration

        super.init()

        peripheral.delegate = self

        // TODO: Commenting out temporarily
        // assertConfiguration()
    }
}


// MARK: - Nested types
extension PeripheralManager {
    struct Configuration {
        var serviceCharacteristics: [CBUUID: [CBUUID]] = [:]
        var notifyingCharacteristics: [CBUUID: [CBUUID]] = [:]
        var valueUpdateMacros: [CBUUID: (_ manager: PeripheralManager) -> Void] = [:]
    }

    enum CommandCondition {
        case notificationStateUpdate(characteristicUUID: CBUUID, enabled: Bool)
        case valueUpdate(characteristic: CBCharacteristic, matching: ((Data?) -> Bool)?)
        case write(characteristic: CBCharacteristic)
        case discoverServices
        case discoverCharacteristicsForService(serviceUUID: CBUUID)
    }
}

protocol PeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic)

    func peripheralManager(_ manager: PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?)

    func peripheralManagerDidUpdateName(_ manager: PeripheralManager)

    func completeConfiguration(for manager: PeripheralManager) throws

    func reconnectLatestPeripheral()
}


// MARK: - Operation sequence management
extension PeripheralManager {
    func configureAndRun(_ block: @escaping (_ manager: PeripheralManager) -> Void) -> (() -> Void) {
        return {
            if !self.needsConfiguration && self.peripheral.services == nil {
                self.log.error("Configured peripheral has no services. Reconfiguring…")
            }

            if self.delegate == nil {
              self.log.error("PeripheralManager delegate is nil")
            }

            /*if self.peripheral.state == .disconnected || self.peripheral.state == .connecting {
              self.log.info("Peripheral is not connected - triggering reconnectLatestPeripheral...")
              // TODO: This might throw... Also - thread-safety?
              if let delegate = self.delegate {
                  delegate.reconnectLatestPeripheral()
              }
            }*/

            if self.needsConfiguration || self.peripheral.services == nil {
                do {
                    try self.applyConfiguration()
                    self.needsConfiguration = false

                    if let delegate = self.delegate {
                        try delegate.completeConfiguration(for: self)
                        self.log.default("Delegate configuration notified")
                    }

                    self.log.default("Peripheral configuration completed")
                } catch let error {
                    self.log.error("Error applying peripheral configuration: %@", String(describing: error))
                    // Will retry
                }
            }

            block(self)
        }
    }

    func perform(_ block: @escaping (_ manager: PeripheralManager) -> Void) {
        queue.async(execute: configureAndRun(block))
    }

    /*func perform(_ block: @escaping (_ manager: PeripheralManager) -> Void) {
        // TODO: Add reconnection dispatch group here!
        if peripheral.state == .disconnected || peripheral.state == .connecting {
            log.info("Peripheral is not connected - triggering reconnectLatestPeripheral...")
            let group = DispatchGroup()
            // TODO: This might throw... Also - thread-safety?
            if let delegate = self.delegate {
                // reconnectLatestPeripheral also handle
                delegate.reconnectLatestPeripheral()
            }
            // Wait for reconnection
            group.enter()
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                if self.peripheral.state == .connected {
                    group.leave()
                    timer.invalidate()
                }
            }
            group.notify(queue: queue) {
                self.queue.async(execute: self.configureAndRun(block))
            }
        } else {
            queue.async(execute: configureAndRun(block))
        }
    }*/

    private func assertConfiguration() {
        /*perform { (_) in
            // Intentionally empty to trigger configuration if necessary
        }*/
        self.runSession(withName: "Assert peripheral configuration") { () in
            // Intentionally empty to trigger configuration if necessary
        }
    }

    private func applyConfiguration(discoveryTimeout: TimeInterval = 2) throws {
        try discoverServices(configuration.serviceCharacteristics.keys.map { $0 }, timeout: discoveryTimeout)

        for service in peripheral.services ?? [] {
            guard let characteristics = configuration.serviceCharacteristics[service.uuid] else {
                // Not all services may have characteristics
                continue
            }

            try discoverCharacteristics(characteristics, for: service, timeout: discoveryTimeout)
        }

        for (serviceUUID, characteristicUUIDs) in configuration.notifyingCharacteristics {
            guard let service = peripheral.services?.itemWithUUID(serviceUUID) else {
                throw PeripheralManagerError.unknownCharacteristic
            }

            for characteristicUUID in characteristicUUIDs {
                guard let characteristic = service.characteristics?.itemWithUUID(characteristicUUID) else {
                    throw PeripheralManagerError.unknownCharacteristic
                }

                guard !characteristic.isNotifying else {
                    continue
                }

                try setNotifyValue(true, for: characteristic, timeout: discoveryTimeout)
            }
        }
    }
}


// MARK: - Synchronous Commands
extension PeripheralManager {
    /// - Throws: PeripheralManagerError
    func runCommand(timeout: TimeInterval, command: () -> Void) throws {
        // Prelude
        dispatchPrecondition(condition: .onQueue(queue))
        guard central?.state == .poweredOn && peripheral.state == .connected else {
            self.log.info("runCommand guard failed - bluetooth not running or peripheral not connected: peripheral %@", peripheral)
            throw PeripheralManagerError.notReady
        }

        commandLock.lock()

        defer {
            commandLock.unlock()
        }

        guard commandConditions.isEmpty else {
            throw PeripheralManagerError.emptyValue
        }

        // Run
        command()

        guard !commandConditions.isEmpty else {
            // If the command didn't add any conditions, then finish immediately
            return
        }

        // Postlude
        let signaled = commandLock.wait(until: Date(timeIntervalSinceNow: timeout))

        defer {
            commandError = nil
            commandConditions = []
        }

        guard signaled else {
            self.log.info("runCommand lock timeout reached - not signalled")
            throw PeripheralManagerError.notReady
        }

        if let error = commandError {
            throw PeripheralManagerError.cbPeripheralError(error)
        }
    }

    /// It's illegal to call this without first acquiring the commandLock
    ///
    /// - Parameter condition: The condition to add
    func addCondition(_ condition: CommandCondition) {
        dispatchPrecondition(condition: .onQueue(queue))
        commandConditions.append(condition)
    }

    func discoverServices(_ serviceUUIDs: [CBUUID], timeout: TimeInterval) throws {
        let servicesToDiscover = peripheral.servicesToDiscover(from: serviceUUIDs)

        guard servicesToDiscover.count > 0 else {
            return
        }

        try runCommand(timeout: timeout) {
            addCondition(.discoverServices)

            peripheral.discoverServices(serviceUUIDs)
        }
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID], for service: CBService, timeout: TimeInterval) throws {
        let characteristicsToDiscover = peripheral.characteristicsToDiscover(from: characteristicUUIDs, for: service)

        guard characteristicsToDiscover.count > 0 else {
            return
        }

        try runCommand(timeout: timeout) {
            addCondition(.discoverCharacteristicsForService(serviceUUID: service.uuid))

            peripheral.discoverCharacteristics(characteristicsToDiscover, for: service)
        }
    }

    /// - Throws: PeripheralManagerError
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            addCondition(.notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: enabled))

            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    /// - Throws: PeripheralManagerError
    func readValue(for characteristic: CBCharacteristic, timeout: TimeInterval) throws -> Data? {
        try runCommand(timeout: timeout) {
            addCondition(.valueUpdate(characteristic: characteristic, matching: nil))

            peripheral.readValue(for: characteristic)
        }

        return characteristic.value
    }

    /// - Throws: PeripheralManagerError
//    func wait(for characteristic: CBCharacteristic, timeout: TimeInterval) throws -> Data {
//        try runCommand(timeout: timeout) {
//            addCondition(.valueUpdate(characteristic: characteristic, matching: nil))
//        }
//
//        guard let value = characteristic.value else {
//            throw PeripheralManagerError.timeout
//        }
//
//        return value
//    }

    /// - Throws: PeripheralManagerError
    func writeValue(_ value: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType, timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            if case .withResponse = type {
                addCondition(.write(characteristic: characteristic))
            }

            peripheral.writeValue(value, for: characteristic, type: type)
        }
    }
}

extension PeripheralManager {
    public override var debugDescription: String {
        var items = [
            "## PeripheralManager",
            "peripheral: \(peripheral)",
        ]
        queue.sync {
            items.append("needsConfiguration: \(needsConfiguration)")
        }
        return items.joined(separator: "\n")
    }
}

// MARK: - Delegate methods executed on the central's queue
extension PeripheralManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .discoverServices = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .discoverCharacteristicsForService(serviceUUID: service.uuid) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: characteristic.isNotifying) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .write(characteristic: characteristic) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()

        var notifyDelegate = false

        if let macro = configuration.valueUpdateMacros[characteristic.uuid] {
            macro(self)
        }

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .valueUpdate(characteristic: characteristic, matching: let matching) = condition {
                return matching?(characteristic.value) ?? true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        } else if commandConditions.isEmpty {
            notifyDelegate = true // execute after the unlock
        }

        commandLock.unlock()

        if notifyDelegate {
            // If we weren't expecting this notification, pass it along to the delegate
            delegate?.peripheralManager(self, didUpdateValueFor: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        delegate?.peripheralManager(self, didReadRSSI: RSSI, error: error)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        delegate?.peripheralManagerDidUpdateName(self)
    }
}


extension PeripheralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        self.log.debug("PeripheralManager - centralManagerDidUpdateState: %@", central)
        switch central.state {
        case .poweredOn:
            self.log.debug("PeripheralManager - centralManagerDidUpdateState - running assertConfiguration")
            if peripheral.state != .connected {
                sessionQueue.isSuspended = true
            }
            if peripheral.state == .connected {
                sessionQueue.isSuspended = false
                assertConfiguration()
            }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // Clear the queue in case of connection error
        sessionQueue.cancelAllOperations()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.log.debug("PeripheralManager - didConnect: %@", peripheral)
        switch peripheral.state {
        case .connected:
            self.log.debug("PeripheralManager - didConnect - resuming sessionQueue")
            sessionQueue.isSuspended = false
            self.log.debug("PeripheralManager - didConnect - running assertConfiguration")
            assertConfiguration()
        default:
            break
        }
    }
}

extension CBPeripheral {
    func getCommandCharacteristic() -> CBCharacteristic? {
        guard let service = services?.itemWithUUID(OmnipodServiceUUID.service.cbUUID) else {
            return nil
        }

        return service.characteristics?.itemWithUUID(OmnipodCharacteristicUUID.command.cbUUID)
    }

    func getDataCharacteristic() -> CBCharacteristic? {
        guard let service = services?.itemWithUUID(OmnipodServiceUUID.service.cbUUID) else {
            return nil
        }

        return service.characteristics?.itemWithUUID(OmnipodCharacteristicUUID.data.cbUUID)
    }
}

// MARK: - Command session management
extension PeripheralManager {
    public func runSession(withName name: String , _ block: @escaping () -> Void) {
        self.log.default("Scheduling session %{public}@", name)

        // TODO: What about .disconnecting?
        if self.peripheral.state == .disconnected || self.peripheral.state == .connecting {
            sessionQueue.isSuspended = true
            self.log.info("runSession - Peripheral is not connected...")
            if self.peripheral.state == .disconnected {
                if let delegate = self.delegate {
                    self.log.debug("runSession - Peripheral is not connected - triggering reconnectLatestPeripheral...")
                    delegate.reconnectLatestPeripheral()
                }
            }
        }

        sessionQueue.addOperation({ [weak self] in
            self?.perform { (manager) in
                manager.log.default("======================== %{public}@ ===========================", name)
                block()
                manager.log.default("------------------------ %{public}@ ---------------------------", name)
            }
        })
    }
}
