//
//  SGMW.swift
//  carkey
//
//  Created by Shilapi Chen on 9/9/25.
//  Reworked for Baojun (宝骏汽车+) openapi: login + signed requests.
//

import Foundation
import SwiftUI
import CryptoKit
import CoreBluetooth

enum SGMWBLEProfile {
    enum UnknownSpectial {
        static let uuid = CBUUID(string: "F000FFD0-0451-4000-B000-000000000000")
    }

    enum AuthorizeService {
        static let uuid = CBUUID(string: "181A")

        enum Characteristics {
            // request by Write
            static let Request = CBUUID(string: "2A6E")
            // response by notify
            static let Response = CBUUID(string: "2A6F")

            static let AllCharacteristicsUuid = [
                Request,
                Response
            ]
        }
    }

    enum ControlService {
        static let uuid = CBUUID(string: "182A")

        enum Characteristics {
            // request by Write
            static let Request = CBUUID(string: "2A7E")
            // response by notify
            static let Response = CBUUID(string: "2A7F")

            static let AllCharacteristicsUuid = [
                Request,
                Response
            ]
        }
    }

    static let AllServicesUuid = [
        UnknownSpectial.uuid,
        AuthorizeService.uuid,
        ControlService.uuid
    ]
}

// MARK: - 宝骏开放平台配置
//
// 这组参数取自 baojun_vehicle（Home Assistant 集成）里实测可用的
// 「宝骏汽车+」客户端凭据：appCode = baojun_plus，版本 1.2.11。
// 签名规则：sha256(path + accessToken + nonce + timestamp)
//
enum BaojunConfig {
    static let baseURL = "https://openapi.baojun.net"
    static let clientId = "2019022010124905839"
    static let clientSecret = "38bcbed68e03f38b5b8d67f59f6f4954"
    static let appCode = "baojun_plus"
    static let appVersion = "1.2.11"

    // 头部设备信息不参与签名，沿用集成里跑通的取值
    static let deviceBrand = "Apple"
    static let deviceModel = "iPhone"
    static let deviceType = "iOS"
    static let systemVersion = "18.0"
}

enum BaojunAuthError: LocalizedError {
    case network(String)
    case server(String)
    case parse(String)
    case missingToken

    var errorDescription: String? {
        switch self {
        case .network(let msg): return "网络错误：\(msg)"
        case .server(let msg): return msg.isEmpty ? "服务器拒绝了请求" : msg
        case .parse(let msg): return "返回数据无法解析：\(msg)"
        case .missingToken: return "登录成功但没有拿到 access_token"
        }
    }
}

struct AuthParameters {
    let signature: String
    let nonce: String
    let timestamp: String
}

// MARK: - 宝骏统一认证
class SGMWUnifiedOAuth {

    private(set) var accessToken: String?
    private(set) var clientSecret: String?

    init() {}

    // 登录成功后写入
    func updateToken(accessToken: String, clientSecret: String = BaojunConfig.clientSecret) {
        self.accessToken = accessToken
        self.clientSecret = clientSecret
    }

    // 退出登录
    func clearToken() {
        self.accessToken = nil
        self.clientSecret = nil
    }

    var isLoggedIn: Bool {
        return (accessToken ?? "").isEmpty == false
    }

    // MARK: 签名头

    /// 生成带签名的请求头。签名和具体 path 绑定，必须传入接口路径。
    func generateAuthenticatedHeaders(forPath path: String) -> [String: String]? {
        guard let token = accessToken, !token.isEmpty else {
            loggerNet.error("no access token, cannot sign request")
            return nil
        }
        let authParams = generateAuthenticationParameters(path: path, accessToken: token)

        return [
            "Content-Type": "application/json",
            "accept": "application/json",
            // 业务头
            "platformNo": "android",
            "version": BaojunConfig.appVersion,
            "appCode": BaojunConfig.appCode,
            "deviceBrand": BaojunConfig.deviceBrand,
            "deviceModel": BaojunConfig.deviceModel,
            "deviceType": BaojunConfig.deviceType,
            "systemVersion": BaojunConfig.systemVersion,
            // 签名头
            "sgmwclientid": BaojunConfig.clientId,
            "sgmwclientsecret": BaojunConfig.clientSecret,
            "sgmwtimestamp": authParams.timestamp,
            "sgmwnonce": authParams.nonce,
            "sgmwsignature": authParams.signature,
            "sgmwappcode": BaojunConfig.appCode,
            "sgmwappversion": BaojunConfig.appVersion,
            "sgmwsystem": "Android",
            "sgmwsystemversion": "15",
            "sgmwplatformno": "android",
            "sgmwaccesstoken": token
        ]
    }

    /// 公共接口（登录、验证码）用的头，不需要签名
    func publicHeaders() -> [String: String] {
        return [
            "Content-Type": "application/json",
            "accept": "application/json",
            "platformNo": "android",
            "version": BaojunConfig.appVersion,
            "appCode": BaojunConfig.appCode,
            "deviceBrand": BaojunConfig.deviceBrand,
            "deviceModel": BaojunConfig.deviceModel,
            "deviceType": BaojunConfig.deviceType,
            "systemVersion": BaojunConfig.systemVersion
        ]
    }

    private func generateAuthenticationParameters(path: String, accessToken: String) -> AuthParameters {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString
        let signSource = path + accessToken + nonce + timestamp
        let signature = signSource.sha256Hex()
        return AuthParameters(signature: signature, nonce: nonce, timestamp: timestamp)
    }

    // MARK: 登录

    /// 短信验证码登录
    func login(mobile: String, smsCode: String,
               completion: @escaping (Result<String, Error>) -> Void) {
        let base: [String: String] = [
            "client_id": BaojunConfig.clientId,
            "client_secret": BaojunConfig.clientSecret,
            "response_type": "token",
            "state": "carkey_ios",
            "loginType": "sms",
            "mobile": mobile,
            "smsCode": smsCode
        ]
        performLogin(payloads: [base], completion: completion)
    }

    /// 手机号 + 密码登录
    func login(mobile: String, password: String,
               completion: @escaping (Result<String, Error>) -> Void) {
        let base: [String: String] = [
            "client_id": BaojunConfig.clientId,
            "client_secret": BaojunConfig.clientSecret,
            "response_type": "token",
            "state": "carkey_ios",
            "loginType": "password",
            "mobile": mobile,
            "password": password
        ]
        var alt = base
        alt.removeValue(forKey: "mobile")
        alt["userName"] = mobile
        performLogin(payloads: [base, alt], completion: completion)
    }

    /// 请求登录短信验证码
    func requestSmsCode(mobile: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard var components = URLComponents(string: BaojunConfig.baseURL + "/oauth/jun/getLoginSmsCode") else {
            completion(.failure(BaojunAuthError.parse("bad url")))
            return
        }
        components.queryItems = [URLQueryItem(name: "mobile", value: mobile)]
        guard let url = components.url else {
            completion(.failure(BaojunAuthError.parse("bad url")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in publicHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(BaojunAuthError.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                completion(.failure(BaojunAuthError.network("HTTP 请求失败")))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(BaojunAuthError.parse("empty response")))
                return
            }
            if let result = json["result"] as? Bool, result == false {
                let message = (json["message"] as? String) ?? (json["msg"] as? String) ?? "验证码发送失败"
                completion(.failure(BaojunAuthError.server(message)))
                return
            }
            completion(.success(()))
        }.resume()
    }

    /// 依次尝试多种请求体格式，兼容服务端不同的接收方式
    private func performLogin(payloads: [[String: String]],
                              completion: @escaping (Result<String, Error>) -> Void) {
        var remaining = payloads
        guard let current = remaining.first else {
            completion(.failure(BaojunAuthError.server("登录失败，请检查账号或密码")))
            return
        }
        remaining.removeFirst()

        guard let url = URL(string: BaojunConfig.baseURL + "/oauth/jun/ucenter/login") else {
            completion(.failure(BaojunAuthError.parse("bad url")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in publicHeaders() where key != "Content-Type" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // 表单提交（与集成里跑通的第一种方式一致）
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var pairs: [String] = []
        for (key, value) in current {
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { continue }
            pairs.append("\(key)=\(encoded)")
        }
        request.httpBody = pairs.joined(separator: "&").data(using: .utf8)

        let finish: (Result<String, Error>) -> Void = { [weak self] result in
            switch result {
            case .success(let token):
                self?.updateToken(accessToken: token)
                completion(.success(token))
            case .failure:
                if remaining.isEmpty {
                    completion(result)
                } else {
                    self?.performLogin(payloads: remaining, completion: completion)
                }
            }
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                finish(.failure(BaojunAuthError.network(error.localizedDescription)))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                finish(.failure(BaojunAuthError.parse("empty response")))
                return
            }
            if let result = json["result"] as? Bool, result == false {
                let message = (json["message"] as? String) ?? (json["msg"] as? String) ?? "登录失败"
                finish(.failure(BaojunAuthError.server(message)))
                return
            }
            guard let token = SGMWUnifiedOAuth.extractString(json, keys: ["access_token", "accessToken", "sgmwaccesstoken", "token"]) else {
                finish(.failure(BaojunAuthError.missingToken))
                return
            }
            finish(.success(token))
        }.resume()
    }

    // MARK: JSON 小工具

    /// 递归查找第一个命中的字符串字段
    static func extractString(_ object: Any, keys: [String]) -> String? {
        if let dict = object as? [String: Any] {
            var lowered: [String: Any] = [:]
            for (key, value) in dict {
                lowered[String(describing: key).lowercased()] = value
            }
            for key in keys {
                if let value = lowered[key.lowercased()] {
                    if let s = value as? String, s.isEmpty == false { return s }
                    if let n = value as? NSNumber { return n.stringValue }
                }
            }
            for value in dict.values {
                if let found = extractString(value, keys: keys) { return found }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let found = extractString(item, keys: keys) { return found }
            }
        }
        return nil
    }
}

extension String {
    func sha256Hex() -> String {
        let digest = SHA256.hash(data: Data(self.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
