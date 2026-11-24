//
//  carkeyApp.swift
//  carkey
//
//  Created by Shilapi Chen on 9/8/25.
//

import SwiftUI
import Foundation
import OSLog

let logger = Logger(
	subsystem: "com.sleepyshark.carkey",
	category: "main"
)

@main
struct carkeyApp: App {

	// 复用单例，登录状态变化会驱动根视图切换
	@StateObject private var dataManager = DataManager.shared

	init() {
		WatchSyncManager.shared.startSession()
	}

	var body: some Scene {
		WindowGroup {
			Group {
				if dataManager.appData.userData == nil {
					LoginView()
				} else {
					MainTabView()
				}
			}
			.environmentObject(dataManager)
			.environmentObject(BluetoothManager.shared)
		}
	}
}
