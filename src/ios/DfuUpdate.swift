import iOSDFULibrary
import CoreBluetooth

@objc(DfuUpdate) class DfuUpdate : CDVPlugin, CBCentralManagerDelegate, DFUServiceDelegate, DFUProgressDelegate {

    var dfuCallbackId: String?
    var manager: CBCentralManager!
    var dfuController: DFUServiceController?

    @objc(pluginInitialize)
    override func pluginInitialize() {
        super.pluginInitialize()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Envoi des résultats

    private func send(_ result: CDVPluginResult, keepCallback: Bool = false, to callbackId: String? = nil) {
        guard let id = callbackId ?? dfuCallbackId else {
            return
        }
        result.setKeepCallbackAs(keepCallback)
        commandDelegate.send(result, callbackId: id)
    }

    private func error(_ message: String) -> CDVPluginResult {
        return CDVPluginResult(status: CDVCommandStatus.error, messageAs: message)
    }

    // MARK: - Point d'entrée

    @objc(updateFirmware:)
    func updateFirmware(command: CDVInvokedUrlCommand) {
        commandDelegate.run {
            self.dfuCallbackId = command.callbackId

            guard let options = command.argument(at: 0) as? NSDictionary else {
                self.send(self.error("The first Argument must be the Configuration"))
                return
            }

            let deviceId = options.value(forKey: "deviceId") as? String ?? ""
            let fileURL = options.value(forKey: "fileUrl") as? String ?? ""
            let packetReceiptNotificationsValue = options.value(forKey: "packetReceiptNotificationsValue") as? NSInteger ?? 10

            if deviceId.isEmpty {
                self.send(self.error("Device id is required"))
                return
            }

            if fileURL.isEmpty {
                self.send(self.error("File URL is required"))
                return
            }

            guard let sourceURL = self.getURI(url: fileURL) else {
                self.send(self.error("Invalid file URL: " + fileURL))
                return
            }

            let (result, keep) = self.startUpgrade(
                deviceId: deviceId,
                url: sourceURL,
                packetReceiptNotificationsValue: packetReceiptNotificationsValue
            )
            self.send(result, keepCallback: keep)
        }
    }

    func startUpgrade(deviceId: String, url: URL, packetReceiptNotificationsValue: NSInteger) -> (CDVPluginResult, Bool) {
        var waited = 0
        while manager.state != .poweredOn && waited < 30 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
        if manager.state != .poweredOn {
            return (error("Bluetooth not ready"), false)
        }

        guard let selectedFirmware = DFUFirmware(urlToZipFile: url) else {
            return (error("Firmware could not be read at " + url.path), false)
        }

        if !selectedFirmware.valid {
            return (error("Invalid firmware"), false)
        }

        guard let deviceUUID = UUID(uuidString: deviceId) else {
            return (error("Address " + deviceId + " is not a valid UUID"), false)
        }

        let peripherals = manager.retrievePeripherals(withIdentifiers: [deviceUUID])
        guard let target = peripherals.first else {
            return (error("Device with address " + deviceId + " not found"), false)
        }

        let initiator = DFUServiceInitiator(queue: DispatchQueue(label: "Other"))

        initiator.enableUnsafeExperimentalButtonlessServiceInSecureDfu = true
        initiator.packetReceiptNotificationParameter = UInt16(packetReceiptNotificationsValue)
        initiator.forceDfu = false
        initiator.dataObjectPreparationDelay = 0.3
        initiator.delegate = self
        initiator.progressDelegate = self

        dfuController = initiator.with(firmware: selectedFirmware).start(target: target)

        let started = CDVPluginResult(
            status: CDVCommandStatus.ok,
            messageAs: deviceId + ":" + url.absoluteString
        )
        return (started, true)
    }

    // MARK: - Délégués DFU

    func dfuStateDidChange(to state: DFUState) {
        var stateStr = "unknown"
        switch state {
        case .connecting: stateStr = "deviceConnecting"
        case .starting: stateStr = "dfuProcessStarting"
        case .enablingDfuMode: stateStr = "enablingDfuMode"
        case .uploading: stateStr = "firmwareUploading"
        case .validating: stateStr = "firmwareValidating"
        case .disconnecting: stateStr = "deviceDisconnecting"
        case .completed: stateStr = "dfuCompleted"
        case .aborted: stateStr = "dfuAborted"
        @unknown default: stateStr = "unknown"
        }

        let finished = state == .aborted || state == .completed
        send(
            CDVPluginResult(status: CDVCommandStatus.ok, messageAs: ["status": stateStr]),
            keepCallback: !finished
        )

        if finished {
            clearHandlers()
        }
    }

    func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        send(
            CDVPluginResult(
                status: CDVCommandStatus.error,
                messageAs: [
                    "message": message,
                    "errorMessage": message,
                    "error": error.rawValue,
                    "status": "dfuAborted"
                ]
            )
        )
        clearHandlers()
    }

    func dfuProgressDidChange(for part: Int, outOf totalParts: Int, to progress: Int, currentSpeedBytesPerSecond: Double, avgSpeedBytesPerSecond: Double) {
        let message: [String: Any] = [
            "status": "progressChanged",
            "progress": [
                "percent": progress,
                "speed": currentSpeedBytesPerSecond,
                "avgSpeed": avgSpeedBytesPerSecond,
                "currentPart": part,
                "partsTotal": totalParts
            ]
        ]

        send(CDVPluginResult(status: CDVCommandStatus.ok, messageAs: message), keepCallback: true)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
    }

    func clearHandlers() {
        dfuCallbackId = nil
        dfuController = nil
        pluginInitialize()
    }

    // MARK: - Résolution du fichier

    func getURI(url: String) -> URL? {
        if url.hasPrefix("cdvfile://") {
            return nil
        }

        if url.hasPrefix("file://") {
            if let direct = URL(string: url) {
                return direct
            }
            return URL(fileURLWithPath: url.replacingOccurrences(of: "file://", with: ""))
        }

        if url.hasPrefix("/") {
            return URL(fileURLWithPath: url)
        }

        return URL(string: url)
    }
}
