# 首台 iPhone 试跑指南

> 皓哥的实际情况：**Windows 无 Mac** + iPhone 15 Pro Max + 第一次做 App + 只给自己和团里 10 人用
> 目标：把你自己剪出来那个 ipa，装到自己的手机上跑起来

---

## 结论先说

**能跑，而且这条路跟将来发给团里队友是同一条管道** —— 现在搭一次，后面两种需求都归它管。

但有一笔钱绕不过去：**Apple Developer Program ¥688/年**。没有它，云上打不出能装进你手机的包。

Mac 可以暂时不买。

---

## 一、为什么免费 Apple ID 走不通

很多人听说"免费账号也能真机调试"，这句话在**有 Mac** 的前提下才成立。

| | 免费 Personal Team | 付费 Program（¥688/年） |
|---|---|---|
| 签名在哪生成 | **只能由 Xcode 在本地钥匙串里自动生成** | 后台可以下载 `.mobileprovision` 给任何机器用 |
| 能不能给云构建用 | ✗ 云端拿不到这个 profile | ✓ 这就是 Ad Hoc 的标准做法 |
| 有效期 | **7 天**，一周后 App 直接打不开 | 跟你的会员同步，最长 1 年 |
| App ID 数量 | 限制 3 个，7 天一轮回 | 不限 |

**→ 没 Mac + 没付费会员 = 装不上去。** 皓哥你是前者已定、后者没得选，所以这 ¥688 必须先花。

好消息：Mac 这一项确实能省，代价只是**每一轮调试从 15 秒变成 5 分钟**（详见 §6 什么时候该买 Mac）。

---

## 二、三个时间段，今天该干什么

### 阶段 0 · 今天就能做（完全不用等代码）

这七步做完，你的"签名资格 + 下载通道"就都备好了。**建议现在就做掉**，别等到代码写出来了才想起来 —— 会员审核要时间，那时候你会干等着。

| # | 动作 | 在哪做 | 产出 |
|---|---|---|---|
| 1 | 买会员 | developer.apple.com/programs，用你的 Apple ID 登录，选 Individual ¥688/年 | 中国区需实名（身份证姓名 + 手机号），审核**几分钟到 1 个工作日** |
| 2 | **定 Bundle ID** | 你自己拍板，建议 `com.benka.bkclip` | 反向域名格式，**一次性定死，之后永不能改** |
| 3 | 取 UDID | Windows 装爱思助手，USB 连 iPhone → 设备详情 → 复制 UDID；或手机 Safari 打开 `pgyer.com/udid` 装临时描述文件 | 40 位十六进制字符串 |
| 4 | 注册设备 | Developer 后台 › Devices › ＋ › 名字写「皓哥-iPhone15PM」+ 粘贴 UDID | 设备进白名单 |
| 5 | 建 App ID | Identifiers › ＋ › App IDs › App › Explicit 填第 2 步那个 Bundle ID | **Capabilities 一个都不要勾** |
| 6 | 生成 Ad Hoc profile | Profiles › ＋ › **Distribution › Ad Hoc** › 选刚建的 App ID › 选 Distribution 证书 › 勾选你的设备 › Download | 一个 `.mobileprovision`，存好别丢 |
| 7 | 准备下载地址 | 你已有服务器 49.233.219.150 → 建 `/bk/` 目录 + Nginx | 必须 HTTPS + 正确 MIME |

**关于第 5 步，这是你的 App 独有的好消息**：去气口剪辑只用 AVFoundation + 相册读写，**不需要推送、不需要 iCloud、不需要 App Groups、不需要应用组**。凡是这些都要额外 entitlement（甚至有的和 Ad Hoc 不兼容），咱们一个都不占。所以 profile 一路「下一步」就行，这是最省心的那一类 entitlements。

**第 7 步的 Nginx 两行**（配错 = 点了链接毫无反应，极容易误判成 ipa 坏了）：

```nginx
types {
  application/octet-stream  ipa;
  text/xml                  plist;
}
```

HTTPS 用 Let's Encrypt 免费证书。**不能用自签证书**，iPhone 会直接拒绝安装。

---

### 阶段 1 · 代码写完，出第一个包

```
Windows 改代码 → git push → 云构建 macOS 机器 → 签名出 ipa → 传 /bk/ → 手机 Safari 打开安装
```

**云构建选哪个**

| 方案 | 免费额度 | 适合你吗 |
|---|---|---|
| **Codemagic** | 500 分钟/月 | **推荐**。勾上 automatic code signing 就不用自己折腾证书，网页点点即可，最省事 |
| GitHub Actions macOS | 个人版 2000 分钟/月 | 免费可控，但要自己写 yml + 自己管证书密钥（存 Secrets） |
| EAS Build（Expo） | 15 次 iOS 构建/月 | 如果你用 Expo 工程才顺，本 App 用原生 SwiftUI 就不必要 |

**一个强烈建议：工程用 XcodeGen 管，别手写 `.pbxproj`**

你在 Windows 上没法用 Xcode，而 Xcode 工程里那个 `project.pbxproj` 是人肉维护最痛苦的文件之一 —— 加个源文件、改个 Build Setting 都可能把这个巨型配置文件写坏。

替代方案：仓库里放一个 `project.yml`（几十行文本），云构建时先跑一句 `brew install xcodegen && xcodegen` 自动生成 `BKClip.xcodeproj`，再走 `xcodebuild`。

好处是：**以后你在 Windows 上增删一个 Swift 文件，只是往 yml 里加一行**。AI 帮你改代码也不会弄坏工程。

出包的核心就两条命令：

```bash
xcodebuild archive -workspace BKClip.xcworkspace -scheme BKClip \
  -archivePath build/BKClip.xcarchive \
  -destination 'generic/platform=iOS'

xcodebuild -exportArchive -archivePath build/BKClip.xcarchive \
  -exportPath build/ipa -exportOptionsPlist ExportOptions.plist   # method = ad-hoc
```

---

### 阶段 2 · 手机上第一次（两个开关，各自只需一次）

装完第一次打开会报错 / 打不开，**这是正常的，不是包坏了**：

| 开关 | 路径 | 什么时候要再弄 |
|---|---|---|
| 开发者模式 | 设置 › 隐私与安全性 › **开发者模式** → 打开 | 仅首次 |
| 信任开发者 | 设置 › 通用 › **VPN 与设备管理** › 点你的 Apple ID → 信任 | 仅首次，**后续覆盖升级不用再信** |

之后每次升级：Safari 点一下链接 → 覆盖安装 → 完事。

---

### 阶段 3 · 之后的日常循环

改代码 → push → 云构建 → 传 ipa → Safari 点一次 → 装好。

**唯一必须每次做的事：版本号 +1。**（`CFBundleVersion` / build 号）
忘了加，iPhone 会装到一半失败、或者装完还是老的那版 —— 这是第一次做 App 最常犯的错。建议直接做成脚本自增。

---

## 三、最容易卡住的 6 个点

| 坑 | 症状 | 怎么确认 |
|---|---|---|
| 会员还没审核通过就想出包 | profile 生成不了 / 后台 Ad Hoc 选项是灰的 | 后台首页看有没有绿色 Active |
| Bundle ID 前后不一致 | 签名失败，或者装成了「另一个 App」数据对不上 | 全仓库搜一遍，只允许一个值 |
| **UDID 抄错一位** | 装到一半提示 device not included | 复制别手打，爱思里那个 40 位的才是 UDID（不是序列号、不是 IMEI） |
| 用 http 直链 | 点了链接毫无反应 | iOS 7.1+ 强制 HTTPS |
| Nginx MIME 没配 | 同上「毫无反应」 | 和上面那条症状一样，先查 MIME 再怀疑 ipa |
| 覆盖安装忘了加版本号 | 装失败 / 装完还是老的 | 每次 build +1 |

---

## 四、花多少钱、多少时间

**每年固定**：¥688 会员 + ¥0 服务器（你已有）+ ¥0 构建（免费额度够用）→ **约 ¥688/年**
域名和对象存储可选，非要加也就几十块一年。

**时间预算（诚实版）**：

| 环节 | 第一次 | 之后 |
|---|---|---|
| 会员审核 | 几分钟 ~ 1 个工作日 | 每年一次 |
| 后台七步配置 | 约 40 分钟（摸索） | 加设备时 5 分钟 |
| 配通云构建 | 半天 ~ 一天（必踩坑） | 0 |
| 出一次包装到手机 | 30 分钟 | **15 分钟** |

第一次从零到跑起来，心里准备 **2~3 个折腾的半天**。之后就是一杯茶的功夫。

---

## 五、每年一次的「续命」，别忘了

Ad Hoc 有两个东西会过期，**任一到期，你手机上那个 App 会直接打不开**（不是不能更新，是启动不了）：

1. `.mobileprovision` 描述文件 —— 一年
2. Apple Developer 会员 —— 一年

所以**每年必须重新打包、让所有人重新点一次安装**，即使代码一行没改。
建议立刻在两个地方设提醒：**会员到期前 30 天**、**profile 到期前 30 天**。这件事没有提醒一定会忘，忘了就是全团 App 集体变砖。

（更新链路的具体操作看同一目录下的 `README.md` 发布手册。）

---

## 六、什么时候该买 Mac

现在可以不买。但出现下面任一情况，就该买了：

- 你一天要出 **3 次以上**包 —— 云端一轮 5 分钟 vs 本地 15 秒，差价很快值回票价
- 需要 Instruments 查内存/卡顿 —— 这个 App 处理 4K 长视频，**被系统按内存峰值杀掉是最可能的死因**，云端调试查不了这个
- 需要在控制台实时看 NSLog

二手 M1/M2 Mac mini 约 ¥2500-3500。**建议先跑云端两三个版本，确认这个项目你真的会长期做，再下手。**

---

## 七、开工前 checklist

- [ ] Apple Developer Program 已买，后台显示 Active
- [ ] Bundle ID 已定并抄在显眼的地方（一旦用了就不能再改）
- [ ] iPhone 的 UDID 已复制（40 位，不是序列号）
- [ ] Devices 里已加你的手机
- [ ] App ID 已建，Capabilities 全不勾
- [ ] Ad Hoc profile 已下载保存
- [ ] 服务器 `/bk/` 目录已建，HTTPS 通，Nginx MIME 已配 ipa / plist
- [ ] 仓库里用 XcodeGen（project.yml）而不是手写 pbxproj
- [ ] 云构建能出 ipa
- [ ] 版本号每次自增（做成脚本）
- [ ] 手机上开发者模式 + 信任，都已开过
- [ ] 日历里加了两个「每年续命」提醒
