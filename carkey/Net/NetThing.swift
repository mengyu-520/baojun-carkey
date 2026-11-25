//
//  NetThing.swift
//  carkey
//
//  Created by Shilapi Chen on 9/8/25.
//  Reworked: 使用宝骏 openapi 的签名接口 + 登录/短信验证码。
//

import Foundation
import UIKit
import CoreLocation
import OSLog

let loggerNet = Logger(
    subsystem: "com.sleepyshark.carkey",
    category: "net"
)

// api请求协议
protocol EndpointType {
    var path: String { get }
    var method: String { get }
    var body: [String: Any]? { get }
}

enum BaojunEndpoint {
    /// 账号下所有车辆
    case queryAllCar
    /// 默认车辆状态
    case queryDefaultCarStatus(vin: String)
    /// 蓝牙数字钥匙
    case queryBleKey(vin: String, userId: String)
    /// 车门锁止/解锁
    case doorLock(vin: String, locked: Bool)
    /// 车窗
    case window(vin: String, close: Bool)
    /// 寻车（闪灯鸣笛）
    case searchCar(vin: String)
    /// 远程启动授权
    case ignitionAuthorize(vin: String)
    /// 空调
    case airCondition(vin: String, on: Bool, temperature: Int, blower: Int, duration: Int, heat: Bool)
    /// 胎压
    case tirePressure(vin: String)
}

extension BaojunEndpoint: EndpointType {
    var path: String {
        switch self {
        case .queryAllCar:
            return "/junApi/sgmw/userCarRelation/queryAllCar"
        case .queryDefaultCarStatus:
            return "/junApi/sgmw/userCarRelation/queryDefaultCarStatus"
        case .queryBleKey:
            return "/junApi/sgmw/car/control/ble/key/query"
        case .doorLock:
            return "/junApi/sgmw/car/control/doorLock"
        case .window:
            return "/junApi/sgmw/car/control/window"
        case .searchCar:
            return "/junApi/sgmw/car/control/searchCar"
        case .ignitionAuthorize:
            return "/junApi/sgmw/car/control/ignition/authorize"
        case .airCondition:
            return "/junApi/sgmw/car/control/acc"
        case .tirePressure:
            return "/junApi/sgmw/car/info/tire/pressure"
        }
    }

    var method: String {
        return "POST"
    }

    var body: [String: Any]? {
        switch self {
        case .queryAllCar:
            return [:]
        case .queryDefaultCarStatus(let vin):
            return ["vin": vin]
        case .queryBleKey(let vin, let userId):
            return ["vin": vin, "userId": userId]
        case .doorLock(let vin, let locked):
            return ["vin": vin, "status": locked ? 1 : 0]
        case .window(let vin, let close):
            return ["vin": vin, "status": close ? "1" : "0"]
        case .searchCar(let vin):
            return ["vin": vin]
        case .ignitionAuthorize(let vin):
            return ["vin": vin]
        case .airCondition(let vin, let on, let temperature, let blower, let duration, let heat):
            return [
                "vin": vin,
                "accOnOff": on ? "1" : "0",
                "status": on ? (heat ? "2" : "1") : "0",
                "temperature": String(temperature),
                "blowerLvl": String(blower),
                "duration": String(duration)
            ]
        case .tirePressure(let vin):
            return ["vin": vin]
        }
    }
}

class NetworkManager {
    static let shared = NetworkManager()
    private init() {}
    private let session = URLSession.shared
}

// General part
extension NetworkManager {
    func request(_ request: URLRequest, completion: @escaping (Result<Data, Error>) -> Void) {
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusError = NSError(domain: "com.networking.error", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected response"])
                completion(.failure(statusError))
                return
            }

            if let data = data {
                completion(.success(data))
            }
        }
        task.resume()
    }
}

// Baojun Part
extension NetworkManager {
    /// 带签名的宝骏接口请求
    func requestBaojun(_ endpoint: EndpointType, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: BaojunConfig.baseURL + endpoint.path) else {
            let error = NSError(domain: "NetworkManager", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            completion(.failure(error))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method

        guard let headers = DataManager.shared.sgmwUnifiedOAuth.generateAuthenticatedHeaders(forPath: endpoint.path) else {
            let error = NSError(domain: "NetworkManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "未登录或签名失败"])
            completion(.failure(error))
            return
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        // 附加设备信息头（不参与签名）
        let device = UIDevice.current
        let appInfo = Bundle.main.infoDictionary
        let appVersion = appInfo?["CFBundleShortVersionString"] as? String ?? "1.0"
        let appBuild = appInfo?["CFBundleVersion"] as? String ?? "1"
        request.setValue("73", forHTTPHeaderField: "accessChannel")
        request.setValue("%E4%B8%8A%E6%B5%B7%E5%B8%82", forHTTPHeaderField: "cityName")
        request.setValue(getDeviceModelIdentifier(), forHTTPHeaderField: "deviceType")
        request.setValue("App Store", forHTTPHeaderField: "channel")
        request.setValue(device.systemVersion, forHTTPHeaderField: "platformVersion")
        request.setValue("31.262702401106353", forHTTPHeaderField: "latitude")
        request.setValue(appVersion, forHTTPHeaderField: "version")
        request.setValue(appBuild, forHTTPHeaderField: "build")
        request.setValue("121.65264383085028", forHTTPHeaderField: "longitude")

        if let bodyData = endpoint.body,
           let jsonData = try? JSONSerialization.data(withJSONObject: bodyData, options: []) {
            request.httpBody = jsonData
        }

        self.request(request, completion: completion)
    }
}

// MARK: - 登录 + 拉取数据

extension DataManager {

    /// 手机号密码登录
    func signIn(mobile: String, password: String,
                completion: @escaping (Result<Void, Error>) -> Void) {
        sgmwUnifiedOAuth.login(mobile: mobile, password: password) { [weak self] result in
            self?.handleLoginResult(mobile: mobile, result: result, completion: completion)
        }
    }

    /// 手机号验证码登录
    func signIn(mobile: String, smsCode: String,
                completion: @escaping (Result<Void, Error>) -> Void) {
        sgmwUnifiedOAuth.login(mobile: mobile, smsCode: smsCode) { [weak self] result in
            self?.handleLoginResult(mobile: mobile, result: result, completion: completion)
        }
    }

    /// 发送登录验证码
    func sendLoginSmsCode(mobile: String, completion: @escaping (Result<Void, Error>) -> Void) {
        sgmwUnifiedOAuth.requestSmsCode(mobile: mobile, completion: completion)
    }

    private func handleLoginResult(mobile: String,
                                   result: Result<String, Error>,
                                   completion: @escaping (Result<Void, Error>) -> Void) {
        switch result {
        case .success(let token):
            loggerNet.debug("login success, token length = \(token.count)")
            self.login(userName: mobile,
                       accessToken: token,
                       clientSecret: BaojunConfig.clientSecret,
                       userID: mobile)
            self.bootstrap { bootstrapResult in
                DispatchQueue.main.async {
                    completion(bootstrapResult)
                }
            }
        case .failure(let error):
            loggerNet.error("login failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                completion(.failure(error))
            }
        }
    }

    /// 登录后依次拉取：车辆列表 → 车辆状态 → 蓝牙钥匙
    func bootstrap(completion: @escaping (Result<Void, Error>) -> Void) {
        fetchVehicleList { [weak self] vinResult in
            guard let self = self else { return }
            switch vinResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let vin):
                self.bindVehicle(vin: vin)
                self.fetchAndLoadCarData(vin: vin)
                self.fetchAndLoadKeyData(vin: vin)
                self.fetchAndLoadTirePressure(vin: vin)
                self.startRealtime()
                // 给状态/钥匙请求一点时间落地
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    completion(.success(()))
                }
            }
        }
    }

    /// 拉取账号下的车辆并取 VIN
    func fetchVehicleList(completion: @escaping (Result<String, Error>) -> Void) {
        NetworkManager.shared.requestBaojun(BaojunEndpoint.queryAllCar) { result in
            switch result {
            case .failure(let error):
                loggerNet.error("queryAllCar failed: \(error.localizedDescription)")
                completion(.failure(error))
            case .success(let data):
                let json: Any = (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
                if let message = DataManager.errorMessage(from: json) {
                    completion(.failure(BaojunAuthError.server(message)))
                    return
                }
                if let vin = DataManager.findValue(in: json, key: "vin"), vin.isEmpty == false {
                    loggerNet.debug("got vin: \(vin)")
                    completion(.success(vin))
                } else {
                    completion(.failure(BaojunAuthError.parse("没有找到账号下的车辆 VIN")))
                }
            }
        }
    }

    func fetchAndLoadCarData(vin explicitVin: String? = nil) {
        let vin = (explicitVin?.isEmpty == false ? explicitVin! : self.vin)
        guard vin.isEmpty == false else {
            loggerNet.error("cannot fetch car data without vin")
            return
        }
        NetworkManager.shared.requestBaojun(BaojunEndpoint.queryDefaultCarStatus(vin: vin)) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    if let responseString = String(data: data, encoding: .utf8) {
                        self?.loadCarData(from: responseString)
                    }
                case .failure(let error):
                    loggerNet.error("failed to load car data: \(error.localizedDescription)")
                }
            }
        }
    }

    func fetchAndLoadKeyData(vin explicitVin: String? = nil) {
        let vin = (explicitVin?.isEmpty == false ? explicitVin! : self.vin)
        guard vin.isEmpty == false else {
            loggerNet.error("cannot fetch key without vin")
            return
        }
        let userId = self.appData.userData?.userID
            ?? self.appData.carData?.carInfo.bindCarUserMobile
            ?? ""
        NetworkManager.shared.requestBaojun(BaojunEndpoint.queryBleKey(vin: vin, userId: userId)) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    if let responseString = String(data: data, encoding: .utf8) {
                        self?.loadKeyData(from: responseString)
                    }
                case .failure(let error):
                    loggerNet.error("failed to load car key data: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 胎压（4 轮 + 轮胎温度）
    func fetchAndLoadTirePressure(vin explicitVin: String? = nil) {
        let vin = (explicitVin?.isEmpty == false ? explicitVin! : self.vin)
        guard vin.isEmpty == false else {
            loggerNet.error("cannot fetch tire pressure without vin")
            return
        }
        NetworkManager.shared.requestBaojun(BaojunEndpoint.tirePressure(vin: vin)) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    guard let json: Any = try? JSONSerialization.jsonObject(with: data) else { return }
                    if let message = DataManager.errorMessage(from: json) {
                        loggerNet.error("tire pressure failed: \(message)")
                        return
                    }
                    let lf = DataManager.numberValue(in: json, keys: ["lfTirPrsVal", "lfTirePressure"])
                    let rf = DataManager.numberValue(in: json, keys: ["rfTirPrVal", "rfTirePressure"])
                    let lr = DataManager.numberValue(in: json, keys: ["lrTirPrVal", "lrTirePressure"])
                    let rr = DataManager.numberValue(in: json, keys: ["rrTirPrVal", "rrTirePressure"])
                    let temp = DataManager.numberValue(in: json, keys: ["tirTemp", "tireTemp"])

                    guard lf != nil || rf != nil || lr != nil || rr != nil else {
                        loggerNet.warning("tire pressure payload has no recognized fields")
                        return
                    }
                    self?.appData.tirePressure = TirePressure(lf: lf, rf: rf, lr: lr, rr: rr, temp: temp)
                    loggerNet.debug("tire pressure updated")
                case .failure(let error):
                    loggerNet.error("failed to load tire pressure: \(error.localizedDescription)")
                }
            }
        }
    }

    /// 云端车控（BLE 未连接时的兜底）
    func sendCloudControl(_ endpoint: BaojunEndpoint,
                          completion: @escaping (Result<Void, Error>) -> Void) {
        NetworkManager.shared.requestBaojun(endpoint) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { completion(.failure(error)) }
            case .success(let data):
                let json: Any = (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
                if let message = DataManager.errorMessage(from: json) {
                    DispatchQueue.main.async { completion(.failure(BaojunAuthError.server(message))) }
                } else {
                    DispatchQueue.main.async { completion(.success(())) }
                }
                // 车控下发后刷新一次状态
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    DataManager.shared.fetchAndLoadCarData()
                }
            }
        }
    }

    // MARK: JSON 工具

    static func errorMessage(from object: Any) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        if let result = dict["result"] as? Bool, result == false {
            return (dict["message"] as? String) ?? (dict["msg"] as? String) ?? "接口返回失败"
        }
        if let code = dict["code"] as? String, code != "0", code != "200", code.lowercased() != "success" {
            let message = (dict["message"] as? String) ?? (dict["msg"] as? String) ?? "接口返回异常 code=\(code)"
            return message
        }
        return nil
    }

    /// 在 JSON 里按多个候选字段名找数值（字符串形式的数字也能解析）
    static func numberValue(in object: Any, keys: [String]) -> Double? {
        for key in keys {
            if let text = findAnyValue(in: object, key: key) {
                if let value = Double(text) { return value }
            }
        }
        return nil
    }

    static func findAnyValue(in object: Any, key: String) -> String? {
        if let dict = object as? [String: Any] {
            for (rawKey, value) in dict where String(describing: rawKey).lowercased() == key.lowercased() {
                if let number = value as? NSNumber { return number.stringValue }
                if let s = value as? String, s.isEmpty == false { return s }
            }
            for value in dict.values {
                if let found = findAnyValue(in: value, key: key) { return found }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let found = findAnyValue(in: item, key: key) { return found }
            }
        }
        return nil
    }

    /// 在 JSON 里找出第一个名为 key 的非空字符串
    static func findValue(in object: Any, key: String) -> String? {
        if let dict = object as? [String: Any] {
            for (rawKey, value) in dict where String(describing: rawKey).lowercased() == key.lowercased() {
                if let s = value as? String, s.isEmpty == false { return s }
            }
            for value in dict.values {
                if let found = findValue(in: value, key: key) { return found }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let found = findValue(in: item, key: key) { return found }
            }
        }
        return nil
    }
}
