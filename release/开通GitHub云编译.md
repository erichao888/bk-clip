# 开通 GitHub 云编译（不用申请，按这里做完就有）

---

## 零、先把概念掰正

**它不需要申请。** 你不是在租一台云 Mac，也不是去哪个网站填表开通服务。

GitHub Actions 是 GitHub 账户自带的功能 —— **只要仓库里放着那个 yml 文件，它就自动生效**。
yml 我已经写好了（`.github/workflows/build-unsigned-ipa.yml`），你要做的只是把代码放进 GitHub 仓库。

「免费额度」也不用领。公开仓库默认就是无限免费；付钱的情况根本不会发生（Free 账号默认设置了 $0 消费上限，超额只会停任务，不会扣款）。

所以这件事的真实工作量是：**注册一个 GitHub 账号 + 把文件夹传上去 + 点一个按钮**。二十分钟的事。

---

## 一、目录必须是这样（最容易错的一步）

GitHub 只认**仓库根目录**下的 `.github/workflows/`。所以：

```
bk-clip/                        ← 这个文件夹「就是」仓库根目录
├── .github/
│   └── workflows/
│       └── build-unsigned-ipa.yml   ✅ GitHub 能扫到
├── project.yml
├── app/
├── docs/
├── release/
└── tools/
```

❌ 常见错误：新建一个仓库，把整个 `bk-clip` 拖进去，变成 `仓库/bk-clip/.github/...`
—— 这样 GitHub 扫不到，Actions 页面是空的，你会以为没开通，其实是多套了一层。

**一句话：bk-clip 里面的东西直接摆在仓库根目录。**

---

## 二、三条路，选一条（推荐 A）

### A. GitHub Desktop（鼠标操作，推荐）

1. **注册**：打开 github.com，用邮箱注册一个账号（有就跳过）
2. **装客户端**：desktop.github.com 下载安装，登录刚才的账号
3. **把我们这个文件夹变成仓库**：
   - 打开 GitHub Desktop → 菜单 `File` → `Add Local Repository...`
   - 路径选 `C:\Users\Administrator\WorkBuddy\2026-10-01-14-22-58\bk-clip`
   - 如果提示「这不是一个 git 仓库」，点 `Create Repository`，名称填 `bk-clip`，**其他都别勾**，确定
4. **发布到 GitHub**：
   - 点右上角的 `Publish repository`
   - 名字 `bk-clip`
   - ⚠️ **取消勾选「Keep this code private」** → 也就是选 Public（公开仓库云编译才免费无限）
   - 点 Publish
5. 等它上传完，浏览器打开 github.com/你的用户名/bk-clip 就能看到文件了

> 关于公开：这个仓库里只有你自己写的一个剪辑小工具的代码。公开的唯一目的就是换免费云编译，
> 不存在「被人拿去发布」的问题 —— 没有你的签名，谁打包出来也装不到手机上。

### B. 命令行（你机器上装了 Git，可以用）

```bash
cd "C:/Users/Administrator/WorkBuddy/2026-10-01-14-22-58/bk-clip"
git init
git add .
git commit -m "bk剪辑 首个版本"
git branch -M main
git remote add origin https://github.com/你的用户名/bk-clip.git
git push -u origin main
```

（先在网页上建一个**空的** Public 仓库，不要勾 README，拿到地址再执行上面这段）

### C. 网页拖文件（最不推荐，但能凑合）

GitHub 网页支持拖拽上传，但**传不了整个文件夹结构**，`.github` 这种隐藏目录网页上也很难处理。
真要这么干，至少保证手动建出 `.github/workflows/` 两层目录再放文件。容易出错，不如 A。

---

## 三、确认 Actions 开着

仓库页面 → `Settings` → 左侧 `Actions` → `General`
→ 最下面 `Actions permissions` 选 **Allow all actions and reusable workflows** → Save。

新仓库默认是开着的，这一步只是兜底检查。

---

## 四、跑第一次编译

1. 仓库页面 → 顶部标签 **Actions**
2. 左侧列表里点 **打包未签名 IPA**
3. 右边 `Run workflow` 下拉 → 绿色的 `Run workflow` 按钮
4. 等 6~10 分钟。页面会出现一个正在转的任务，点进去能看到实时日志
5. 跑完（绿色勾）之后，同一个页面往下滚到 **Artifacts** 区域
6. 点 `bkClip-unsigned-ipa` 下载，解压得到 `bkClip-unsigned.ipa`

拿到这个 ipa 之后，回去看 `爱思助手安装.md` 的第 3 步。

---

## 五、如果 Actions 页面是空的

| 现象 | 原因 | 怎么办 |
|---|---|---|
| Actions 页看不到任何工作流 | yml 多加了一层目录 | 确认它在 `.github/workflows/` 下，且这是仓库根 |
| 看不到工作流 | 文件不在默认分支 | 推到 `main` 分支；新建仓库时若默认分支叫 master，去 Settings 改 |
| 提示 Actions 被禁用 | 权限没开 | 按上面第三节打开 |
| yml 报语法错 | 复制时缩进乱了 | 别手抄，直接传原文件 |

---

## 六、额度到底够不够用

| 仓库类型 | macOS 云主机 | 换算 |
|---|---|---|
| **Public** | **免费无限** | 你随便跑 |
| Private | 2000 分钟/月额度，macOS 按 10 倍折算 | ≈ 实际 200 分钟，一次 6~10 分钟，够跑二三十次 |

选 Public 就完全没有这个顾虑。而且 Free 账号默认消费上限 $0 —— **最坏情况是任务停掉，不会扣你一分钱。**

---

## 七、以后改了代码怎么办

1. GitHub Desktop 里会看到改动，左下角填一句说明 → `Commit to main`
2. 右上角 `Push origin`
3. 回到 Actions 页面再 `Run workflow` 一次，就有新包了

不用重新走一遍注册、建仓库这些步骤。
