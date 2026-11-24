//
//  BleSignalView.swift
//  carkey
//
//  蓝牙信号卡片 + 无感解锁设置
//

import SwiftUI

struct BleSignalCard: View {
    @ObservedObject private var ble = BluetoothManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // 标题 + 状态
            HStack(spacing: 8) {
                Text("蓝牙信号")
                    .font(.caption)
                    .foregroundColor(.gray)
                Spacer()
                Image(systemName: ble.autoUnlockState.systemImage)
                    .foregroundColor(ble.autoUnlockState.color)
                Text(ble.autoUnlockState.title)
                    .font(.caption)
                    .foregroundColor(ble.autoUnlockState.color)
            }

            // 数值
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ble.rssi.map { "\($0)" } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("dBm")
                    .font(.caption)
                    .foregroundColor(.gray)

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(BleSignal.summary(rssi: ble.smoothedRSSI))
                        .font(.footnote)
                        .foregroundColor(.white)
                    Text(BleSignal.distanceText(ble.estimatedDistance))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }

            // 信号格
            SignalBarsView(bars: BleSignal.bars(rssi: ble.smoothedRSSI))
                .frame(height: 22)

            // 平滑值 + 曲线
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("平滑值 \(smoothText)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Spacer()
                    Text(lastSeenText)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                RSSISparkline(values: ble.rssiHistory)
                    .frame(height: 44)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(8)
            }

            Divider().background(Color.white.opacity(0.15))

            // 无感解锁设置
            Toggle(isOn: $ble.autoUnlockEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("无感解锁")
                        .font(.footnote)
                        .foregroundColor(.white)
                    Text("靠近车辆自动连接并解锁，无需手动点按钮")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            .tint(.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("触发距离（信号强于 \(Int(ble.autoUnlockThreshold)) dBm）")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Spacer()
                    Text(String(format: "≈ %.1f m", BleSignal.estimatedDistance(rssi: ble.autoUnlockThreshold)))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                Slider(value: $ble.autoUnlockThreshold, in: -90 ... -45, step: 1)
                    .tint(.blue)
                    .disabled(!ble.autoUnlockEnabled)
            }

            Toggle(isOn: $ble.autoLockEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("走远自动上锁")
                        .font(.footnote)
                        .foregroundColor(.white)
                    Text("仅在本次无感解锁后生效，持续远离 10 秒才触发")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            .tint(.orange)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("上锁距离（信号弱于 \(Int(ble.autoLockThreshold)) dBm）")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Spacer()
                    Text(String(format: "≈ %.1f m", BleSignal.estimatedDistance(rssi: ble.autoLockThreshold)))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                Slider(value: $ble.autoLockThreshold, in: -95 ... -60, step: 1)
                    .tint(.orange)
                    .disabled(!ble.autoLockEnabled)
            }

            if let event = ble.lastAutoEvent {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Text(event)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }

            Text("iOS 只允许前台或刚切后台的一小段时间内持续扫描；锁屏或长时间后台后会暂停，需要打开 App 才能继续无感。")
                .font(.caption2)
                .foregroundColor(.gray.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .cornerRadius(18)
    }

    private var smoothText: String {
        guard let smooth = ble.smoothedRSSI else { return "—" }
        return String(format: "%.1f dBm", smooth)
    }

    private var lastSeenText: String {
        guard let last = ble.lastSeenAt else { return "尚未收到广播" }
        let seconds = Int(Date().timeIntervalSince(last))
        if seconds < 2 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        return "\(seconds / 60) 分钟前"
    }
}

// MARK: - 信号格

struct SignalBarsView: View {
    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0 ..< 5, id: \.self) { index in
                Capsule()
                    .fill(index < bars ? barColor : Color.white.opacity(0.12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 8 + CGFloat(index) * 3.5)
            }
        }
    }

    private var barColor: Color {
        switch bars {
        case 4: return .green
        case 3: return .green
        case 2: return .yellow
        case 1: return .orange
        default: return .red
        }
    }
}

// MARK: - RSSI 曲线

struct RSSISparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard values.count > 1 else { return }
                let maxValue = values.max() ?? -40
                let minValue = values.min() ?? -100
                let span = max(1.0, maxValue - minValue)

                for (index, value) in values.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = geometry.size.height * CGFloat((maxValue - value) / span)
                    let point = CGPoint(x: x, y: min(max(y, 0), geometry.size.height))
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(Color.cyan.opacity(0.9), lineWidth: 1.5)
        }
    }
}

#Preview {
    ZStack {
        Color.black
        BleSignalCard()
            .padding()
    }
}
