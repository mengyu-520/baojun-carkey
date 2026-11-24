//
//  LoginView.swift
//  carkey
//
//  宝骏账号登录界面：手机号 + 密码 / 手机号 + 短信验证码
//

import SwiftUI

struct LoginView: View {

    @ObservedObject private var dataManager = DataManager.shared

    @State private var mobile: String = ""
    @State private var password: String = ""
    @State private var smsCode: String = ""

    @State private var useSmsCode: Bool = false
    @State private var isBusy: Bool = false
    @State private var isSendingCode: Bool = false
    @State private var errorText: String?
    @State private var hintText: String?

    private var canSubmit: Bool {
        guard mobile.count >= 6 else { return false }
        if useSmsCode {
            return smsCode.count >= 4
        }
        return password.count >= 4
    }

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.black, Color(red: 0.12, green: 0.12, blue: 0.14)]),
                startPoint: .top,
                endPoint: .bottom
            ).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    VStack(alignment: .leading, spacing: 8) {
                        Text("宝骏数字钥匙")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("手机号登录后自动绑定车辆、拉取蓝牙钥匙")
                            .font(.footnote)
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 40)

                    // 登录方式切换
                    HStack(spacing: 0) {
                        modeButton(title: "密码登录", active: !useSmsCode) {
                            useSmsCode = false
                            errorText = nil
                        }
                        modeButton(title: "验证码登录", active: useSmsCode) {
                            useSmsCode = true
                            errorText = nil
                        }
                    }
                    .padding(4)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(12)

                    VStack(spacing: 14) {
                        loginField(title: "手机号") {
                            TextField("请输入手机号", text: $mobile)
                                .keyboardType(.numberPad)
                                .textContentType(.telephoneNumber)
                        }

                        if useSmsCode {
                            loginField(title: "短信验证码") {
                                HStack {
                                    TextField("请输入验证码", text: $smsCode)
                                        .keyboardType(.numberPad)
                                    Button(isSendingCode ? "发送中…" : "获取验证码") {
                                        sendCode()
                                    }
                                    .font(.footnote)
                                    .foregroundColor(.blue)
                                    .disabled(isSendingCode || mobile.count < 6)
                                }
                            }
                        } else {
                            loginField(title: "密码") {
                                SecureField("请输入密码", text: $password)
                                    .textContentType(.password)
                            }
                        }
                    }

                    if let errorText = errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let hintText = hintText {
                        Text(hintText)
                            .font(.footnote)
                            .foregroundColor(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(action: submit) {
                        HStack {
                            if isBusy {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                                    .padding(.trailing, 6)
                            }
                            Text(isBusy ? "登录中…" : "登录")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(canSubmit && !isBusy ? Color.blue : Color.gray.opacity(0.3))
                        .cornerRadius(16)
                    }
                    .disabled(!canSubmit || isBusy)

                    Spacer(minLength: 20)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("说明")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text("- 账号走宝骏官方开放平台登录接口，登录信息只保存在本机 Documents 目录。")
                        Text("- 登录后自动拉取车辆状态与蓝牙数字钥匙；钥匙失效可下拉刷新重新获取。")
                        Text("- 蓝牙解锁需要手机贴近车辆（车端 GATT 服务 0x181A / 0x182A）。")
                    }
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .padding(.bottom, 30)
                }
                .padding(.horizontal, 22)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 子组件

    @ViewBuilder
    private func modeButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(active ? .white : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(active ? Color.blue : Color.clear)
                .cornerRadius(10)
        }
    }

    @ViewBuilder
    private func loginField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
            content()
                .padding(.vertical, 14)
                .padding(.horizontal, 14)
                .background(Color.white.opacity(0.08))
                .cornerRadius(14)
                .foregroundColor(.white)
        }
    }

    // MARK: 动作

    private func sendCode() {
        isSendingCode = true
        errorText = nil
        hintText = nil
        dataManager.sendLoginSmsCode(mobile: mobile) { result in
            DispatchQueue.main.async {
                isSendingCode = false
                switch result {
                case .success:
                    hintText = "验证码已发送，请查看短信"
                case .failure(let error):
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isBusy = true
        errorText = nil
        hintText = "正在登录并同步车辆…"
        simpleHaptic(type: .success)

        let finish: (Result<Void, Error>) -> Void = { result in
            DispatchQueue.main.async {
                isBusy = false
                switch result {
                case .success:
                    hintText = nil
                    errorText = nil
                case .failure(let error):
                    hintText = nil
                    errorText = error.localizedDescription
                }
            }
        }

        if useSmsCode {
            dataManager.signIn(mobile: mobile, smsCode: smsCode, completion: finish)
        } else {
            dataManager.signIn(mobile: mobile, password: password, completion: finish)
        }
    }
}

#Preview {
    LoginView()
}
