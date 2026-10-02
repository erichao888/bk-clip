# bk剪辑 · 发布与更新

Ad Hoc 分发的发版脚手架。分两部分：**一次性准备**（只在最开始做一次）和**每次发版**（以后重复执行）。

---

## 一、文件清单

把 `release/` 整个目录传到服务器上，例如 `https://你的域名/bk/`：

```
/bk/
├── index.html          安装落地页（群里的那个链接，点进去看版本和说明）
├── version.json        版本元数据（App 内自检更新也读它）
├── manifest.plist      iOS OTA 安装描述文件
├── bkClip.ipa          安装包本体（发版时替换）
├── icon57.png          57×57 图标，安装弹窗用（可选）
└── icon512.png         512×512 大图标（可选）
```

`UpdateChecker.swift` 不上传，是拷进 Xcode 工程里用的。

---

## 二、一次性准备

### 1. 加入 Apple Developer Program（$99/年）
individual 个人账号即可。这是全部事情的前提。

### 2. 收集每台设备的 UDID
只有登记过的设备能装，这是 Ad Hoc 的硬限制。

让队员用 iPhone 自带 Safari 打开蒲公英或 fir.im 的「获取 UDID」页面，按提示装一个临时描述文件，页面上会显示 40 位 UDID，截图发你。收集齐后在 Developer 后台 Devices 里逐个添加。

### 3. 生成 Ad Hoc profile
Developer 后台 → Profiles → 新建 → **Ad Hoc** → 选 App ID → 选证书 → 勾选全部设备 → 下载，交给云构建服务用。

设备名单之后要加减，就重新生成一次 profile，不需要重新注册 UDID。

### 4. 服务器要求
- **必须 HTTPS**，自签证书不行（iPhone 会拒绝）。用免费的 Let's Encrypt 即可
- Nginx 要返回正确 MIME，否则点了没反应：
  ```nginx
  types {
      application/octet-stream  ipa;
      text/xml                  plist;
      application/json          json;
  }
  ```
- ipa 地址必须能匿名直下，不要挂在需要登录或鉴权的路径后面

### 5. 替换占位符
把三处 `example.com` 换成你的真实域名：

| 文件 | 位置 |
|---|---|
| `manifest.plist` | software-package / display-image / full-size-image 的 url |
| `manifest.plist` | bundle-identifier（例如 `com.benka.bkclip`） |
| `manifest.plist` | bundle-version（填构建号，每次发版要改） |
| `version.json` | url 字段中的 plist 地址（**要 URL 编码**） |
| `UpdateChecker.swift` | `kManifestURL` |

URL 编码对照：`https://a.com/bk/manifest.plist` → `https%3A%2F%2Fa.com%2Fbk%2Fmanifest.plist`

---

## 三、每次发版 · 六步

| 步 | 做什么 | 要点 |
|---|---|---|
| 1 | 电脑改代码，**构建号 +1** | 显示版本号留给有明显新功能时跳；改了本地数据格式必须写迁移 |
| 2 | 提交到 Git | 每次发布打一个 tag，出问题能回滚 |
| 3 | 云构建 IPA（EAS / Codemagic / GitHub Actions） | 产出未签名或已签名的包 |
| 4 | Ad Hoc 签名，上传服务器覆盖旧 ipa | **设备名单没变就不用重新生成 profile** |
| 5 | 改 `manifest.plist` 的 bundle-version + `version.json` 的 version/build/note/date/size | **这两处必须同步改**，漏改会导致 App 反复提示旧版本 |
| 6 | 群里发一句「新版来了」+ index.html 的链接 | 链接地址固定不变，让大家存个书签 |

做完之后，谁在线打开 App 就会自己弹更新提示；不弹的，点群里的链接也能装。

---

## 四、App 内自检更新

`UpdateChecker.swift` 拷进工程，在第一个界面里调用：

```swift
override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    UpdateChecker.checkAndPrompt(on: self)
}
```

行为：启动请求 `version.json` → 比对构建号 → 有新版弹窗 → 点了直接跳安装。同一个 build 默认一天最多打扰一次，`mandatory: true` 时每次都弹（用于修复严重 bug 的版本）。

---

## 五、每年一次 · 续命

profile 有效期一年、会员有效期一年。任一到期，**已安装的 App 会直接打不开**（灰掉或闪退），不是不能更新而已。

到期前做一次完整流程：续费 → 重新生成 profile → 重新构建 → 所有人点一次安装。哪怕代码一行没改也要发这一版。

建议在日历里设两个提醒：到期前 30 天、前 7 天。

---

## 六、坑清单

| 现象 | 原因 |
|---|---|
| 点了链接没反应 | plist 或 ipa 不是 HTTPS；ipa 的 MIME 不对；plist 里的地址带了鉴权 |
| 提示无法安装 | 构建号没递增 / 设备 UDID 没登记 / profile 已过期 |
| 装完打不开，提示未受信任 | 首次安装要在 设置 › 通用 › VPN 与设备管理 里信任一次 |
| 历史数据丢了 | **bundle id 改过**，等于装了另一个 App。从第一天起就别动它 |
| 新版打开就崩 | 改了本地数据结构却没写迁移。启动时用 schemaVersion 判断并转换 |
| App 突然全团打不开 | 会员或 profile 到期，走第五节 |
