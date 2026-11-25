//
//  CarControl.swift
//  carkey
//
//  Created by Shilapi Chen on 9/29/25.
//  Reworked: 真实车辆状态 + BLE 优先 / 云端兜底 的车控按钮。
//

import SwiftUI
import MapKit

// MARK: - 状态模型（供 t/ViewIndicator.swift 使用）
enum StatusState {
    case ok
    case warning(issues: [String])
    case error(issues: [String])

    var iconName: String {
        switch self {
        case .ok: return "checkmark"
        case .warning: return "exclamationmark"
        case .error: return "xmark"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    var title: String {
        switch self {
        case .ok: return "车辆状态正常"
        case .warning: return "发现车辆异常"
        case .error: return "出现错误"
        }
    }
}

struct CarControlsView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var bluetoothManager = BluetoothManager.shared

    @State private var toast: String?
    @State private var isLocked: Bool = true

    private var carStatus: CarStatus {
        dataManager.appData.carData?.carStatus ?? .empty
    }

    private var carInfo: CarInfo {
        dataManager.appData.carData?.carInfo ?? .empty
    }

    private var hasVehicle: Bool {
        dataManager.vin.isEmpty == false
    }

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [Color.black, Color.gray.opacity(0.6)]),
                    startPoint: .top,
                    endPoint: .bottom
                ).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        HeaderView()

                        StatusCard(status: carStatus)

                        Car3DCard(status: carStatus, isLocked: carStatus.isLocked)

                        TirePressureCard(pressure: dataManager.appData.tirePressure)

                        BleSignalCard()

                        PrimaryControlsView(
                            isLocked: $isLocked,
                            canControl: hasVehicle,
                            bleConnected: bluetoothManager.state == .connected,
                            lock: { lockVehicle() },
                            unlock: { unlockVehicle() }
                        )

                        ActionGridView(enableCloud: hasVehicle) { action in
                            run(action: action)
                        }

                        CarLocationView(status: carStatus)

                        ApiStatusView(
                            error: nil,
                            lastUpdateTime: dataManager.appData.carData?.updateDate ?? "从未更新"
                        )

                        Spacer(minLength: 10)
                    }
                    .padding()
                }
                .refreshable {
                    dataManager.fetchAndLoadCarData()
                    dataManager.fetchAndLoadKeyData()
                }

                if let toast = toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.footnote)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(20)
                            .padding(.bottom, 40)
                    }
                    .transition(.opacity)
                }
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            isLocked = carStatus.isLocked
        }
    }

    // MARK: - 动作

    private func showToast(_ text: String) {
        withAnimation {
            toast = text
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { toast = nil }
        }
    }

    private func run(action: CarAction) {
        switch action {
        case .lock:
            lockVehicle()
        case .unlock:
            unlockVehicle()
        case .findCar:
            guard hasVehicle else { showToast("未绑定车辆"); return }
            showToast("已下发寻车指令")
            dataManager.sendCloudControl(.searchCar(vin: dataManager.vin)) { result in
                if case .failure(let error) = result {
                    showToast(error.localizedDescription)
                }
            }
        case .acOn:
            guard hasVehicle else { showToast("未绑定车辆"); return }
            showToast("已下发空调开启")
            dataManager.sendCloudControl(
                .airCondition(vin: dataManager.vin, on: true, temperature: 23, blower: 3, duration: 10, heat: false)
            ) { result in
                if case .failure(let error) = result {
                    showToast(error.localizedDescription)
                }
            }
        case .acOff:
            guard hasVehicle else { showToast("未绑定车辆"); return }
            showToast("已下发空调关闭")
            dataManager.sendCloudControl(
                .airCondition(vin: dataManager.vin, on: false, temperature: 23, blower: 0, duration: 0, heat: false)
            ) { result in
                if case .failure(let error) = result {
                    showToast(error.localizedDescription)
                }
            }
        case .windowClose:
            guard hasVehicle else { showToast("未绑定车辆"); return }
            showToast("已下发关窗")
            dataManager.sendCloudControl(.window(vin: dataManager.vin, close: true)) { result in
                if case .failure(let error) = result {
                    showToast(error.localizedDescription)
                }
            }
        case .powerOff:
            guard bluetoothManager.state == .connected else {
                showToast("蓝牙未连接，无法下电")
                return
            }
            simpleHaptic(type: .warning)
            bluetoothManager.CarPowerOff()
            showToast("已通过蓝牙下发下电")
        }
    }

    private func unlockVehicle() {
        simpleHaptic(type: .success)
        isLocked = false
        if bluetoothManager.state == .connected {
            bluetoothManager.CarUnlock()
            showToast("蓝牙解锁已下发")
        } else if hasVehicle {
            showToast("蓝牙未连接，走云端解锁")
            dataManager.sendCloudControl(.doorLock(vin: dataManager.vin, locked: false)) { result in
                if case .failure(let error) = result {
                    showToast(error.localizedDescription)
                }
            }
        } else {
            showToast("蓝牙未连接且无车辆信息")
        }
    }

    private func lockVehicle() {
        simpleHaptic(type: .success)
        isLocked = true
        if bluetoothManager.state == .connected {
            bluetoothManager.CarLock()
            showToast("蓝牙上锁已下发")
        } else if hasVehicle {
            showToast("蓝牙未连接，走云端上锁")
            dataManager.sendCloudControl(.doorLock(vin: dataManager.vin, locked: true)) { result in
                if case .failure(let error) = result {
                    showToast(error.localizedDescription)
                }
            }
        } else {
            showToast("蓝牙未连接且无车辆信息")
        }
    }
}

// MARK: - 操作项

enum CarAction: String, CaseIterable {
    case lock
    case unlock
    case findCar
    case acOn
    case acOff
    case windowClose
    case powerOff

    var title: String {
        switch self {
        case .lock: return "上锁"
        case .unlock: return "解锁"
        case .findCar: return "寻车"
        case .acOn: return "开空调"
        case .acOff: return "关空调"
        case .windowClose: return "关车窗"
        case .powerOff: return "下电"
        }
    }

    var icon: String {
        switch self {
        case .lock: return "lock.fill"
        case .unlock: return "lock.open.fill"
        case .findCar: return "light.beacon.max.fill"
        case .acOn: return "fanblades.fill"
        case .acOff: return "fanblades.slash"
        case .windowClose: return "arrow.up.to.line"
        case .powerOff: return "power"
        }
    }
}

// MARK: - Subviews

struct CarDisplayView: View {
    var body: some View {
        Image("EQ100")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .offset(x: 14)
    }
}

struct HeaderView: View {
    @ObservedObject private var dataManager = DataManager.shared
    @ObservedObject private var bluetoothManager = BluetoothManager.shared

    @State private var scanningTask: Task<Void, Never>?

    private func startScanningLoop() {
        guard scanningTask == nil else { return }
        guard DataManager.shared.appData.carKeyData != nil else {
            loggerView.debug("no ble key yet, skip scanning")
            return
        }
        loggerView.debug("ble scan task started")
        scanningTask = Task.detached {
            while !Task.isCancelled {
                BluetoothManager.shared.startScan()
                try? await Task.sleep(nanoseconds: 9_000_000_000)
            }
        }
    }

    private func stopScanningLoop() {
        scanningTask?.cancel()
        scanningTask = nil
    }

    private var indicatorColor: Color {
        switch bluetoothManager.state {
        case .connected: return .green
        case .authorizing: return .orange
        default: return .red
        }
    }

    private var indicatorText: String {
        switch bluetoothManager.state {
        case .connected: return "蓝牙钥匙已连接"
        case .authorizing: return "鉴权中"
        case .scanning: return "扫描中"
        case .disconnected: return "未连接"
        case .unknown: return "状态未知"
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(dataManager.appData.carData?.carInfo.displayName ?? "我的宝骏")
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundColor(.white)

                HStack(spacing: 8) {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 8, height: 8)
                    Text(indicatorText)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                    if let rssi = bluetoothManager.rssi {
                        Text("\(rssi) dBm")
                            .font(.caption2)
                            .foregroundColor(.gray.opacity(0.8))
                    }
                }
                .onAppear(perform: startScanningLoop)
                .onDisappear(perform: stopScanningLoop)
            }
            Spacer()
            Button {
                bluetoothManager.startScan()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
        }
    }
}

struct StatusCard: View {
    let status: CarStatus

    var body: some View {
        HStack(spacing: 0) {
            statusItem(
                title: "电量",
                value: status.batterySOCPercentage.map { "\($0)%" } ?? "—"
            )
            divider
            statusItem(
                title: "续航",
                value: status.remainingMileage.map { "\($0) km" } ?? "—"
            )
            divider
            statusItem(
                title: "总里程",
                value: status.totalMileage.map { "\($0) km" } ?? "—"
            )
            divider
            statusItem(
                title: "车锁",
                value: status.isLocked ? "已锁" : "未锁"
            )
        }
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.08))
        .cornerRadius(16)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 34)
    }

    private func statusItem(title: String, value: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.headline)
                .foregroundColor(.white)
            Text(title)
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }
}

struct PrimaryControlsView: View {
    @Binding var isLocked: Bool
    let canControl: Bool
    let bleConnected: Bool
    let lock: () -> Void
    let unlock: () -> Void

    private var disabled: Bool { !canControl && !bleConnected }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: unlock) {
                Label("解锁", systemImage: "lock.open.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(isLocked ? Color.blue : Color.blue.opacity(0.35))
                    .cornerRadius(16)
            }
            .disabled(disabled)

            Button(action: lock) {
                Label("上锁", systemImage: "lock.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(!isLocked ? Color.blue : Color.blue.opacity(0.35))
                    .cornerRadius(16)
            }
            .disabled(disabled)
        }
        .animation(.easeInOut, value: isLocked)
    }
}

struct ActionGridView: View {
    let enableCloud: Bool
    let onAction: (CarAction) -> Void

    private let columns = [
        GridItem(.flexible()), GridItem(.flexible()),
        GridItem(.flexible()), GridItem(.flexible())
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("常用操作")
                .font(.caption)
                .foregroundColor(.gray)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(CarAction.allCases, id: \.rawValue) { action in
                    Button {
                        onAction(action)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: action.icon)
                                .font(.title3)
                            Text(action.title)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .foregroundColor(.white)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(14)
                    }
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(18)
    }
}

struct CarLocationView: View {
    let status: CarStatus

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = status.latitudeValue, let lon = status.longitudeValue,
              lat > 0.0001, lon > 0.0001 else { return nil }
        // 服务端给的是 WGS84，地图需要 GCJ02
        if let gcj = GPSTool.gps84_To_Gcj02(lon: lon, lat: lat) {
            return gcj
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("车辆位置")
                .font(.caption)
                .foregroundColor(.gray)

            if let coordinate = coordinate {
                Map(initialPosition: .region(
                    MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
                    )
                )) {
                    Annotation("车辆", coordinate: coordinate) {
                        Image(systemName: "car.fill")
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .frame(height: 190)
                .cornerRadius(12)
            } else {
                Text("暂无有效定位数据")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(18)
    }
}

// MARK: - Preview
struct CarControlsView_Previews: PreviewProvider {
    static var previews: some View {
        CarControlsView()
    }
}
