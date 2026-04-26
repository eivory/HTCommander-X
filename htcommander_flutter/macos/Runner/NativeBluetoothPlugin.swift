import CoreBluetooth
import FlutterMacOS

/// Native CoreBluetooth control of the Benshi UV-PRO / family.
///
/// This is the macOS port of bendio's BLE side: scan, connect, GATT
/// service / characteristic discovery, write, and indication
/// notifications, all in-process. Replaces the Python subprocess +
/// JSON-RPC stdio bridge for everything except RFCOMM audio (Phase 2
/// will move that too).
///
/// Method channel: `htcommander.macos/ble`
///   - `scan(timeout: Double)` →
///       `[{"id": <CBPeripheral.identifier>, "name": <str>, "rssi": <int>}]`
///   - `connect(deviceUuid: String)` → `{"connected": true}`
///   - `write(bytes: hexString)` → `{}`
///   - `disconnect()` → `{}`
///
/// Event channel: `htcommander.macos/ble_indication` — emits
/// FlutterStandardTypedData chunks for every indication value the
/// peripheral pushes on the radio's indicate characteristic.
class NativeBluetoothPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
                              CBCentralManagerDelegate, CBPeripheralDelegate {

    // The Benshi-family vendor service exposes a write and an indicate
    // characteristic. Same UUIDs bendio's link.py uses.
    private static let serviceUuid =
        CBUUID(string: "00001100-d102-11e1-9b23-00025b00a5a5")
    private static let writeUuid =
        CBUUID(string: "00001101-d102-11e1-9b23-00025b00a5a5")
    private static let indicateUuid =
        CBUUID(string: "00001102-d102-11e1-9b23-00025b00a5a5")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var indicateChar: CBCharacteristic?

    private var indicationSink: FlutterEventSink?
    private var pendingScan: (FlutterResult, [String: [String: Any]])?
    private var scanTimer: Timer?
    private var pendingConnect: FlutterResult?

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = NativeBluetoothPlugin()
        let methodChannel = FlutterMethodChannel(
            name: "htcommander.macos/ble",
            binaryMessenger: registrar.messenger
        )
        registrar.addMethodCallDelegate(plugin, channel: methodChannel)
        let events = FlutterEventChannel(
            name: "htcommander.macos/ble_indication",
            binaryMessenger: registrar.messenger
        )
        events.setStreamHandler(plugin)
        // CBCentralManager dispatches on whatever queue is passed at
        // init; main queue is fine for our throughput (max ~30 msgs/s).
        plugin.central = CBCentralManager(delegate: plugin, queue: nil)
    }

    // MARK: FlutterPlugin
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "scan":
            let args = call.arguments as? [String: Any]
            let timeout = args?["timeout"] as? Double ?? 5.0
            startScan(timeout: timeout, result: result)
        case "connect":
            let args = call.arguments as? [String: Any]
            guard let uid = args?["deviceUuid"] as? String,
                  let uuid = UUID(uuidString: uid) else {
                result(FlutterError(code: "bad_uuid",
                                    message: "deviceUuid is required",
                                    details: nil))
                return
            }
            connect(uuid: uuid, result: result)
        case "write":
            let args = call.arguments as? [String: Any]
            let hex = args?["bytes"] as? String ?? ""
            writeBytes(hex: hex, result: result)
        case "disconnect":
            disconnect()
            result([:])
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: FlutterStreamHandler
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        indicationSink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        indicationSink = nil
        return nil
    }

    // MARK: scan
    private func startScan(timeout: Double, result: @escaping FlutterResult) {
        if central.state != .poweredOn {
            result(FlutterError(code: "ble_off",
                                message: "Bluetooth is off",
                                details: nil))
            return
        }
        var found: [String: [String: Any]] = [:]
        pendingScan = (result, found)
        // No service filter so non-advertising paired devices still
        // show up. The Flutter side filters by the Benshi name list.
        central.scanForPeripherals(withServices: nil, options: nil)
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            self.finishScan()
        }
    }

    private func finishScan() {
        central.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil
        guard let (result, foundDict) = pendingScan else { return }
        pendingScan = nil
        let arr = foundDict.values.map { $0 }
        result(arr)
    }

    // MARK: connect
    private func connect(uuid: UUID, result: @escaping FlutterResult) {
        if let existing = peripheral, existing.identifier == uuid,
           existing.state == .connected {
            result(["connected": true])
            return
        }
        disconnect()
        // retrievePeripherals returns the device by UUID without
        // re-scanning — works if the user has connected to it before.
        let peripherals = central.retrievePeripherals(withIdentifiers: [uuid])
        guard let p = peripherals.first else {
            result(FlutterError(
                code: "not_found",
                message: "No peripheral known by that UUID. " +
                         "Scan first or pair via System Settings.",
                details: nil
            ))
            return
        }
        peripheral = p
        p.delegate = self
        pendingConnect = result
        central.connect(p, options: nil)
    }

    private func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
        indicateChar = nil
    }

    // MARK: write
    private func writeBytes(hex: String, result: @escaping FlutterResult) {
        guard let data = Self.dataFromHex(hex) else {
            result(FlutterError(code: "bad_hex",
                                message: "bytes was not valid hex",
                                details: nil))
            return
        }
        guard let p = peripheral, let ch = writeChar else {
            result(FlutterError(code: "not_connected",
                                message: "Radio not connected",
                                details: nil))
            return
        }
        p.writeValue(data, for: ch, type: .withResponse)
        result([:])
    }

    // MARK: CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Nothing actionable here — pendingScan/connect retry on demand.
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard pendingScan != nil else { return }
        let id = peripheral.identifier.uuidString
        var entry: [String: Any] = [
            "id": id,
            "name": peripheral.name ?? "",
            "rssi": RSSI.intValue,
        ]
        // Mark whether the radio service UUID was advertised — the
        // Dart side uses this to flag known Benshi devices.
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey]
            as? [CBUUID], uuids.contains(Self.serviceUuid) {
            entry["benshi_service"] = true
        }
        pendingScan?.1[id] = entry
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUuid])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        if let cb = pendingConnect {
            pendingConnect = nil
            cb(FlutterError(
                code: "connect_failed",
                message: error?.localizedDescription ?? "connect failed",
                details: nil))
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // If the peripheral drops mid-session, surface a sentinel
        // empty event so the Dart side knows to tear down state.
        // (The existing onDataReceived(error, null) path handles this.)
        if let sink = indicationSink {
            DispatchQueue.main.async {
                sink(FlutterError(
                    code: "disconnected",
                    message: error?.localizedDescription ?? "disconnected",
                    details: nil))
            }
        }
        if peripheral === self.peripheral {
            self.peripheral = nil
            self.writeChar = nil
            self.indicateChar = nil
        }
    }

    // MARK: CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard error == nil, let svc = peripheral.services?.first(
            where: { $0.uuid == Self.serviceUuid }) else {
            failConnect("radio service not found: \(error?.localizedDescription ?? "missing")")
            return
        }
        peripheral.discoverCharacteristics(
            [Self.writeUuid, Self.indicateUuid], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let chars = service.characteristics else {
            failConnect("characteristic discovery failed: \(error?.localizedDescription ?? "missing")")
            return
        }
        for c in chars {
            if c.uuid == Self.writeUuid { writeChar = c }
            if c.uuid == Self.indicateUuid {
                indicateChar = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
        guard writeChar != nil, indicateChar != nil else {
            failConnect("required characteristics missing")
            return
        }
        if let cb = pendingConnect {
            pendingConnect = nil
            cb(["connected": true])
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.indicateUuid,
              let data = characteristic.value, error == nil else { return }
        guard let sink = indicationSink else { return }
        // Hop to the main queue so Flutter event-channel ordering is
        // deterministic — CBPeripheral can deliver on background.
        DispatchQueue.main.async {
            sink(FlutterStandardTypedData(bytes: data))
        }
    }

    private func failConnect(_ message: String) {
        guard let cb = pendingConnect else { return }
        pendingConnect = nil
        cb(FlutterError(code: "connect_failed", message: message, details: nil))
        disconnect()
    }

    // MARK: helpers
    private static func dataFromHex(_ hex: String) -> Data? {
        var bytes = [UInt8]()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return Data(bytes)
    }
}
