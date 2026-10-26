# 把「清盘」上传到 GitHub

这份说明假设仓库目录就是 `DiskSweeper/`（含 `App/`、`build.sh`、`README.md`、`LICENSE`）。
命令都在这个目录里执行。

---

## 0. 前置准备

### 0.1 注册 GitHub 账号

打开 https://github.com/signup ，用邮箱注册即可。

### 0.2 确认 git 可用

```bash
git --version
```

macOS 自带；没有的话执行 `xcode-select --install`。

### 0.3 配置提交身份（只需一次）

GitHub 靠邮箱把提交算到你名下。建议用 GitHub 提供的匿名邮箱，避免暴露真实邮箱
（在 GitHub → Settings → Emails 里可以看到 `xxxx@users.noreply.github.com`）。

```bash
git config --global user.name "你的名字"
git config --global user.email "你的GitHub邮箱或noreply邮箱"
```

检查：

```bash
git config --global --list | grep user
```

---

## 1. 在 GitHub 上创建仓库

1. 打开 https://github.com/new
2. **Repository name** 填 `qingpan`（或 `disk-sweeper`，随意）
3. **Description** 可以填：`macOS 大文件扫描与批量清理工具`
4. 选择 **Public**（公开）或 **Private**（私有，自己用）
5. **不要**勾选 "Add a README file"、"Add .gitignore"、"Choose a license"
   —— 本地已经有了，勾了会导致首次推送冲突
6. 点 **Create repository**

创建完会看到一页命令提示，先放着，按下面第 3 步操作。

---

## 2. 顺手改掉 README 里的占位符

`README.md` 里有一处 `<your-name>`：

```bash
# 把 <your-name> 换成你的 GitHub 用户名
sed -i '' 's/<your-name>/你的用户名/g' README.md
```

另外把 `LICENSE` 里的 `xueyatao` 换成你的名字或 ID。

---

## 3. 提交并推送

仓库目录已经初始化过 `git`（`git init -b main` 已执行）。直接：

```bash
cd "路径/DiskSweeper"

# 看一下将提交哪些文件（build/ 已被 .gitignore 排除，不会上传）
git status

git add .
git commit -m "feat: 清盘 v1.1.0 — 全盘扫描 / 类型筛选 / 批量清理"

# 关联远程仓库（把 <你的用户名> 和 <仓库名> 换掉）
git remote add origin https://github.com/<你的用户名>/qingpan.git

git push -u origin main
```

推送时会要求认证。HTTPS 方式**不能用账号密码**，需要 Personal Access Token：

1. GitHub → 右上角头像 → Settings → Developer settings
   → Personal access tokens → **Tokens (classic)** → Generate new token
2. 勾选 `repo` 权限，生成后复制 `ghp_...`（只显示一次）
3. 推送时用户名填 GitHub 用户名，**密码位置粘贴这个 token**

想省事的话也可以装 GitHub CLI：

```bash
brew install gh
gh auth login          # 按提示选 HTTPS + 浏览器登录
gh repo create qingpan --public --source=. --push
```

或者用 SSH（一次配置长期免密）：

```bash
ssh-keygen -t ed25519 -C "你的邮箱"
cat ~/.ssh/id_ed25519.pub        # 复制内容，粘贴到 GitHub → Settings → SSH keys
git remote set-url origin git@github.com:<你的用户名>/qingpan.git
git push -u origin main
```

---

## 4. 发布一个可下载的 DMG（可选）

源码仓库里不含编译产物，想让人直接下载就发一个 Release：

```bash
# 1. 打包 DMG（自动带上「拖到 Applications」快捷方式和卷图标）
./make_dmg.sh
# 产物：build/DiskSweeper-1.1.0.dmg

# 2. 用网页发布：GitHub 仓库 → Releases → Draft a new release
#    Tag 填 v1.1.0，把 build/DiskSweeper-1.1.0.dmg 拖进去即可

# 3. 或者用 gh CLI
gh release create v1.1.0 build/DiskSweeper-1.1.0.dmg \
  --title "清盘 v1.1.0" \
  --notes "全盘扫描、类型筛选、批量清理与撤销"
```

> 注意：未签名的 App 在别人机器上会被 Gatekeeper 拦，README 里已写了「右键 → 打开」的绕行方法。

---

## 5. 以后怎么更新

```bash
git add .
git commit -m "fix: 描述你改了什么"
git push
```

---

## 6. 常见问题

**Q：提示 `remote origin already exists`**
```bash
git remote set-url origin https://github.com/<你的用户名>/qingpan.git
```

**Q：提示 `src refspec main does not match any`**
说明还没提交，先 `git add . && git commit -m "init"`。

**Q：推送很慢或失败（443 超时）**
多半是网络问题，可尝试 SSH 方式，或配置代理：
```bash
git config --global http.proxy http://127.0.0.1:7890
```

**Q：`build/` 会被传上去吗？**
不会，`.gitignore` 里已经排除了 `build/`、`*.iconset`、`.DS_Store`。

**Q：想让别人一看就知道怎么用？**
README 顶部那张截图最关键，`preview/` 里的图请一起提交（当前已包含）。

**Q：仓库名想用中文？**
可以用，但 clone 地址会变成 URL 编码，建议英文名 + 中文 Description。

---

## 7. 上传前自查清单

- [ ] `README.md` 里的 `<your-name>` 已替换
- [ ] `LICENSE` 里的署名已替换
- [ ] `git status` 里没有 `build/`、`.DS_Store`
- [ ] 截图在 `preview/` 且 README 引用路径正确
- [ ] 没有提交任何私人路径、密钥、token
