//
//  Car3DView.swift
//  carkey
//
//  3D 车辆卡片：用 WKWebView + three.js 渲染 GLB 模型，
//  由车辆状态驱动车门 / 车窗 / 后备箱的开合动画。
//

import SwiftUI
import WebKit

// MARK: - 本地资源 URL 协议（避免 file:// 的跨域限制）

final class Car3DBundleHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "car3dbundle"

    private let rootDirectory: URL?

    override init() {
        rootDirectory = Bundle.main.url(forResource: "car3d", withExtension: nil)
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(Car3DError.badRequest)
            return
        }

        var relativePath = url.path
        if relativePath.isEmpty || relativePath == "/" {
            relativePath = "/index.html"
        }
        let relative = String(relativePath.drop(while: { $0 == "/" }))

        guard let base = rootDirectory else {
            urlSchemeTask.didFailWithError(Car3DError.missingBundle)
            return
        }

        let fileURL = base.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(Car3DError.notFound(relative))
            return
        }

        let mimeType = Car3DBundleHandler.mimeType(for: fileURL.pathExtension)
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/") || mimeType.contains("javascript") ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "glb": return "model/gltf-binary"
        case "gltf": return "model/gltf+json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ktx2": return "image/ktx2"
        default: return "application/octet-stream"
        }
    }
}

enum Car3DError: Error {
    case badRequest
    case missingBundle
    case notFound(String)
    case js(String)
}

// MARK: - WebView 桥

final class Car3DBridge: NSObject, ObservableObject, WKScriptMessageHandler {

    static let shared = Car3DBridge()

    @Published private(set) var isReady = false
    @Published private(set) var message: String?

    private var webView: WKWebView?
    private var lastPayload = ""

    func makeWebView() -> WKWebView {
        if let existing = webView { return existing }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.setURLSchemeHandler(Car3DBundleHandler(), forURLScheme: Car3DBundleHandler.scheme)
        config.userContentController.add(self, name: "car3d")

        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.allowsBackForwardNavigationGestures = false
        view.isUserInteractionEnabled = true

        if let url = URL(string: "\(Car3DBundleHandler.scheme)://model/index.html") {
            view.load(URLRequest(url: url))
        }

        webView = view
        return view
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        DispatchQueue.main.async {
            if text == "ready" {
                self.isReady = true
                self.message = nil
            } else if text.hasPrefix("error:") {
                self.message = String(text.dropFirst("error:".count))
            }
        }
    }

    /// 把车辆状态推给 3D 模型；内容没变化就不重复调用
    func apply(status: CarStatus, payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        guard json != lastPayload else { return }
        lastPayload = json
        evaluate("window.Car3D && window.Car3D.applyStatus(\(json));")
    }

    func resetView() {
        evaluate("window.Car3D && window.Car3D.resetView();")
    }

    func setAutoRotate(_ on: Bool) {
        evaluate("window.Car3D && window.Car3D.setAutoRotate(\(on ? "true" : "false"));")
    }

    /// 点击某个部位时给一次动画反馈
    func toggleDoorPreview(_ id: String) {
        evaluate("window.Car3D && window.Car3D.pulseDoor('\(id)');")
    }

    private func evaluate(_ script: String) {
        DispatchQueue.main.async {
            guard let view = self.webView else { return }
            view.evaluateJavaScript(script) { _, error in
                if let error = error {
                    loggerBle.error("car3d js error: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - SwiftUI 包装

struct Car3DModelView: UIViewRepresentable {

    func makeUIView(context: Context) -> WKWebView {
        Car3DBridge.shared.makeWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 3D 车辆卡片

struct Car3DCard: View {

    let status: CarStatus
    let isLocked: Bool

    @ObservedObject private var bridge = Car3DBridge.shared
    @State private var autoRotate = false

    private var doors: [String: Bool] {
        [
            "leftFront": status["door1OpenStatus"] == "1",
            "rightFront": status["door2OpenStatus"] == "1",
            "leftRear": status["door3OpenStatus"] == "1",
            "rightRear": status["door4OpenStatus"] == "1",
            "tailgate": status["tailDoorOpenStatus"] == "1"
        ]
    }

    private var windows: [String: Bool] {
        [
            "leftFront": status["window1Status"] == "1",
            "rightFront": status["window2Status"] == "1",
            "leftRear": status["window3Status"] == "1",
            "rightRear": status["window4Status"] == "1"
        ]
    }

    private var lights: [String: Bool] {
        [
            "running": status["positionLight"] == "1",
            "brake": status["brakeLightStatus"] == "1",
            "lowBeam": status["lowBeamLight"] == "1" || status["dipHeadLight"] == "1",
            "highBeam": status["highBeamLight"] == "1",
            "turnLeft": status["leftTurnLight"] == "1",
            "turnRight": status["rightTurnLight"] == "1"
        ]
    }

    private var payload: [String: Any] {
        ["doors": doors, "windows": windows, "lights": lights]
    }

    private var openDoorCount: Int {
        doors.values.filter { $0 }.count
    }

    private var openWindowCount: Int {
        windows.values.filter { $0 }.count
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.08, green: 0.10, blue: 0.13),
                                     Color(red: 0.03, green: 0.04, blue: 0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                Car3DModelView()
                    .frame(height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                if !bridge.isReady {
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text(bridge.message ?? "正在加载 3D 车辆模型…")
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HStack(spacing: 8) {
                    Button {
                        autoRotate.toggle()
                        bridge.setAutoRotate(autoRotate)
                    } label: {
                        Image(systemName: autoRotate ? "rotate.3d.fill" : "rotate.3d")
                            .font(.footnote)
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }

                    Button {
                        bridge.resetView()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.footnote)
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                }
                .padding(10)

                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        chip(icon: isLocked ? "lock.fill" : "lock.open.fill",
                             text: isLocked ? "已上锁" : "已解锁",
                             tint: isLocked ? Color.green : Color.orange)
                        chip(icon: "door.left.hand.open",
                             text: "车门 \(openDoorCount)/4",
                             tint: openDoorCount > 0 ? Color.orange : Color.gray)
                        chip(icon: "rectangle.bottomthird.inset.filled",
                             text: doors["tailgate"] == true ? "后备箱开" : "后备箱关",
                             tint: doors["tailgate"] == true ? Color.orange : Color.gray)
                        chip(icon: "wind",
                             text: "车窗 \(openWindowCount)/4",
                             tint: openWindowCount > 0 ? Color.blue : Color.gray)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }

            Text("拖动可旋转车辆 · 双指缩放")
                .font(.caption2)
                .foregroundColor(.gray.opacity(0.7))
        }
        .onAppear {
            bridge.apply(status: status, payload: payload)
        }
        .onChange(of: payloadSignature) { _ in
            bridge.apply(status: status, payload: payload)
        }
    }

    private var payloadSignature: String {
        let doorSig = doors.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value ? 1 : 0)" }.joined()
        let windowSig = windows.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value ? 1 : 0)" }.joined()
        return doorSig + "|" + windowSig
    }

    private func chip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.28))
        .clipShape(Capsule())
    }
}

// MARK: - 胎压卡片

struct TirePressureCard: View {

    let pressure: TirePressure?

    private func value(_ raw: Double?) -> String {
        guard let raw = raw else { return "—" }
        return String(format: "%.0f", raw)
    }

    private func color(_ raw: Double?) -> Color {
        guard let raw = raw else { return .gray }
        if raw < 200 { return .red }
        if raw > 280 { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("胎压")
                    .font(.caption)
                    .foregroundColor(.gray)
                Spacer()
                if let temp = pressure?.temp {
                    Text("轮胎温度 \(String(format: "%.0f", temp))°C")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }

            HStack(spacing: 14) {
                tire(title: "左前", value: value(pressure?.lf), tint: color(pressure?.lf))
                tire(title: "右前", value: value(pressure?.rf), tint: color(pressure?.rf))
            }
            HStack(spacing: 14) {
                tire(title: "左后", value: value(pressure?.lr), tint: color(pressure?.lr))
                tire(title: "右后", value: value(pressure?.rr), tint: color(pressure?.rr))
            }

            if pressure == nil {
                Text("云端暂未返回胎压数据（部分车型需车辆上电后才有）")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func tire(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 15))
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10)).foregroundColor(.gray)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text("kPa").font(.system(size: 9)).foregroundColor(.gray)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
