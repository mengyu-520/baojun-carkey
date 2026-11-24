//
//  AutoUnlock.swift
//  carkey
//
//  无感解锁的状态模型与信号换算工具
//

import Foundation
import SwiftUI

/// 无感解锁流程状态
enum AutoUnlockState {
    case idle          // 待机
    case nearby        // 已靠近但未触发
    case connecting    // 正在连接
    case unlocking     // 正在鉴权/解锁
    case unlocked      // 已完成无感解锁

    var title: String {
        switch self {
        case .idle: return "待机"
        case .nearby: return "已靠近"
        case .connecting: return "连接中"
        case .unlocking: return "正在解锁"
        case .unlocked: return "已无感解锁"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .gray
        case .nearby: return .yellow
        case .connecting, .unlocking: return .orange
        case .unlocked: return .green
        }
    }

    var systemImage: String {
        switch self {
        case .idle: return "moon.zzz"
        case .nearby: return "dot.radiowaves.left.and.right"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .unlocking: return "lock.open"
        case .unlocked: return "checkmark.circle.fill"
        }
    }
}

/// RSSI → 距离 / 档位 换算
enum BleSignal {
    /// 1 米处的参考信号强度
    static let txPowerAtOneMeter: Double = -59
    /// 路径损耗指数（车内/地面反射环境通常 2.0 ~ 2.5）
    static let pathLossExponent: Double = 2.2

    /// 对数距离路径损耗模型估算距离（米）
    static func estimatedDistance(rssi: Double,
                                  txPower: Double = txPowerAtOneMeter,
                                  n: Double = pathLossExponent) -> Double {
        let raw = pow(10.0, (txPower - rssi) / (10.0 * n))
        return (raw * 10).rounded() / 10
    }

    /// 0 ~ 4 档信号格
    static func bars(rssi: Double?) -> Int {
        guard let rssi = rssi else { return 0 }
        if rssi >= -55 { return 4 }
        if rssi >= -65 { return 3 }
        if rssi >= -75 { return 2 }
        if rssi >= -85 { return 1 }
        return 0
    }

    static func summary(rssi: Double?) -> String {
        guard let rssi = rssi else { return "无信号" }
        switch bars(rssi: rssi) {
        case 4: return "很强（贴近车辆）"
        case 3: return "良好"
        case 2: return "一般"
        case 1: return "较弱"
        default: return "极弱"
        }
    }

    static func distanceText(_ distance: Double?) -> String {
        guard let distance = distance else { return "—" }
        if distance < 1 {
            return String(format: "%.1f 米内", distance)
        }
        return String(format: "约 %.1f 米", distance)
    }
}

/// 无感解锁设置的持久化键
enum BleAutoDefaults {
    static let enabled = "ble.autoUnlock.enabled"
    static let unlockThreshold = "ble.autoUnlock.rssi"
    static let autoLockEnabled = "ble.autoLock.enabled"
    static let autoLockThreshold = "ble.autoLock.rssi"
}
