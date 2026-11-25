//
//  Car3DView.swift
//  carkey
//
//  3D 车辆卡片：WKWebView + three.js 渲染 GLB，
//  车辆状态驱动车门 / 车窗 / 后备箱开合；电量、续航、里程、车锁、胎压直接叠在 3D 视窗上。
//

import SwiftUI
import WebKit

// MARK: - 本地资源 URL 协议

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
            textEncodingName: "utf-8"
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
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}

enum Car3DError: Error {
    case badRequest
    case missingBundle
    case notFound(String)
}

// MARK: - WebView 桥

final class Car3DBridge: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {

    static let shared = Car3DBridge()

    @Published private(set) var isReady = false
    @Published private(set) var message: String?

    private var webView: WKWebView?
    private var lastPayload = ""

    func makeWebView() -> WKWebView {
        if let existing = webView { return existing }

        let controller = WKUserContentController()
        controller.add(self, name: "car3d")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        config.setURLSchemeHandler(Car3DBundleHandler(), forURLScheme: Car3DBundleHandler.scheme)

        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.navigationDelegate = self

        if Bundle.main.url(forResource: "car3d", withExtension: nil) == nil {
            message = "car3d 资源没有打进 App 包"
        }

        if let url = URL(string: "\(Car3DBundleHandler.scheme)://model/index.html") {
            view.load(URLRequest(url: url))
        }

        webView = view
        return view
    }

    // MARK: JS → Swift

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        DispatchQueue.main.async {
            if text == "ready" {
                self.isReady = true
                self.message = nil
                // 模型就绪后补推一次当前状态，避免加载期间的更新被丢掉
                if self.lastPayload.isEmpty == false {
                    self.evaluate("window.Car3D && window.Car3D.applyStatus(\(self.lastPayload));")
                }
            } else if text.hasPrefix("error") || text.hasPrefix("jserror") || text.hasPrefix("rejection") {
                self.message = text
            }
        }
    }

    // MARK: 页面加载

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isReady { message = "页面已加载，等待 3D 模型…" }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        message = "页面加载失败：\(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        message = "无法打开 3D 页面：\(error.localizedDescription)"
    }

    // MARK: Swift → JS

    func apply(payload: [String: Any]) {
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

    private func evaluate(_ script: String) {
        guard let view = webView else { return }
        DispatchQueue.main.async {
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

// MARK: - 3D 车辆卡片（数据直接叠在模型上）

struct Car3DCard: View {

    let status: CarStatus
    let isLocked: Bool
    let tire: TirePressure?

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

    private var signature: String {
        let doorSig = doors.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value ? 1 : 0)" }.joined()
        let windowSig = windows.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value ? 1 : 0)" }.joined()
        return doorSig + "|" + windowSig
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.12, blue: 0.16),
                                 Color(red: 0.02, green: 0.03, blue: 0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Car3DModelView()
                .clipShape(RoundedRectangle(cornerRadius: 22))

            if !bridge.isReady {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(bridge.message ?? "正在加载 3D 车辆模型…")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            }

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    statPill(icon: "battery.75", value: batteryText, unit: "电量")
                    statPill(icon: "bolt.fill", value: rangeText, unit: "续航")

                    Spacer(minLength: 4)

                    HStack(spacing: 6) {
                        circleButton(systemName: autoRotate ? "rotate.3d.fill" : "rotate.3d") {
                            autoRotate.toggle()
                            bridge.setAutoRotate(autoRotate)
                        }
                        circleButton(systemName: "arrow.counterclockwise") {
                            bridge.resetView()
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        statPill(icon: isLocked ? "lock.fill" : "lock.open.fill",
                                 value: isLocked ? "已上锁" : "已解锁",
                                 unit: "车锁")
                        statPill(icon: "road.lanes", value: mileageText, unit: "总里程")
                    }

                    Spacer(minLength: 4)

                    tirePanel
                }
            }
            .padding(12)
        }
        .frame(height: 360)
        .onAppear { bridge.apply(payload: payload) }
        .onChange(of: signature) { _ in bridge.apply(payload: payload) }
    }

    // MARK: 覆盖在模型上的数据

    private var batteryText: String {
        guard let soc = status.batterySOCPercentage else { return "—" }
        return "\(soc)%"
    }

    private var rangeText: String {
        guard let km = status.remainingMileage else { return "—" }
        return "\(km) km"
    }

    private var mileageText: String {
        guard let km = status.totalMileage else { return "—" }
        return "\(km) km"
    }

    private func statPill(icon: String, value: String, unit: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.cyan)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text(unit)
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.38))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        )
    }

    private func circleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(Color.black.opacity(0.35))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.8))
        }
    }

    private var tirePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 9))
                    .foregroundColor(.cyan)
                Text("胎压 kPa")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }

            HStack(spacing: 8) {
                tireValue("左前", tire?.lf)
                tireValue("右前", tire?.rf)
            }
            HStack(spacing: 8) {
                tireValue("左后", tire?.lr)
                tireValue("右后", tire?.rr)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.38))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        )
    }

    private func tireValue(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 7))
                .foregroundColor(.white.opacity(0.45))
            Text(value.map { String(format: "%.0f", $0) } ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(tireColor(value))
        }
    }

    private func tireColor(_ value: Double?) -> Color {
        guard let value = value else { return .white.opacity(0.4) }
        if value < 200 { return .red }
        if value > 280 { return .orange }
        return .green
    }
}
