# 宝骏数字钥匙 iOS（Baojun CarKey）

在 `shilapi/BleCarKey-iOS` 的 BLE 数字钥匙实现基础上，接入了本机 `F:\宝骏云海ipa\baojun_vehicle`（Home Assistant 集成）里那套**宝骏汽车+ 官方开放平台**的登录与签名接口，并补上了完整的登录界面。

> 仅供个人学习交流，不用于任何商业用途。BLE 协议与云端接口版权归上汽通用五菱（SGMW）所有。

---

## 这一版改了什么

| 模块 | 原项目 | 本项目 |
|------|--------|--------|
| 账号体系 | 手工粘贴 accessToken / clientSecret / userID，靠“菱菱邦”MD5 签名，没有登录页 | 手机号 **密码 / 短信验证码** 登录，走 `/oauth/jun/ucenter/login`，凭据取自 baojun_vehicle（`appCode = baojun_plus`、`version = 1.2.11`） |
| 请求签名 | `md5(sorted_params + appkey)` | `sha256(path + accessToken + nonce + timestamp)`，与 baojun_vehicle 的 `client.py` 完全一致 |
| 云端车控 | 只有状态查询 + 蓝牙钥匙查询 | 增加门锁、车窗、寻车、空调、远程启动授权（`doorLock / window / searchCar / acc / ignition/authorize`） |
| 车辆状态解析 | 强类型一次性解码，缺字段就整体失败 | 改为宽松解码（`FlexValue` + 字典），云海/云朵等不同车型缺字段也能出数据 |
| BLE 关键修复 | `GenerateRandomHex8` 不补零（会导致帧内字段错位）、`authOK` 强解包崩溃、无钥匙时也会疯狂扫描 | 已修；扫描前检查钥匙，断开/退出登录有统一入口 |
| 车控按钮 | 网格按钮是空实现（只有点击动画） | BLE 已连接走本地蓝牙，未连接自动走云端兜底 |
| 部署要求 | 依赖 iOS 26 SDK（`glassEffect`）、watchOS 26 | 已移除所有 iOS 26 专属 API，`WATCHOS_DEPLOYMENT_TARGET` 降为 11.0，Xcode 16.x 也能编 |
| 签名配置 | 写死作者的 `DEVELOPMENT_TEAM` | 已清空，bundle id 改为 `com.mengyu.baojuncarkey` |

BLE 协议本身（`0x181A` 的 `2A6E/2A6F` 鉴权、`0x182A` 的 `2A7E/2A7F` 控制、两轮 challenge-response、`masterKey XOR keyMasterRandom` 派生密钥）保持原样——这部分是原作者验证过的。

---

## 目录结构

```
baojun_carkey/
├── carkey.xcodeproj            # Xcode 工程（objectVersion 77，新增 swift 文件会自动纳入编译）
├── carkey/
│   ├── Data/
│   │   ├── SGMW.swift          # 宝骏配置 + 登录 + 签名头（改动最大）
│   │   └── Data.swift          # 宽松解码模型 + 本地持久化
│   ├── Net/
│   │   └── NetThing.swift      # 接口定义 + 登录/同步/云端车控
│   ├── Bluetooth/
│   │   ├── BtThing.swift       # BLE 扫描 / 连接 / 鉴权 / 控制 + RSSI 统计 + 无感状态机
│   │   ├── BtData.swift        # 组帧 + AES-ECB 加解密
│   │   └── AutoUnlock.swift    # 无感状态枚举 + RSSI→距离换算 + 设置持久化键
│   ├── View/
│   │   ├── LoginView.swift     # 新增：登录界面
│   │   ├── BleSignalView.swift # 新增：蓝牙信号卡 + 无感解锁设置
│   │   ├── CarControl.swift    # 车辆页 + 状态卡 + 车控
│   │   └── ContentView.swift   # Tab 容器 / 我的 / 钥匙详情
│   └── carkeyApp.swift         # 未登录 → 登录页，已登录 → 主界面
├── BaoJunKey Watch App/        # watchOS 伴侣（保持原样，最低 watchOS 11）
└── .github/workflows/build-ipa.yml  # 出未签名 ipa 的流水线
```

---

## 打包成 ipa 的三种方式

### 方式 A：GitHub Actions（不需要 Mac）

1. 把整个 `baojun_carkey` 目录推到自己的 GitHub 仓库（原仓库的 `.git` 没有复制过来，直接 `git init` 即可）。
2. 打开 Actions → `Build unsigned IPA` → Run workflow。
3. 跑完在 Artifacts 里下载 `baojun-carkey-unsigned-ipa`，里面是 `baojun-carkey-unsigned.ipa`。

产物是**未签名**的，必须自己签一次才能装：用 Sideloadly / AltStore / TrollStore 侧载。你的机器是 iOS 18.5，TrollStore 用不了（它最高支持到 17.0），只能走 Sideloadly 或 AltStore，用免费 Apple ID 签的话 **7 天要重签一次**。

### 方式 B：自己的 Mac + Xcode

1. 打开 `carkey.xcodeproj`，在 `carkey` target 的 Signing & Capabilities 里选自己的 Team，Bundle Identifier 改成全球唯一（例如 `com.你的名字.baojuncarkey`；watch target 同步改）。
2. 真机连接后 Product → Archive → Distribute App → Development / Ad Hoc 导出 ipa。
3. 或者命令行打包：

```bash
xcodebuild -project carkey.xcodeproj -scheme carkey \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/carkey.xcarchive archive
```

### 方式 C：有 Apple 开发者账号时用 CI 签好（可选）

在仓库 Secrets 里放 `P12_BASE64`、`PROVISIONING_PROFILE_BASE64`、`TEAM_ID`，再改成 `archive + exportArchive` 即可产出可直接安装的 ipa。这一步没做进默认流水线，因为免费账号的证书 7 天就过期。

---

## 使用步骤

1. 首次启动进入登录页：填手机号，选「密码登录」或「验证码登录」。
2. 登录成功后自动：拉车辆列表 → 取 VIN → 拉车辆状态 → 拉蓝牙数字钥匙。
3. 车辆页顶部圆点变绿 = 蓝牙钥匙已连接（鉴权两轮握手完成），此时解锁/上锁走本地 BLE；红点表示未连接，按钮会自动退回云端下发。
4. 「钥匙」页可以看密钥 ID、蓝牙 MAC、失效时间，也能手动重新拉取密钥。

---

## 无感解锁与信号显示（本次新增）

车辆页多了一张「蓝牙信号」卡片，数据全部来自真实广播与 `readRSSI()`：

- **实时信号**：原始 RSSI（dBm）、指数平滑值（0.7 旧 + 0.3 新）、按对数距离损耗模型估算的距离（1 米参考 -59 dBm、路径损耗指数 2.2）、5 格信号条、最近 60 个采样点的曲线。
- **扫描策略**：`options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]`，同一帧广播重复上报才能拿到连续 RSSI；未连接时自动循环扫描（8 秒一轮），连上后广播会停，改由每 2 秒 `readRSSI()` 续命。
- **无感解锁判定**：平滑信号 ≥ 阈值（默认 -62 dBm）并持续 2 秒 → 标记 `pendingAutoUnlock` → 连接 + 两轮鉴权 → `authOK()` 里自动下发 `CarUnlock`。阈值带 **4~6 dB 滞回**，信号抖动不会反复触发。
- **已连接路径**：如果连接是手动/后台建立的，靠近阈值同样会触发解锁，且会先看云端 `doorLockStatus` —— 车已经是开锁状态就跳过，不重复下发。
- **走远自动上锁**（默认关闭）：只对“本次由无感解锁”生效，持续 10 秒低于阈值才下发 `CarLock` 并断开，避免你人在家里车被锁。
- **界面可见状态**：顶部状态点旁边直接显示当前 dBm，卡片里显示「待机 / 已靠近 / 连接中 / 正在解锁 / 已无感解锁」和最近一次触发时间。

**这里必须讲清楚的限制**：iOS 的后台 BLE 扫描受系统限制，`bluetooth-central` 后台模式只在“刚切后台的一小段时间 + 已连接设备周边”有效，锁屏久了扫描会被系统掐掉。所以现在这套是 **App 在前台（或刚切后台）时无感**；要做到真正的锁屏后台无感，需要把 CBCentralManager 换成带 `restoreIdentifier` 的自建实例 + 状态恢复（SwiftyBluetooth 不支持，得单开一轮改）。卡片底部也写了这句提示。

---

## 已知限制（重要）

- **本机（Windows）无法编译验证**。所有代码都是按原工程的 API 与 baojun_vehicle 的接口逻辑改的，但 Swift 编译只能在 macOS / CI 上过。第一次跑 CI 如果报编译错，把 `build-log` 里第一条 error 发我，我按行修。
- **登录接口未实测**。签名规则来自你本地能跑通的 `client.py`，但登录是表单提交，服务端可能只认某一种 content-type；代码里已经做了「mobile / userName 两种字段 × 表单」的降级重试，仍失败就说明账号密码这条路被风控，需要改成纯短信登录。
- **BLE 钥匙能不能真的开锁，取决于车端**：需要云海车机在广播里带头部 manufacturer data（用于匹配 MAC），且 `0x181A/0x182A` 服务存在。上车前建议先用 nRF Connect 扫一次确认。
- **无感解锁的距离是不精确的**：RSSI 受人体遮挡、车门金属、电池仓影响，同一位置可能差 10 dB 以上；建议第一次把阈值调到 -55 左右（更近才触发），确认可靠后再放回 -62。
- **后台无感受 iOS 限制**：见上一节，锁屏长时间后扫描会停。要彻底解决需要重写 CoreBluetooth 层（restoreIdentifier + 状态恢复）。
- **watchOS 伴侣**保留原样，如果 watch 版本低于 11 会装不上伴侣 App；不需要手表功能可以在 Xcode 里把 Watch target 的依赖去掉。
- 云端接口的 `accessToken` 存在本机 `Documents/UserData.json`，没有做 Keychain 加密，介意的话我可以改成 Keychain 存储。
