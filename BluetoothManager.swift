import Foundation
import CoreBluetooth
import Combine

final class BluetoothManager: NSObject, ObservableObject {
    // HM-10 BLE UART service/characteristic IDs.
    private let hm10ServiceUUID = CBUUID(string: "FFE0")
    private let hm10CharacteristicUUID = CBUUID(string: "FFE1")

    // State the UI observes.
    @Published private(set) var isBluetoothReady = false
    @Published private(set) var isConnected = false
    @Published private(set) var peripheralName = ""
    @Published private(set) var lastStatusMessage = ""

    // BLE runtime objects.
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var rxBuffer = ""

    override init() {
        super.init()
        // Use main queue so published UI state updates stay simple.
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // Starts discovery for HM-10 peripherals.
    func startScan() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [hm10ServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    // Manual disconnect, usually for debugging/recovery.
    func disconnect() {
        guard let targetPeripheral else { return }
        central.cancelPeripheralConnection(targetPeripheral)
    }

    // Sends one newline-delimited command to Arduino.
    func sendCommand(_ command: String) {
        guard let targetPeripheral, let commandCharacteristic else { return }
        let payload = "\(command)\n"
        guard let data = payload.data(using: .utf8) else { return }

        let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        targetPeripheral.writeValue(data, for: commandCharacteristic, type: writeType)
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    // Tracks adapter power state and restarts scan if possible.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isBluetoothReady = central.state == .poweredOn
        if central.state == .poweredOn {
            startScan()
        } else {
            isConnected = false
            peripheralName = ""
            targetPeripheral = nil
            commandCharacteristic = nil
        }
    }

    // Connects to first matching HM-10 by name or service UUID.
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        if let name = peripheral.name?.lowercased(), name.contains("hm-10") || name.contains("hmsoft") {
            central.stopScan()
            targetPeripheral = peripheral
            peripheralName = peripheral.name ?? "Unknown"
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            return
        }

        // Accept peripherals advertising HM-10 BLE service UUID.
        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID], services.contains(hm10ServiceUUID) {
            central.stopScan()
            targetPeripheral = peripheral
            peripheralName = peripheral.name ?? "Unknown"
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    // After connect, discover services for command channel.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        peripheralName = peripheral.name ?? "Unknown"
        peripheral.discoverServices([hm10ServiceUUID])
    }

    // Auto-recover by re-scanning when disconnected.
    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        isConnected = false
        commandCharacteristic = nil
        targetPeripheral = nil
        startScan()
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    // Discover all characteristics under each service.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    // Pick a characteristic that can write and ideally notify.
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            let supportsWrite = characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse)
            let supportsNotify = characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)

            if characteristic.uuid == hm10CharacteristicUUID || (supportsWrite && supportsNotify) {
                commandCharacteristic = characteristic
                if supportsNotify {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else if supportsNotify {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    // Parse incoming newline-delimited status messages.
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil,
              let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else { return }

        rxBuffer += text
        let lines = rxBuffer.components(separatedBy: "\n")
        rxBuffer = lines.last ?? ""

        for line in lines.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lastStatusMessage = trimmed
        }
    }
}
