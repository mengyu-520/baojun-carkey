//
//  Data.swift
//  carkey
//
//  Created by Shilapi Chen on 9/11/25.
//  Reworked: tolerant decoding so 云海/云朵 等车型返回字段缺失也不会整体解析失败。
//

import Foundation
import SwiftUI
import Combine
import OSLog

let loggerData = Logger(
    subsystem: "com.sleepyshark.carkey",
    category: "data"
)

// MARK: - 数据结构

struct UserData: Codable {
    var userName: String
    var accessToken: String
    var clientSecret: String
    var userID: String
    /// 登录后绑定到的车辆 VIN
    var vin: String? = nil
}

struct CarKeyAPIResponse: Decodable {
    let result: Bool
    let data: CarKeyData
    let systemDate: String?
    let systemTimeMillis: Int64?
}

struct CarKeyData: Codable {
    var collectTime: String
    var keyId: String
    var keyType: String
    var keyMasterRandom: String
    var masterKey: String
    var bleMac: String
    var endTime: String
    var userId: String
    var vin: String

    private enum CodingKeys: String, CodingKey {
        case collectTime, keyId, keyType, keyMasterRandom, masterKey
        case bleMac, endTime, userId, vin
    }

    init(collectTime: String = "",
         keyId: String = "",
         keyType: String = "",
         keyMasterRandom: String = "",
         masterKey: String = "",
         bleMac: String = "",
         endTime: String = "",
         userId: String = "",
         vin: String = "") {
        self.collectTime = collectTime
        self.keyId = keyId
        self.keyType = keyType
        self.keyMasterRandom = keyMasterRandom
        self.masterKey = masterKey
        self.bleMac = bleMac
        self.endTime = endTime
        self.userId = userId
        self.vin = vin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collectTime = (try? container.decode(String.self, forKey: .collectTime)) ?? ""
        keyId = CarKeyData.stringValue(container, key: .keyId)
        keyType = (try? container.decode(String.self, forKey: .keyType)) ?? ""
        keyMasterRandom = (try? container.decode(String.self, forKey: .keyMasterRandom)) ?? ""
        masterKey = (try? container.decode(String.self, forKey: .masterKey)) ?? ""
        bleMac = (try? container.decode(String.self, forKey: .bleMac)) ?? ""
        endTime = (try? container.decode(String.self, forKey: .endTime)) ?? ""
        userId = CarKeyData.stringValue(container, key: .userId)
        vin = (try? container.decode(String.self, forKey: .vin)) ?? ""
    }

    /// keyId 有时是数字有时是字符串，统一转成字符串
    private static func stringValue(_ container: KeyedDecodingContainer<CodingKeys>,
                                    key: CodingKeys) -> String {
        if let s = try? container.decode(String.self, forKey: key) { return s }
        if let i = try? container.decode(Int64.self, forKey: key) { return String(i) }
        if let d = try? container.decode(Double.self, forKey: key) { return String(Int64(d)) }
        return ""
    }

    var collectDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: collectTime)
    }

    var bleMacString: String {
        return bleMac
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
    }
}

struct VehicleAPIResponse: Decodable {
    let result: Bool
    let data: CarData
    let systemDate: String?
    let systemTimeMillis: Int64?
}

// MARK: - 车辆数据（宽松解码）

/// 兼容字符串 / 数字 / 布尔 / null 的标量值
enum FlexValue: Codable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(String.self) {
            self = .text(value)
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var text: String {
        switch self {
        case .text(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "1" : "0"
        case .null: return ""
        }
    }

    var intValue: Int? { Int(text) }
    var doubleValue: Double? { Double(text) }
}

/// 车辆状态：按字典存，任何字段缺失都不影响解码
struct CarStatus: Codable {
    private var values: [String: FlexValue]

    static let empty = CarStatus()

    init() {
        values = [:]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: FlexValue].self) {
            values = dict
        } else {
            values = [:]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    /// 原始字段访问：carStatus["batterySoc"]
    subscript(key: String) -> String {
        return values[key]?.text ?? ""
    }

    // 界面上用得到的派生值
    var statusName: String { self["statusName"].isEmpty ? self["statusToast"] : self["statusName"] }
    var batterySOCPercentage: Int? { Int(self["batterySoc"]) }
    var remainingMileage: Int? { Int(self["leftMileage"]) }
    var totalMileage: Int? { Int(self["mileage"]) }
    var interiorTemp: Double? { Double(self["interiorTemperature"]) }
    var batteryHealth: Int? { Int(self["batSOH"]) }
    var isLocked: Bool { self["doorLockStatus"] == "1" }
    var isCharging: Bool { self["charging"] == "1" || self["vecChrgingSts"] == "1" }
    var isACOn: Bool { self["acStatus"] == "1" }
    var isDoorOpen: Bool { self["doorOpenStatus"] == "1" || self["tailDoorOpenStatus"] == "1" }
    var isWindowOpen: Bool {
        return self["windowStatus"] == "1"
            || self["window1Status"] == "1"
            || self["window2Status"] == "1"
            || self["window3Status"] == "1"
            || self["window4Status"] == "1"
    }
    var isPoweredOn: Bool { self["accActPos"] != "0" && self["accActPos"].isEmpty == false }
    var latitudeValue: Double? { Double(self["latitude"]) }
    var longitudeValue: Double? { Double(self["longitude"]) }
    var collectTime: String { self["collectTime"] }
}

struct CarInfo: Codable {
    var vin: String
    var carName: String
    var carTypeName: String
    var model: String
    var level: String
    var colorName: String
    var carPlate: String
    var image: String
    var bleType: Int
    var bindCarUserMobile: String
    var supportMqtt: Int

    static let empty = CarInfo()

    init(vin: String = "",
         carName: String = "",
         carTypeName: String = "",
         model: String = "",
         level: String = "",
         colorName: String = "",
         carPlate: String = "",
         image: String = "",
         bleType: Int = 0,
         bindCarUserMobile: String = "",
         supportMqtt: Int = 0) {
        self.vin = vin
        self.carName = carName
        self.carTypeName = carTypeName
        self.model = model
        self.level = level
        self.colorName = colorName
        self.carPlate = carPlate
        self.image = image
        self.bleType = bleType
        self.bindCarUserMobile = bindCarUserMobile
        self.supportMqtt = supportMqtt
    }

    private enum CodingKeys: String, CodingKey {
        case vin, carName, carTypeName, model, level, colorName
        case carPlate, image, bleType, bindCarUserMobile, supportMqtt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vin = (try? container.decode(String.self, forKey: .vin)) ?? ""
        carName = (try? container.decode(String.self, forKey: .carName)) ?? ""
        carTypeName = (try? container.decode(String.self, forKey: .carTypeName)) ?? ""
        model = (try? container.decode(String.self, forKey: .model)) ?? ""
        level = (try? container.decode(String.self, forKey: .level)) ?? ""
        colorName = (try? container.decode(String.self, forKey: .colorName)) ?? ""
        carPlate = (try? container.decode(String.self, forKey: .carPlate)) ?? ""
        image = (try? container.decode(String.self, forKey: .image)) ?? ""
        bleType = (try? container.decode(Int.self, forKey: .bleType)) ?? 0
        bindCarUserMobile = (try? container.decode(String.self, forKey: .bindCarUserMobile)) ?? ""
        supportMqtt = (try? container.decode(Int.self, forKey: .supportMqtt)) ?? 0
    }

    var displayName: String {
        if !carName.isEmpty { return carName }
        if !carTypeName.isEmpty { return carTypeName }
        return "我的宝骏"
    }
}

struct CarData: Codable {
    let carStatus: CarStatus
    let carInfo: CarInfo
    var updateDate: String

    private enum CodingKeys: String, CodingKey {
        case carStatus, carInfo, updateDate
    }

    init(carStatus: CarStatus = .empty, carInfo: CarInfo = .empty) {
        self.carStatus = carStatus
        self.carInfo = carInfo
        self.updateDate = Date().formatted(date: .numeric, time: .standard)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        carStatus = (try? container.decode(CarStatus.self, forKey: .carStatus)) ?? .empty
        carInfo = (try? container.decode(CarInfo.self, forKey: .carInfo)) ?? .empty
        updateDate = Date().formatted(date: .numeric, time: .standard)
    }

    // 兼容原有调用
    var displayDate: String { updateDate }
}

// MARK: - 本地持久化

struct AppData: Codable {
    var userData: UserData?
    var carKeyData: CarKeyData?
    var carData: CarData?
    var tirePressure: TirePressure?
}

/// 胎压（单位 kPa），取自 /junApi/sgmw/car/info/tire/pressure
struct TirePressure: Codable, Equatable {
    var lf: Double?
    var rf: Double?
    var lr: Double?
    var rr: Double?
    var temp: Double?

    init(lf: Double? = nil, rf: Double? = nil, lr: Double? = nil, rr: Double? = nil, temp: Double? = nil) {
        self.lf = lf
        self.rf = rf
        self.lr = lr
        self.rr = rr
        self.temp = temp
    }

    var hasValue: Bool {
        [lf, rf, lr, rr].contains { $0 != nil }
    }
}

class DataManager: ObservableObject {

    static let shared = DataManager()

    @Published var appData: AppData {
        didSet {
            save()
        }
    }

    let sgmwUnifiedOAuth = SGMWUnifiedOAuth()

    private static func archiveURL() -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDirectory.appendingPathComponent("UserData").appendingPathExtension("json")
    }

    private init() {
        guard let data = try? Data(contentsOf: DataManager.archiveURL()) else {
            self.appData = AppData()
            loggerData.error("failed to load local user data: not exist")
            return
        }
        do {
            let decoder = JSONDecoder()
            self.appData = try decoder.decode(AppData.self, from: data)
            guard let userData = self.appData.userData else {
                loggerData.error("failed to load user data for SGMWOAuth")
                return
            }
            self.sgmwUnifiedOAuth.updateToken(accessToken: userData.accessToken, clientSecret: userData.clientSecret)
            loggerData.debug("SGMWOAuth token loaded")
            updateKeyDataToBtKeyModel()
            loggerData.debug("BLE key data loaded")
        } catch {
            loggerData.error("failed to decode AppData: \(error.localizedDescription)")
            self.appData = AppData()
            return
        }
        loggerData.debug("load local user data successfully")
    }

    var isLoggedIn: Bool {
        return appData.userData != nil
    }

    var vin: String {
        if let vin = appData.userData?.vin, vin.isEmpty == false { return vin }
        return appData.carData?.carInfo.vin ?? ""
    }
}

extension DataManager {

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(appData)
            try data.write(to: DataManager.archiveURL())
            loggerData.debug("save local user data successfully")
        } catch {
            loggerData.error("failed to save local user data: \(error.localizedDescription)")
        }
    }

    func login(userName: String, accessToken: String, clientSecret: String, userID: String, vin: String? = nil) {
        let newUser = UserData(userName: userName, accessToken: accessToken, clientSecret: clientSecret, userID: userID, vin: vin)
        DispatchQueue.main.async {
            self.appData.userData = newUser
            loggerData.info("logged in as \(newUser.userID)")
        }
        sgmwUnifiedOAuth.updateToken(accessToken: newUser.accessToken, clientSecret: newUser.clientSecret)
    }

    func bindVehicle(vin: String) {
        DispatchQueue.main.async {
            self.appData.userData?.vin = vin
        }
    }

    func logout() {
        DispatchQueue.main.async {
            self.appData.userData = nil
            self.appData.carKeyData = nil
            self.appData.carData = nil
        }
        sgmwUnifiedOAuth.clearToken()
        BluetoothManager.shared.disconnectTarget()
        WatchSyncManager.shared.sendAppData(AppData())
        loggerData.info("logged out")
    }

    /// 从JSON加载并更新蓝牙密钥数据
    func loadKeyData(from jsonString: String) {
        guard let jsonData = jsonString.data(using: .utf8) else { return }
        do {
            let apiResponse = try JSONDecoder().decode(CarKeyAPIResponse.self, from: jsonData)
            guard apiResponse.result else {
                loggerData.error("failed to load BLE key: server returned false")
                return
            }
            self.appData.carKeyData = apiResponse.data
            updateKeyDataToBtKeyModel()
            loggerData.debug("BLE key data loaded for VIN: \(apiResponse.data.vin)")
            WatchSyncManager.shared.sendAppData(self.appData)
        } catch {
            loggerData.error("failed to load BLE key: \(error)")
        }
    }

    func updateKeyDataToBtKeyModel() {
        guard let keyData = self.appData.carKeyData,
              keyData.masterKey.isEmpty == false,
              keyData.keyMasterRandom.isEmpty == false,
              keyData.bleMac.isEmpty == false else {
            loggerData.error("failed to update key data to ble key model")
            return
        }
        let keyInfo = E300BleKeyInfoModel(
            bleMac: keyData.bleMac,
            keyId: keyData.keyId,
            masterKey: keyData.masterKey,
            keyMasterRandom: keyData.keyMasterRandom
        )
        BluetoothManager.shared.UpdateKey(key: keyInfo)
    }

    /// 从JSON加载并更新车辆综合数据
    func loadCarData(from jsonString: String) {
        guard let jsonData = jsonString.data(using: .utf8) else {
            loggerData.error("failed to parse car data json")
            return
        }

        do {
            let apiResponse = try JSONDecoder().decode(VehicleAPIResponse.self, from: jsonData)
            guard apiResponse.result else {
                loggerData.error("API returned false")
                return
            }
            DispatchQueue.main.async {
                self.appData.carData = apiResponse.data
                loggerData.debug("successfully load car data for \(apiResponse.data.carInfo.displayName)")
            }
            WatchSyncManager.shared.sendAppData(self.appData)
        } catch {
            loggerData.error("failed to parse car data json: \(error)")
        }
    }
}
