//
//  BaojunMQTT.swift
//  carkey
//
//  宝骏云端 MQTT 推送（MQTT 3.1.1 / TCP 1883），用于实时状态：
//  车门、车窗、尾门、车锁、空调状态由服务器主动推送，替代轮询。
//  协议细节对齐 HA 集成 baojun_vehicle/mqtt.py。
//

import Foundation
import Network
import CryptoKit

final class BaojunMQTTClient {

    static let shared = BaojunMQTTClient()

    // MARK: 配置

    private let host = "parkingdata.sgmwcloud.com.cn"
    private let port: UInt16 = 1883
    private let topicSuffixes = [
        "/prod/sgmw/vehicle/app/status",
        "/prod/sgmw/vehicle/control",
        "/prod/sgmw/vehicle/car_check_authorize/business",
        "/prod/sgmw/vehicle/car_parking_notify/business"
    ]

    private let mqttAuthPath = "/junApi/sgmw/base/mqtt/auth"
    private let mqttClientId = "2019041810222516127"
    private let mqttClientSecret = BaojunConfig.clientSecret
    private let mqttAppCode = "sgmw_llb"
    private let mqttAppVersion = "5.2.15"
    private let mqttSystem = "iOS"
    private let mqttSystemVersion = "15.4.1"
    private let mqttUserAgent = "LingLingBang/5.2.15"

    // MARK: 回调（主线程）

    var onStatusPatch: (([String: String]) -> Void)?
    var onControlResult: (([String: String]) -> Void)?
    var onConnectionState: ((_ state: String, _ connected: Bool) -> Void)?

    // MARK: 状态

    private let queue = DispatchQueue(label: "cn.mengyu.baojun.mqtt")
    private var connection: NWConnection?
    private var vin = ""
    private var token: String?
    private var currentClientId = ""
    private var buffer = Data()
    private var packetId: UInt16 = 1
    private var attempt = 0
    private var running = false
    private var connected = false
    private var keepAliveTimer: DispatchSourceTimer?
    private var retryWork: DispatchWorkItem?

    private init() {}

    // MARK: 启停

    func start(vin: String) {
        guard vin.isEmpty == false else { return }
        if running && vin == self.vin && (connection != nil) { return }

        stop(silent: true)
        running = true
        attempt = 0
        self.vin = vin
        token = nil
        queue.async { [weak self] in
            self?.fetchTokenAndConnect()
        }
    }

    func stop(silent: Bool = false) {
        running = false
        retryWork?.cancel()
        retryWork = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        queue.async { [weak self] in
            guard let self = self else { return }
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
            self.connected = false
            if !silent {
                self.notifyState("已断开", connected: false)
            }
        }
    }

    var isConnected: Bool { connected }

    // MARK: Token

    private func fetchTokenAndConnect() {
        guard running else { return }

        if let token = token, token.isEmpty == false {
            connect(with: token)
            return
        }
        guard let accessToken = DataManager.shared.appData.userData?.accessToken,
              accessToken.isEmpty == false else {
            scheduleRetry(reason: "缺少 accessToken", collision: false)
            return
        }

        var request = URLRequest(url: URL(string: BaojunConfig.baseURL + mqttAuthPath)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["vin": vin])
        for (field, value) in mqttAuthHeaders(accessToken: accessToken) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            self.queue.async {
                guard self.running else { return }

                if let error = error {
                    self.scheduleRetry(reason: "token 请求失败: \(error.localizedDescription)", collision: false)
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.scheduleRetry(reason: "token 响应解析失败", collision: false)
                    return
                }
                if let result = json["result"] as? Bool, result == false {
                    let message = (json["message"] as? String) ?? (json["msg"] as? String) ?? "unknown"
                    self.scheduleRetry(reason: "token 被拒绝: \(message)", collision: false)
                    return
                }
                let payload = (json["data"] as? [String: Any]) ?? json
                guard let value = (payload["mqttToken"] as? String) ?? (payload["token"] as? String),
                      value.isEmpty == false else {
                    self.scheduleRetry(reason: "响应里没有 mqttToken", collision: false)
                    return
                }
                self.token = value
                self.connect(with: value)
            }
        }.resume()
    }

    private func mqttAuthHeaders(accessToken: String) -> [String: String] {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = BaojunMQTTClient.randomNonce(length: 10)
        let raw = accessToken
            + timestamp
            + nonce
            + mqttClientId
            + mqttClientSecret
            + mqttAppCode
            + mqttAppVersion
            + mqttSystem
            + mqttSystemVersion
        let signature = SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return [
            "Content-Type": "application/json; charset=UTF-8",
            "User-Agent": mqttUserAgent,
            "sgmwaccesstoken": accessToken,
            "sgmwtimestamp": timestamp,
            "sgmwnonce": nonce,
            "sgmwclientid": mqttClientId,
            "sgmwclientsecret": mqttClientSecret,
            "sgmwappcode": mqttAppCode,
            "sgmwappversion": mqttAppVersion,
            "sgmwsystem": mqttSystem,
            "sgmwsystemversion": mqttSystemVersion,
            "sgmwsignature": signature
        ]
    }

    // MARK: 连接

    private func connect(with token: String) {
        guard running else { return }
        guard attempt < 12 else {
            notifyState("重连次数已用尽", connected: false)
            return
        }
        attempt += 1

        currentClientId = "\(vin)_" + String(format: "%04d", Int.random(in: 0...9999))
        notifyState("正在连接", connected: false)

        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        let conn = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
        connection = conn
        buffer = Data()
        packetId = 1

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendConnect(token: token)
            case .failed(let error):
                self.handleDrop(reason: "连接失败: \(error.localizedDescription)")
            case .cancelled:
                if self.running { self.handleDrop(reason: "连接取消") }
            case .waiting(let error):
                self.notifyState("等待网络: \(error.localizedDescription)", connected: false)
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    private func sendConnect(token: String) {
        let username = BaojunMQTTClient.md5(vin.prefix(6) + token)
        let password = BaojunMQTTClient.md5(String(currentClientId.suffix(6)) + token)

        var header = Data()
        header.append(0x10)                                     // CONNECT
        var payload = Data()
        payload.append(mqttString("MQTT"))
        payload.append(4)                                        // protocol level 3.1.1
        payload.append(0xC2)                                     // clean session + username + password
        payload.append(contentsOf: [0x00, 0x3C])                 // keepalive 60s
        payload.append(mqttString(currentClientId))
        payload.append(mqttString(username))
        payload.append(mqttString(password))

        header.append(encodeLength(payload.count))
        header.append(payload)
        send(header)
        startReceiveLoop()
        let sentClientId = currentClientId
        loggerNet.info("MQTT CONNECT 已发送 clientId=\(sentClientId)")
    }

    private func subscribe() {
        var body = Data()
        packetId = nextPacketId()
        body.append(contentsOf: packetIdBytes(packetId))
        for suffix in topicSuffixes {
            body.append(mqttString(vin + suffix))
            body.append(1)                                       // QoS 1
        }
        var packet = Data([0x82])                                // SUBSCRIBE
        packet.append(encodeLength(body.count))
        packet.append(body)
        send(packet)

        startKeepAlive()
        connected = true
        attempt = 0
        notifyState("已连接，实时状态推送中", connected: true)
        loggerNet.info("MQTT 已订阅 \(self.topicSuffixes.count) 个 topic")
    }

    private func startReceiveLoop() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, data.isEmpty == false {
                self.buffer.append(data)
                self.drainPackets()
            }
            if let error = error {
                self.handleDrop(reason: "接收失败: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.handleDrop(reason: "连接被关闭")
                return
            }
            self.startReceiveLoop()
        }
    }

    private func handleDrop(reason: String) {
        guard running else { return }
        connected = false
        stopKeepAlive()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        scheduleRetry(reason: reason, collision: reason.contains("rc=7") || reason.lowercased().contains("client"))
    }

    private func scheduleRetry(reason: String, collision: Bool) {
        guard running else { return }
        retryWork?.cancel()

        let base = collision ? 0.8 : min(12.0, pow(1.65, Double(max(0, attempt - 1))))
        let delay = base + Double.random(in: 0.15...0.75)
        notifyState("\(reason)，\(String(format: "%.1f", delay))s 后重连", connected: false)
        loggerNet.warning("MQTT 重连原因: \(reason)")

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.running else { return }
            self.fetchTokenAndConnect()
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startKeepAlive() {
        stopKeepAlive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.connected else { return }
            self.send(Data([0xC0, 0x00]))
        }
        timer.resume()
        keepAliveTimer = timer
    }

    private func stopKeepAlive() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
    }

    // MARK: 收包

    private func drainPackets() {
        while true {
            guard buffer.count >= 2 else { return }
            let first = buffer[buffer.startIndex]
            var length = 0
            var multiplier = 1
            var offset = 1
            var complete = false

            while offset < buffer.count && offset <= 4 {
                let byte = buffer[buffer.startIndex + offset]
                length += Int(byte & 0x7F) * multiplier
                multiplier *= 128
                offset += 1
                if byte & 0x80 == 0 { complete = true; break }
            }
            guard complete else { return }
            guard buffer.count >= offset + length else { return }

            let body = buffer.subdata(in: (buffer.startIndex + offset)..<(buffer.startIndex + offset + length))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset + length))
            handlePacket(type: first >> 4, flags: first & 0x0F, body: body)
        }
    }

    private func handlePacket(type: UInt8, flags: UInt8, body: Data) {
        switch type {
        case 2:                                  // CONNACK
            let code = body.count >= 2 ? body[body.startIndex + 1] : 0xFF
            if code == 0 {
                subscribe()
            } else {
                token = nil
                handleDrop(reason: "CONNACK rc=\(code)")
            }

        case 3:                                  // PUBLISH
            let qos = (flags >> 1) & 0x03
            guard body.count >= 2 else { return }
            let topicLength = Int(body[body.startIndex]) << 8 | Int(body[body.startIndex + 1])
            guard body.count >= 2 + topicLength else { return }
            let topic = String(data: body.subdata(in: (body.startIndex + 2)..<(body.startIndex + 2 + topicLength)),
                               encoding: .utf8) ?? ""
            var cursor = 2 + topicLength
            var incomingId: UInt16 = 0
            if qos > 0 {
                guard body.count >= cursor + 2 else { return }
                incomingId = UInt16(body[body.startIndex + cursor]) << 8 | UInt16(body[body.startIndex + cursor + 1])
                cursor += 2
            }
            let payload = body.count > cursor ? body.subdata(in: (body.startIndex + cursor)..<body.endIndex) : Data()

            if qos == 1 {
                var ack = Data([0x40, 0x02])
                ack.append(contentsOf: packetIdBytes(incomingId))
                send(ack)
            }
            dispatch(topic: topic, payload: payload)

        case 9:                                  // SUBACK
            loggerNet.debug("MQTT SUBACK: \(body.map { String($0) }.joined(separator: ","))")

        default:
            break
        }
    }

    private func dispatch(topic: String, payload: Data) {
        if topic.hasSuffix("/vehicle/app/status") {
            let parsed = BaojunProto.parseStatus(payload)
            guard parsed.isEmpty == false else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onStatusPatch?(parsed)
            }
            return
        }

        if topic.hasSuffix("/vehicle/control") {
            let parsed = BaojunProto.parseControlResult(payload)
            guard parsed.isEmpty == false else { return }
            DispatchQueue.main.async { [weak self] in
                self?.onControlResult?(parsed)
            }
            return
        }

        loggerNet.debug("MQTT 其他消息 topic=\(topic) bytes=\(payload.count)")
    }

    // MARK: 发包辅助

    private func send(_ data: Data) {
        guard let conn = connection else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.handleDrop(reason: "发送失败: \(error.localizedDescription)")
            }
        })
    }

    private func nextPacketId() -> UInt16 {
        packetId += 1
        if packetId == 0 { packetId = 1 }
        return packetId
    }

    private func packetIdBytes(_ id: UInt16) -> [UInt8] {
        [UInt8(id >> 8), UInt8(id & 0xFF)]
    }

    private func mqttString(_ text: String) -> Data {
        var data = Data()
        let bytes = Array(text.utf8)
        data.append(UInt8(bytes.count >> 8))
        data.append(UInt8(bytes.count & 0xFF))
        data.append(contentsOf: bytes)
        return data
    }

    private func encodeLength(_ value: Int) -> Data {
        var data = Data()
        var remaining = value
        repeat {
            var byte = UInt8(remaining % 128)
            remaining /= 128
            if remaining > 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining > 0
        return data
    }

    private func notifyState(_ text: String, connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionState?(text, connected)
        }
    }

    // MARK: 工具

    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func randomNonce(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}

// MARK: - protobuf 解析（对齐 baojun_vehicle/protobuf.py）

enum BaojunProto {

    static func parseStatus(_ payload: Data) -> [String: String] {
        var result: [String: String] = [:]
        for field in fields(payload) {
            guard let name = statusFieldNames[field.number] else { continue }
            if let value = intValue(field) {
                result[name] = String(value)
            } else if let text = textValue(field) {
                result[name] = text
            }
        }
        return result
    }

    static func parseControlResult(_ payload: Data) -> [String: String] {
        var result: [String: String] = [:]
        for field in fields(payload) {
            switch field.number {
            case 1: result["resultCode"] = textValue(field) ?? intValue(field).map(String.init) ?? ""
            case 2: result["message"] = textValue(field) ?? ""
            case 3: result["serviceCode"] = textValue(field) ?? ""
            case 4: result["timestamp"] = intValue(field).map(String.init) ?? ""
            default: break
            }
        }
        return result.filter { $0.value.isEmpty == false }
    }

    private static let statusFieldNames: [Int: String] = [
        1: "collectTime", 2: "acStatus", 3: "doorLockStatus",
        4: "door1LockStatus", 5: "door2LockStatus", 6: "door3LockStatus", 7: "door4LockStatus",
        8: "tailDoorLockStatus",
        9: "door1OpenStatus", 10: "door2OpenStatus", 11: "door3OpenStatus", 12: "door4OpenStatus",
        13: "tailDoorOpenStatus",
        14: "window1Status", 15: "window2Status", 16: "window3Status", 17: "window4Status",
        18: "window1OpenDegree", 19: "window2OpenDegree", 20: "window3OpenDegree", 21: "window4OpenDegree"
    ]

    private struct Field {
        let number: Int
        let wire: Int
        let data: Data
    }

    private static func fields(_ payload: Data) -> [Field] {
        var output: [Field] = []
        var offset = 0
        let bytes = [UInt8](payload)

        while offset < bytes.count {
            guard let tag = readVarint(bytes, &offset) else { break }
            let wire = Int(tag & 0x07)
            let number = Int(tag >> 3)

            if wire == 0 {
                guard let value = readVarint(bytes, &offset) else { break }
                var encoded = Data()
                var remainder = UInt64(value)
                repeat {
                    var byte = UInt8(remainder & 0x7F)
                    remainder >>= 7
                    if remainder > 0 { byte |= 0x80 }
                    encoded.append(byte)
                } while remainder > 0
                output.append(Field(number: number, wire: wire, data: encoded))
                continue
            }

            if wire == 2 {
                guard let length = readVarint(bytes, &offset) else { break }
                let end = offset + Int(length)
                guard end <= bytes.count else { break }
                output.append(Field(number: number, wire: wire, data: Data(bytes[offset..<end])))
                offset = end
                continue
            }

            break
        }
        return output
    }

    private static func intValue(_ field: Field) -> Int? {
        guard field.wire == 0 else { return nil }
        var offset = 0
        let bytes = [UInt8](field.data)
        guard let value = readVarint(bytes, &offset) else { return nil }
        return Int(value)
    }

    private static func textValue(_ field: Field) -> String? {
        guard field.wire == 2 else { return nil }
        return String(data: field.data, encoding: .utf8)
    }

    private static func readVarint(_ bytes: [UInt8], _ offset: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
