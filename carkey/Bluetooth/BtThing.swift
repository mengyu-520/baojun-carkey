import Combine
import CommonCrypto
import CoreBluetooth
import CryptoSwift
import Foundation
import OSLog
import SwiftUI
import SwiftyBluetooth

let loggerBle = Logger(
	subsystem: "com.sleepyshark.carkey",
	category: "ble"
)

// disconnected -> scanning  -> authorizing -> connected
enum BluetoothManagerState {
	case unknown
	case disconnected
	case authorizing
	case connected
	case scanning

	var description: String {
		switch self {
		case .unknown: return "Unknown"
		case .disconnected: return "Disconnected"
		case .authorizing: return "Authorizing"
		case .connected: return "Connected"
		case .scanning: return "Scanning"
		}
	}
}

extension Peripheral: @retroactive Identifiable {
	public var id: String {
		return self.identifier.uuidString
	}
}

struct BleTarget {
	var peripheral: Peripheral
	var authorizeRequestCharacteristic: CBCharacteristic?
	var authorizeResponseCharacteristic: CBCharacteristic?
	var controlRequestCharacteristic: CBCharacteristic?
	var controlResponseCharacteristic: CBCharacteristic?
}

class BluetoothManager: ObservableObject {
	static let shared = BluetoothManager()

	@Published var keyInfo: E300BleKeyInfoModel?
	@Published var avaliblePeripherals = [Peripheral]()
	@Published var target: BleTarget?
	@Published var state: BluetoothManagerState = .disconnected
	@Published var isConnected: Bool = false

	// MARK: 信号数据
	/// 最近一次收到的广播 RSSI（dBm）
	@Published var rssi: Int?
	/// 指数平滑后的 RSSI，用于无感解锁判断，避免抖误触发
	@Published var smoothedRSSI: Double?
	/// 最近 60 次平滑值，界面上画曲线
	@Published var rssiHistory: [Double] = []
	/// 最后一次看到车辆的时间
	@Published var lastSeenAt: Date?
	/// 按信号强度估算的距离（米）
	@Published var estimatedDistance: Double?
	/// 无感流程当前状态
	@Published var autoUnlockState: AutoUnlockState = .idle
	/// 最近一次无感事件描述
	@Published var lastAutoEvent: String?

	// MARK: 无感解锁设置
	@Published var autoUnlockEnabled: Bool = true { didSet { saveAutoUnlockSettings() } }
	/// 触发自动解锁的信号阈值（dBm，越大越靠近）
	@Published var autoUnlockThreshold: Double = -62 { didSet { saveAutoUnlockSettings() } }
	@Published var autoLockEnabled: Bool = false { didSet { saveAutoUnlockSettings() } }
	/// 触发自动上锁的信号阈值（dBm，越小越远）
	@Published var autoLockThreshold: Double = -82 { didSet { saveAutoUnlockSettings() } }

	// MARK: 内部状态
	private var isFound = false
	private var isScanning = false
	private var pendingAutoUnlock = false
	private var didAutoUnlock = false
	private var nearSince: Date?
	private var farSince: Date?
	private var lastConnectAttempt = Date.distantPast
	private var autoTimer: Timer?
	private var rssiPollTimer: Timer?

	private init() {
		loadAutoUnlockSettings()
		startAutoUnlockEngine()
	}
}

extension BluetoothManager {
	func UpdateKey(key: E300BleKeyInfoModel) {
		self.keyInfo = key
		loggerBle.info("key info updated")
	}

	func getState() -> BluetoothManagerState {
		return self.state
	}

	func startScan() {
		// 没有钥匙数据时扫描没有意义，直接跳过
		guard self.keyInfo?.bleMacStr.isEmpty == false else {
			loggerBle.warning("no ble key data, skip scan")
			return
		}
		if self.state == .connected || self.state == .authorizing { return }
		if self.isScanning { return }

		loggerBle.info("scan start")
		self.isScanning = true
		DispatchQueue.main.async {
			self.state = .scanning
		}
		self.isFound = false

		SwiftyBluetooth.scanForPeripherals(
			withServiceUUIDs: nil,
			// allowDuplicates 打开后同一个设备会被重复上报，才能拿到实时 RSSI
			options: [CBCentralManagerScanOptionAllowDuplicatesKey: true],
			timeoutAfter: 8
		) { scanResult in
			switch scanResult {
			case .scanStarted:
				DispatchQueue.main.async {
					self.state = .scanning
				}
			case .scanResult(let peripheral, let advertisementData, let rssi):
				self.onScanMatchCallback(
					peripheral: peripheral,
					advertisementData: advertisementData,
					rssi: rssi
				)
			case .scanStopped(let peripherals, let error):
				loggerBle.info("scan ended")
				self.isScanning = false
				if self.state == .scanning {
					DispatchQueue.main.async {
						self.state = .disconnected
					}
				}
				self.avaliblePeripherals = peripherals
				if let error = error {
					loggerBle.error(
						"Encountered error during scanning: \(error)"
					)
				}
			}
		}
	}

	private func onScanMatchCallback(
		peripheral: Peripheral,
		advertisementData: [String: Any],
		rssi: Int?
	) {
		guard
			let manufacturerData = advertisementData[
				CBAdvertisementDataManufacturerDataKey
			] as? Data,
			let targetMac = self.keyInfo?.bleMacStr,
			targetMac.isEmpty == false
		else {
			return
		}

		let discoveredMac = getMacAddress(from: manufacturerData)
		guard discoveredMac.uppercased() == targetMac.uppercased() else {
			return
		}

		// 同一台车的每一帧广播都拿来做信号统计
		self.recordSignal(rssi)

		guard self.state != .connected,
			  self.state != .authorizing,
			  Date().timeIntervalSince(self.lastConnectAttempt) > 3
		else {
			return
		}

		loggerBle.info("ble mac matched: \(discoveredMac), rssi: \(rssi.map(String.init) ?? "-")")
		self.isFound = true
		self.lastConnectAttempt = Date()
		SwiftyBluetooth.stopScan()

		connectTo(peripheral: peripheral)
	}

	private func connectTo(peripheral: Peripheral) {
		peripheral.connect(withTimeout: 5) { result in
			switch result {
			case .success:
				loggerBle.info(
					"ble connected to \(peripheral.name ?? "unnamed")"
				)
				self.target = BleTarget(peripheral: peripheral)

				NotificationCenter.default.addObserver(
					self,
					selector: #selector(self.peripheralDidDisconnect(_:)),
					name: Peripheral.PeripheralDisconnected,
					object: peripheral
				)

				self.startServiceDiscovery(for: peripheral)

			case .failure(let error):
				loggerBle.error("failed to connect: \(error)")
				DispatchQueue.main.async {
					self.state = .disconnected
				}
			}
		}
	}

	private func startServiceDiscovery(for peripheral: Peripheral) {
		loggerBle.info("starting discovery flow...")
		DispatchQueue.main.async {
			self.state = .authorizing
		}

		peripheral.discoverServices(withUUIDs: nil) { [weak self] result in
			guard let self = self else { return }
			switch result {
			case .success(let services):
				for service in services {
					switch service.uuid {
					case SGMWBLEProfile.AuthorizeService.uuid:
						loggerBle.debug("discovered authorize service")
						self.discoverAuthorizationCharacteristics(
							for: peripheral,
							service: service
						)
					case SGMWBLEProfile.ControlService.uuid:
						loggerBle.debug("discovered control service")
						self.discoverControlCharacteristics(
							for: peripheral,
							service: service
						)
					default:
						loggerBle.debug(
							"discovered unknown service: \(service.uuid); with description: \(service.description)"
						)
					}
				}
			case .failure(let error):
				loggerBle.error(
					"unable to find target services, disconnecting: \(error)"
				)
				self.disconnectPeripheral(peripheral: peripheral)
			}
		}
	}

	private func discoverAuthorizationCharacteristics(
		for peripheral: Peripheral,
		service: CBService
	) {
		peripheral.discoverCharacteristics(
			withUUIDs: nil,
			ofServiceWithUUID: service.uuid
		) { [weak self] result in
			guard let self = self else { return }
			switch result {
			case .success(let characteristics):
				loggerBle.debug("discovered authorization characteristics")
				self.assignCharacteristics(characteristics)
			case .failure(let error):
				loggerBle.error(
					"unable to find target characteristics under authorize service, disconnecting: \(error)"
				)
				self.disconnectPeripheral(peripheral: peripheral)
			}
		}
	}

	private func discoverControlCharacteristics(
		for peripheral: Peripheral,
		service: CBService
	) {
		peripheral.discoverCharacteristics(
			withUUIDs: nil,
			ofServiceWithUUID: service.uuid
		) { [weak self] result in
			guard let self = self else { return }
			switch result {
			case .success(let characteristics):
				loggerBle.debug("discovered control characteristics")
				self.assignCharacteristics(characteristics)
			case .failure(let error):
				loggerBle.error(
					"unable to find target characteristics under control service, disconnecting: \(error)"
				)
				self.disconnectPeripheral(peripheral: peripheral)
			}
		}
	}

	private func assignCharacteristics(_ characteristics: [CBCharacteristic]) {
		for characteristic in characteristics {
			switch characteristic.uuid {
			case SGMWBLEProfile.AuthorizeService.Characteristics.Request
				.CBUUIDRepresentation:
				self.target?.authorizeRequestCharacteristic = characteristic
				loggerBle.debug("got authorizeRequestCharacteristic")
			case SGMWBLEProfile.AuthorizeService.Characteristics.Response
				.CBUUIDRepresentation:
				self.target?.authorizeResponseCharacteristic = characteristic
				loggerBle.debug("got authorizeResponseCharacteristic")
			case SGMWBLEProfile.ControlService.Characteristics.Request
				.CBUUIDRepresentation:
				self.target?.controlRequestCharacteristic = characteristic
				loggerBle.debug("got controlRequestCharacteristic")
			case SGMWBLEProfile.ControlService.Characteristics.Response
				.CBUUIDRepresentation:
				self.target?.controlResponseCharacteristic = characteristic
				loggerBle.debug("got controlResponseCharacteristic")
			default:
				loggerBle.debug(
					"got unknown characteristic: \(characteristic.uuid); with description \(characteristic.description)"
				)
			}
		}
		guard self.target?.authorizeResponseCharacteristic != nil,
			self.target?.authorizeRequestCharacteristic != nil,
			self.target?.controlRequestCharacteristic != nil,
			self.target?.controlResponseCharacteristic != nil
		else { return }
		loggerBle.info("got all characterristics")
		self.setAllNotification()
	}

	private func setAllNotification() {
		guard let target = self.target,
			let authResponseChar = target.authorizeResponseCharacteristic,
			let controlResponseChar = target.controlResponseCharacteristic
		else { return }

		loggerBle.info(
			"enabling notifications for authorization and control..."
		)

		// Register observer BEFORE enabling notifications
		NotificationCenter.default.addObserver(
			forName: Peripheral.PeripheralCharacteristicValueUpdate,
			object: target.peripheral,
			queue: nil,
			using: characteristicValueUpdated(_:)
		)

		// Set notify value for auth
		target.peripheral.setNotifyValue(
			toEnabled: true,
			ofCharac: authResponseChar
		) { [weak self] result in
			guard let self = self else { return }
			switch result {
			case .success(let isNotifying) where isNotifying:
				target.peripheral.setNotifyValue(
					toEnabled: true,
					ofCharac: authResponseChar
				) { [weak self] result in
					guard let self = self else { return }
					switch result {
					case .success(let isNotifying) where isNotifying:
						loggerBle.debug("successfully set notify for authorize")
						// 这里调用鉴权逻辑
						self.sendInitialAuthorizationRequest()
					case .failure(let error):
						loggerBle.error(
							"failed to set notify for authorize: \(error)"
						)
						self.disconnectPeripheral(peripheral: target.peripheral)
					default:
						break
					}
				}
			case .failure(let error):
				loggerBle.error("failed to set notify for authorize: \(error)")
				self.disconnectPeripheral(peripheral: target.peripheral)
			default:
				break
			}
		}

		// Set notify value for control
		target.peripheral.setNotifyValue(
			toEnabled: true,
			ofCharac: controlResponseChar
		) { [weak self] result in
			guard let self = self else { return }
			switch result {
			case .success(let isNotifying) where isNotifying:
				target.peripheral.setNotifyValue(
					toEnabled: true,
					ofCharac: controlResponseChar
				) { [weak self] result in
					guard let self = self else { return }
					switch result {
					case .success(let isNotifying) where isNotifying:
						loggerBle.debug("successfully set notify for control")
					case .failure(let error):
						loggerBle.error(
							"failed to set notify for control: \(error)"
						)
						self.disconnectPeripheral(peripheral: target.peripheral)
					default:
						break
					}
				}
			case .failure(let error):
				loggerBle.error("failed to set notify for control: \(error)")
				self.disconnectPeripheral(peripheral: target.peripheral)
			default:
				break
			}
		}
	}

	// 通知回调
	private func characteristicValueUpdated(_ notification: Notification) {

		// check if notification can be unpack
		guard
			let characteristic = notification.userInfo?["characteristic"]
				as? CBCharacteristic,
			let data = characteristic.value
		else {
			loggerBle.warning(
				"received notification with no characteristic or value"
			)
			return
		}

		loggerBle.debug(
			"received notification for characteristic: \(characteristic.uuid.uuidString)"
		)

		switch characteristic.uuid {
		case SGMWBLEProfile.AuthorizeService.Characteristics.Response
			.CBUUIDRepresentation:
			authorizeRequestCallback(data: data)
		default:
			loggerBle.debug(
				"reecieved a notification from unknown characteristic \(characteristic.uuid.uuidString)"
			)
		}
	}

	// 鉴权回调
	private func authorizeRequestCallback(data: Data) {
		guard var keyInfo = self.keyInfo else {
			loggerBle.error("no valid bt auth key")
			return
		}
		let responseData1 = UcuAuthorizationRequestFrame1(
			dataFrame: data,
			aesKey: keyInfo.authAesKey
		)

		// check service id
		if responseData1.serviceId != "A857" {
			loggerBle.error(
				"a notification with wrong service id \(responseData1.serviceId) is matched into auth"
			)
		}

		switch responseData1.subfunction {
		case "0001":
			loggerBle.info("entered auth stage 1")
			keyInfo.randomData1 = responseData1.random1
			if keyInfo.keyIdHex == responseData1.blekey.UnPadZero() {
				self.keyInfo = keyInfo
				loggerBle.debug(
					"auth stage 1 got random1: \(String(describing: keyInfo.randomData1))"
				)
				self.sendSecondAuthorizationRequest()
			} else {
				loggerBle.error(
					"auth stage 1 got wrong key id: \(String(describing: responseData1.blekey))"
				)
			}
		case "0002":
			loggerBle.info("entered auth stage 2")
			let responseData2 = UcuAuthorizationRequestFrame2(
				dataFrame: data,
				aesKey: keyInfo.authAesKey
			)
			if keyInfo.keyIdHex != responseData2.blekey.UnPadZero() {
				loggerBle.error(
					"auth stage 2 got wrong key id: \(String(describing: responseData2.blekey))"
				)
			}

			// check random2
			if keyInfo.randomData2 == responseData2.random2 {
				loggerBle.debug(
					"auth stage 2 got correct random2 :\(String(describing: keyInfo.randomData2))"
				)
				self.authOK()
			} else {
				loggerBle.error("auth stage 2 got wrong random2")
				self.disconnectPeripheral(peripheral: self.target!.peripheral)
			}

		default:
			loggerBle.warning("got unknown auth subfunction id")
		}

	}

	// step 1
	private func sendInitialAuthorizationRequest() {
		guard let keyInfo = self.keyInfo else {
			loggerBle.error("failed to send intial auth request, no key data")
			return
		}
		guard let target = self.target,
			let requestChar = target.authorizeRequestCharacteristic
		else { return }

		if let payload = keyInfo.GenerateRequest1().ToDataFromHexString() {
			target.peripheral.writeValue(
				ofCharac: requestChar,
				value: payload,
				type: .withResponse
			) { result in
				if case .failure(let error) = result {
					self.disconnectPeripheral(peripheral: target.peripheral)
					loggerBle.error(
						"failed to send initial authorization request: \(error.localizedDescription)"
					)
				} else {
					loggerBle.info(
						"successfully sent initial authorization request."
					)
				}
			}
		}
	}

	// step 2
	private func sendSecondAuthorizationRequest() {
		guard let keyInfo = self.keyInfo else {
			loggerBle.error("failed to send second auth request, no key data")
			return
		}
		guard let target = self.target,
			let requestChar = target.authorizeRequestCharacteristic
		else { return }

		if let payload = keyInfo.GenerateRequest2().ToDataFromHexString() {
			target.peripheral.writeValue(
				ofCharac: requestChar,
				value: payload,
				type: .withResponse
			) { result in
				if case .failure(let error) = result {
					self.disconnectPeripheral(peripheral: target.peripheral)
					loggerBle.error(
						"failed to send second authorization request: \(error.localizedDescription)"
					)
				} else {
					loggerBle.info(
						"successfully sent second authorization request."
					)
				}
			}
		}
	}

	private func authOK() {
		DispatchQueue.main.async {
			self.state = .connected
			self.isConnected = true
		}
		self.keyInfo?.UpdateControlKey()
		let vehicleName = self.target?.peripheral.name ?? "车辆"
		loggerBle.info("\(vehicleName) connected and authorized!")

		self.startRSSIPolling()
		self.handleAuthorized()
	}

	/// 退出登录 / 手动断开时调用
	func disconnectTarget() {
		stopRSSIPolling()
		if let target = self.target {
			target.peripheral.disconnect { _ in
				loggerBle.info("disconnect target on logout")
			}
		}
		self.target = nil
		self.pendingAutoUnlock = false
		self.didAutoUnlock = false
		self.nearSince = nil
		self.farSince = nil
		DispatchQueue.main.async {
			self.state = .disconnected
			self.isConnected = false
			self.autoUnlockState = .idle
		}
	}

	private func disconnectPeripheral(peripheral: Peripheral?) {
		guard let peripheralToDisconnect = peripheral else { return }
		peripheralToDisconnect.disconnect { _ in
			// Actual cleanup is handled by the notification observer
			loggerBle.info(
				"disconnect command sent to \(peripheralToDisconnect.name ?? "unnamed")"
			)
		}
	}

	@objc private func peripheralDidDisconnect(_ notification: Notification) {
		loggerBle.warning("target disconnected by notify")
		DispatchQueue.main.async {
			self.state = .disconnected
			self.isConnected = false
			if self.autoUnlockState == .unlocked || self.autoUnlockState == .unlocking {
				self.autoUnlockState = .idle
			}
		}
		self.isScanning = false
		self.stopRSSIPolling()
		self.target = nil

		if let peripheral = notification.object as? Peripheral {
			NotificationCenter.default.removeObserver(
				self,
				name: Peripheral.PeripheralDisconnected,
				object: peripheral
			)
			NotificationCenter.default.removeObserver(
				self,
				name: Peripheral.PeripheralCharacteristicValueUpdate,
				object: peripheral
			)
		}
	}

	private func getMacAddress(from manufacturerData: Data) -> String {
		guard manufacturerData.count >= 6 else { return "" }
		let macBytes = manufacturerData.suffix(6)
		return macBytes.ToHexEncodedString()
	}
}

// MARK: - 信号统计 + 无感解锁

extension BluetoothManager {

	// MARK: 设置持久化

	func loadAutoUnlockSettings() {
		let defaults = UserDefaults.standard
		if defaults.object(forKey: BleAutoDefaults.enabled) != nil {
			autoUnlockEnabled = defaults.bool(forKey: BleAutoDefaults.enabled)
		}
		if defaults.object(forKey: BleAutoDefaults.unlockThreshold) != nil {
			autoUnlockThreshold = defaults.double(forKey: BleAutoDefaults.unlockThreshold)
		}
		if defaults.object(forKey: BleAutoDefaults.autoLockEnabled) != nil {
			autoLockEnabled = defaults.bool(forKey: BleAutoDefaults.autoLockEnabled)
		}
		if defaults.object(forKey: BleAutoDefaults.autoLockThreshold) != nil {
			autoLockThreshold = defaults.double(forKey: BleAutoDefaults.autoLockThreshold)
		}
	}

	func saveAutoUnlockSettings() {
		let defaults = UserDefaults.standard
		defaults.set(autoUnlockEnabled, forKey: BleAutoDefaults.enabled)
		defaults.set(autoUnlockThreshold, forKey: BleAutoDefaults.unlockThreshold)
		defaults.set(autoLockEnabled, forKey: BleAutoDefaults.autoLockEnabled)
		defaults.set(autoLockThreshold, forKey: BleAutoDefaults.autoLockThreshold)
	}

	// MARK: 信号采样

	/// 记录一帧广播或一次 readRSSI 的原始信号
	func recordSignal(_ rssiValue: Int?) {
		guard let rssiValue = rssiValue, rssiValue < 0 else { return }

		let smooth: Double
		if let previous = smoothedRSSI {
			smooth = previous * 0.7 + Double(rssiValue) * 0.3
		} else {
			smooth = Double(rssiValue)
		}

		let now = Date()
		DispatchQueue.main.async {
			self.rssi = rssiValue
			self.smoothedRSSI = smooth
			self.lastSeenAt = now
			self.estimatedDistance = BleSignal.estimatedDistance(rssi: smooth)

			var history = self.rssiHistory
			history.append(smooth)
			if history.count > 60 {
				history.removeFirst(history.count - 60)
			}
			self.rssiHistory = history
		}
	}

	/// 连接状态下每 2 秒读一次 RSSI（广播在连接后会停发）
	func startRSSIPolling() {
		DispatchQueue.main.async {
			self.rssiPollTimer?.invalidate()
			self.rssiPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
				guard let self = self, let target = self.target else { return }
				target.peripheral.readRSSI { result in
					if case .success(let value) = result {
						self.recordSignal(value)
					}
				}
			}
		}
	}

	func stopRSSIPolling() {
		rssiPollTimer?.invalidate()
		rssiPollTimer = nil
	}

	// MARK: 状态机

	func startAutoUnlockEngine() {
		DispatchQueue.main.async {
			self.autoTimer?.invalidate()
			self.autoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
				self?.autoUnlockTick()
			}
		}
	}

	func stopAutoUnlockEngine() {
		autoTimer?.invalidate()
		autoTimer = nil
	}

	/// 鉴权完成后调用：判断这次连接是不是"靠近触发"的
	func handleAuthorized() {
		guard pendingAutoUnlock else {
			DispatchQueue.main.async {
				if self.autoUnlockState == .connecting || self.autoUnlockState == .idle {
					self.autoUnlockState = .nearby
				}
			}
			return
		}

		pendingAutoUnlock = false
		didAutoUnlock = true
		nearSince = nil

		DispatchQueue.main.async {
			self.autoUnlockState = .unlocked
			self.lastAutoEvent = "\(BluetoothManager.timeString()) 靠近自动解锁"
		}

		// 车端会话刚建立，稍等半秒再下发控制帧更稳
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			self.CarUnlock()
			simpleHaptic(type: .success)
		}
	}

	static func timeString() -> String {
		let formatter = DateFormatter()
		formatter.dateFormat = "HH:mm:ss"
		return formatter.string(from: Date())
	}

	/// 车辆锁止状态：true 已锁 / false 已解锁 / nil 未知
	private func vehicleLockedState() -> Bool? {
		guard let raw = DataManager.shared.appData.carData?.carStatus["doorLockStatus"],
			  raw.isEmpty == false else {
			return nil
		}
		if raw == "1" { return true }
		if raw == "0" { return false }
		return nil
	}

	private func autoUnlockTick() {
		guard DataManager.shared.isLoggedIn,
			  keyInfo?.bleMacStr.isEmpty == false else {
			return
		}

		let now = Date()
		let smooth = smoothedRSSI
		let secondsSinceSeen = lastSeenAt.map { now.timeIntervalSince($0) } ?? 999

		// 已连接：走近就解锁，走远（可选）就上锁
		if state == .connected {
			handleConnectedTick(now: now, smooth: smooth)
			return
		}

		farSince = nil

		guard autoUnlockEnabled else {
			nearSince = nil
			if pendingAutoUnlock {
				pendingAutoUnlock = false
				DispatchQueue.main.async { self.autoUnlockState = .idle }
			}
			return
		}

		// 未连接也要持续扫描，否则拿不到信号就永远不会触发
		if !isScanning, Date().timeIntervalSince(lastConnectAttempt) > 4 {
			startScan()
		}

		guard let currentRSSI = smooth, secondsSinceSeen < 6 else {
			nearSince = nil
			return
		}

		// 阈值 +4 dB 的滞回，避免信号抖动导致反复触发
		if currentRSSI >= autoUnlockThreshold {
			if nearSince == nil { nearSince = now }
			if let since = nearSince, now.timeIntervalSince(since) >= 2 {
				pendingAutoUnlock = true
				DispatchQueue.main.async {
					self.autoUnlockState = .unlocking
				}
			}
		} else if currentRSSI < autoUnlockThreshold - 4 {
			nearSince = nil
			if pendingAutoUnlock {
				pendingAutoUnlock = false
			}
			DispatchQueue.main.async {
				if self.autoUnlockState == .unlocking || self.autoUnlockState == .nearby {
					self.autoUnlockState = .idle
				}
			}
		} else {
			DispatchQueue.main.async {
				if self.autoUnlockState == .idle {
					self.autoUnlockState = .nearby
				}
			}
		}
	}

	private func handleConnectedTick(now: Date, smooth: Double?) {
		guard let currentRSSI = smooth else { return }

		// 1) 靠近解锁
		if autoUnlockEnabled, !didAutoUnlock {
			if currentRSSI >= autoUnlockThreshold {
				if nearSince == nil { nearSince = now }
				if let since = nearSince, now.timeIntervalSince(since) >= 2 {
					// 云端已经知道车是解锁状态就不再重复下发
					if vehicleLockedState() == false {
						DispatchQueue.main.async {
							self.autoUnlockState = .nearby
							self.lastAutoEvent = "车辆已是解锁状态，跳过自动解锁"
						}
					} else {
						didAutoUnlock = true
						nearSince = nil
						CarUnlock()
						DispatchQueue.main.async {
							self.autoUnlockState = .unlocked
							self.lastAutoEvent = "\(BluetoothManager.timeString()) 靠近自动解锁"
						}
						simpleHaptic(type: .success)
					}
				}
			} else if currentRSSI < autoUnlockThreshold - 6 {
				nearSince = nil
			}
		}

		// 2) 远离上锁（默认关闭）
		guard autoLockEnabled, didAutoUnlock, currentRSSI <= autoLockThreshold else {
			farSince = nil
			return
		}

		if farSince == nil { farSince = now }
		if let since = farSince, now.timeIntervalSince(since) >= 10 {
			farSince = nil
			didAutoUnlock = false
			CarLock()
			DispatchQueue.main.async {
				self.autoUnlockState = .idle
				self.lastAutoEvent = "\(BluetoothManager.timeString()) 走远自动上锁"
			}
			simpleHaptic(type: .warning)
			disconnectTarget()
		}
	}
}

// MARK: - Control

extension BluetoothManager {
	// RandomNumber为任意8位hexstring
	func GeneralControl(function: ControlFunctionList, randomNumber: String) {
		guard let keyInfo = self.keyInfo else {
			loggerBle.error("failed to send control request \(randomNumber), no key data")
			return
		}
		guard let target = self.target,
			  let requestChar = target.controlRequestCharacteristic
		else { return }
		
		if let payload = keyInfo.GenerateControlRequest(function: function, randomNum: randomNumber).ToDataFromHexString() {
			target.peripheral.writeValue(
				ofCharac: requestChar,
				value: payload,
				type: .withResponse
			) { result in
				if case .failure(let error) = result {
					loggerBle.error(
						"failed to send control request \(randomNumber) : \(error)"
					)
				} else {
					loggerBle.info(
						"successfully sent control request \(randomNumber)"
					)
				}
			}
		}
	}
	
	func CarLock() {
		// 手动或自动上锁后，重置无感解锁的“本次已解锁”标记，
		// 这样下次靠近还能再次自动解锁
		self.didAutoUnlock = false
		let random = GenerateRandomHex8()
		self.GeneralControl(function: ControlFunctionList.doorLockAll, randomNumber: random)
	}
	
	func CarUnlock() {
		let random = GenerateRandomHex8()
		self.GeneralControl(function: ControlFunctionList.doorUnlockAll, randomNumber: random)
	}
	
	func CarPowerOff() {
		let random = GenerateRandomHex8()
		self.GeneralControl(function: ControlFunctionList.powerOff, randomNumber: random)
	}
}


// MARK: - App/UCU Data Frames

// UCU -> App 的响授权响应帧1
struct UcuAuthorizationRequestFrame1 {
	let serviceId: String, subfunction: String, random1: String, blekey: String

	init(dataFrame: Data, aesKey: Data) {
		do {
			var dataHex: String = dataFrame.toHexString()
			if dataHex[0...1] != "00" {
				loggerBle.error("recieved data not encrypted!")
			}
			dataHex = dataHex[2...]
			loggerBle.debug("recieved data for 1st auth: \(dataHex)")
			let decrypted: [UInt8] = try AES(
				key: Array(aesKey),
				blockMode: ECB(),
				padding: .noPadding
			).decrypt(Array(Data(hex: dataHex)))
			let decryptedString = decrypted.toHexString().uppercased()

			// crc check
			if Data(decrypted).Crc16Checksum() != 0 {
				loggerBle.warning("crc check failed on 1st auth response")
			}
			// payload length check (maybe?)
			if Data(hex: String(decryptedString[32...33])).toHexString() != "01"
			{
				loggerBle.warning(
					"payload length check failed on 1st auth response"
				)
			}

			// 肢解
			let service = decryptedString[0...3]
			let subFunc = decryptedString[4...7]
			let random1 = decryptedString[16...23]
			let blekey = decryptedString[24...31]

			self.serviceId = String(service)
			self.subfunction = String(subFunc)
			self.random1 = String(random1)
			self.blekey = String(blekey)

			return

		} catch {
			loggerBle.error(
				"got unexpected error, probably decrypt error: \(error)"
			)
			self.serviceId = ""
			self.subfunction = ""
			self.random1 = ""
			self.blekey = ""
		}
	}
}

// UCU -> App 的响授权响应帧2
struct UcuAuthorizationRequestFrame2 {
	let serviceId: String, subfunction: String, random2: String, blekey: String

	init(dataFrame: Data, aesKey: Data) {
		do {
			var dataHex: String = dataFrame.toHexString()
			if dataHex[0...1] != "00" {
				loggerBle.error("recieved data not encrypted!")
			}
			dataHex = dataHex[2...]
			loggerBle.debug("recieved data for 2nd auth: \(dataHex)")
			let decrypted: [UInt8] = try AES(
				key: Array(aesKey),
				blockMode: ECB(),
				padding: .noPadding
			).decrypt(Array(Data(hex: dataHex)))
			let decryptedString = decrypted.toHexString().uppercased()

			// crc check
			if Data(decrypted).Crc16Checksum() != 0 {
				loggerBle.warning("crc check failed on 2nd auth response")
			}
			// payload length check (maybe?)
			if Data(hex: String(decryptedString[32...33])).toHexString() != "06"
			{
				loggerBle.warning(
					"payload length check failed on 2nd auth response"
				)
			}

			// 肢解
			let service = decryptedString[0...3]
			let subFunc = decryptedString[4...7]
			let random2 = decryptedString[16...23]
			let blekey = decryptedString[24...31]

			self.serviceId = String(service)
			self.subfunction = String(subFunc)
			self.random2 = String(random2)
			self.blekey = String(blekey)

			return

		} catch {
			loggerBle.error("got unexpected error, probably decrypt error")
			self.serviceId = ""
			self.subfunction = ""
			self.random2 = ""
			self.blekey = ""
		}
	}
}

// MARK: - Debug View (Unaltered)

#if DEBUG
extension BluetoothManager {
	/// 仅用于 CI 模拟器截图：填充一组看起来真实的蓝牙信号数据
	func enableDemoSignal() {
		DispatchQueue.main.async {
			self.autoUnlockEnabled = true
			self.autoUnlockThreshold = -62
			self.autoLockEnabled = false
			self.autoLockThreshold = -82

			let samples: [Double] = [
				-86, -83, -80, -78, -76, -74, -73, -71, -70, -69,
				-67.5, -66.8, -65.2, -64.1, -63.0, -62.4, -61.8, -61.5
			]
			self.rssiHistory = samples
			self.rssi = -61
			self.smoothedRSSI = -61.5
			self.estimatedDistance = BleSignal.estimatedDistance(rssi: -61.5)
			self.lastSeenAt = Date()
			self.autoUnlockState = .nearby
			self.lastAutoEvent = "\(BluetoothManager.timeString()) 已靠近，信号达标"
		}
	}
}
#endif

/// 生成 8 位大写 hex 随机数（必须补零，否则帧内字段会错位）
func GenerateRandomHex8() -> String {
	let value = String(Int.random(in: 0...0xFFFF_FFFF), radix: 16, uppercase: true)
	return String(repeating: "0", count: max(0, 8 - value.count)) + value
}
