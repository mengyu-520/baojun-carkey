import Foundation
import LogView
import OSLog
import SwiftUI

let loggerView = Logger(
    subsystem: "com.sleepyshark.carkey",
    category: "view"
)

// MARK：- haptic helper

func simpleHaptic(type: UINotificationFeedbackGenerator.FeedbackType) {
    let generator = UINotificationFeedbackGenerator()
    generator.notificationOccurred(type)
}

func simpleImpact(style: UIImpactFeedbackGenerator.FeedbackStyle) {
    let generator = UIImpactFeedbackGenerator(style: style)
    generator.impactOccurred()
}

// MARK: - Reusable UI Components

/// 用于显示“左边粗体标签，右边值”的通用行视图
struct InfoRowView: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .bold()
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

struct ApiStatusView: View {
    let error: Error?
    let lastUpdateTime: String?

    var body: some View {
        Text(statusText)
            .font(.footnote)
            .foregroundColor(.secondary)
    }

    private var statusText: String {
        if error != nil {
            return "API获取失败"
        }
        return "数据更新日期: \(lastUpdateTime ?? "从未刷新")"
    }
}

// MARK: - 蓝牙密钥二级页面
struct CarKeyInfoView: View {
    @ObservedObject private var dataManager = DataManager.shared

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("蓝牙密钥详情")) {
                    if let keyData = dataManager.appData.carKeyData {
                        InfoRowView(
                            label: "密钥ID",
                            value: keyData.keyId.masked(percentage: 0.7)
                        )
                        InfoRowView(label: "密钥类型", value: keyData.keyType)
                        InfoRowView(
                            label: "VIN码",
                            value: keyData.vin.masked(percentage: 0.7)
                        )
                        InfoRowView(
                            label: "用户ID",
                            value: keyData.userId.masked(percentage: 0.7)
                        )
                        InfoRowView(
                            label: "蓝牙MAC",
                            value: keyData.bleMac.masked(percentage: 0.7)
                        )
                        InfoRowView(label: "失效时间", value: keyData.endTime)
                        InfoRowView(label: "采集时间", value: keyData.collectTime)
                    } else {
                        Text("尚未获取蓝牙钥匙，下拉刷新重新拉取")
                    }
                }

                Section(header: Text("钥匙失效 / 重新获取")) {
                    Button("重新向云端请求密钥") {
                        dataManager.fetchAndLoadKeyData()
                    }
                }
            }.navigationTitle("数字钥匙")
        }
        .refreshable {
            loggerView.debug("refetching car key data")
            dataManager.fetchAndLoadKeyData()
        }
    }
}

// MARK: - 显示帮助用

extension String {

    /// 对字符串按照百分比进行打码
    func masked(percentage: Double, maskCharacter: Character = "*") -> String {
        let clampedPercentage = max(0.0, min(1.0, percentage))
        let totalCount = self.count
        let maskCount = Int(Double(totalCount) * clampedPercentage)

        guard maskCount > 0 else {
            return self
        }

        guard maskCount < totalCount else {
            return String(repeating: maskCharacter, count: totalCount)
        }

        let clearCount = totalCount - maskCount
        let prefixCount = clearCount / 2
        let suffixCount = clearCount - prefixCount

        let prefix = self.prefix(prefixCount)
        let suffix = self.suffix(suffixCount)
        let maskedPart = String(repeating: maskCharacter, count: maskCount)

        return "\(prefix)\(maskedPart)\(suffix)"
    }
}

// --- 用户信息 Tab ---
struct UserInfoView: View {
    @ObservedObject private var dataManager = DataManager.shared

    var body: some View {
        NavigationView {
            Group {
                if let user = dataManager.appData.userData {
                    List {
                        Section(header: Text("账号")) {
                            InfoRowView(label: "手机号", value: user.userID.masked(percentage: 0.5))
                            InfoRowView(label: "登录状态", value: "已登录")
                        }

                        Section(header: Text("车辆")) {
                            InfoRowView(
                                label: "车型",
                                value: dataManager.appData.carData?.carInfo.carTypeName ?? "—"
                            )
                            InfoRowView(
                                label: "VIN",
                                value: (dataManager.appData.carData?.carInfo.vin ?? (user.vin ?? "")).masked(percentage: 0.5)
                            )
                            InfoRowView(
                                label: "蓝牙钥匙",
                                value: dataManager.appData.carKeyData == nil ? "未获取" : "已获取"
                            )
                        }

                        Section {
                            Button("重新同步车辆与钥匙") {
                                dataManager.bootstrap { _ in }
                            }
                            Button("退出登录", role: .destructive) {
                                dataManager.logout()
                            }
                        }
                    }
                } else {
                    LoginView()
                }
            }
            .navigationTitle("我的")
        }
    }
}

// --- Debug Tab (仅在 DEBUG 模式下编译) ---
#if DEBUG
    struct DebugView: View {
        @State var logViewPresented: Bool = false
        @ObservedObject private var bt = BluetoothManager.shared

        var body: some View {
            NavigationView {
                List {
                    Section("数据注入") {
                        Button(action: {
                            DataManager.shared.injectMockData()
                        }) {
                            Text("注入所有模拟数据")
                        }

                        Button(action: {
                            DataManager.shared.clearAllData()
                        }) {
                            Text("清除所有数据")
                        }
                    }

                    Section("Live log") {
                        Button(
                            "Show log",
                            action: {
                                logViewPresented = true
                            }
                        )
                        Text("logs")
                            .onAppear {
                                LogView.predicate = .subystemIn(
                                    ["com.sleepyshark.carkey"],
                                    orNil: false
                                )
                            }
                            .sheet(
                                isPresented: $logViewPresented,
                                content: {
                                    NavigationView {
                                        if #available(iOS 15.0, *) {
                                            LogView()
                                        } else {
                                            Text(
                                                "Run your app on iOS 15 and upper"
                                            )
                                        }
                                    }
                                }
                            )
                    }

                    Section(header: Text("蓝牙")) {
                        Text("当前状态： \(String(describing: bt.state))")

                        Section(
                            header: Text(
                                "发现的设备 (\(bt.avaliblePeripherals.count))"
                            )
                        ) {
                            if bt.avaliblePeripherals.isEmpty {
                                Text("请开始扫描来发现附近的设备...")
                                    .foregroundColor(.gray)
                                    .padding()
                            } else {
                                ForEach(bt.avaliblePeripherals) { device in
                                    Text(device.id)
                                }
                            }
                        }

                        Button(
                            "开始扫描",
                            action: {
                                BluetoothManager.shared.startScan()
                            }
                        )
                    }
                }
                .navigationTitle("DEBUG")
            }
        }
    }

#endif

// MARK: - Main TabView
/// App 的主 Tab 视图
struct MainTabView: View {

    var body: some View {
        TabView {
            CarControlsView()
                .tabItem {
                    Label("车辆", systemImage: "car.fill")
                }

            UserInfoView()
                .tabItem {
                    Label("我的", systemImage: "person.fill")
                }

            CarKeyInfoView()
                .tabItem {
                    Label("钥匙", systemImage: "key.fill")
                }

            // 仅在 DEBUG 模式下编译
            #if DEBUG

                DebugView()
                    .tabItem {
                        Label("调试", systemImage: "ladybug.fill")
                    }

            #endif
        }
    }
}

// MARK: - Preview
#Preview {
    MainTabView()
        .environmentObject(DataManager.shared)
        .environmentObject(BluetoothManager.shared)
}
