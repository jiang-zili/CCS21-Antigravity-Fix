# CCS21 Antigravity 一键修复

修复 CCS21 左侧 Google Antigravity 显示 **Couldn't load this view** 的兼容性问题。

适用于已核对的 **CCS 21.0.1 / Antigravity 1.8.0 / agy 1.4.2 / Windows x64**。扩展脚本按 SHA-256 校验，未知构建拒绝修改；代理在运行时校验 agy 前端哈希，未知后端拒绝适配。

## 使用

1. 下载仓库 ZIP 并解压。
2. 双击 `Run-Fix.cmd`。脚本自动查找扩展、保存原始文件、安装补丁，并尝试正常重启 CCS21。若出现保存提示，请自行保存。
3. Google 的首次使用条款、数据收集选项和登录由本人处理。

`Fix-CCS21-Antigravity.ps1` 内含全部适配代码，修复过程可离线执行，不需要管理员权限、Node.js 或重新下载扩展。CMD 启动器仅为这次脚本进程设置执行策略，不改系统的永久执行策略。

也可直接运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-CCS21-Antigravity.ps1
```

仅检查兼容性与安装状态：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-CCS21-Antigravity.ps1 -CheckOnly
```

恢复本次补丁前的原始扩展：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-CCS21-Antigravity.ps1 -Restore
```

存在多个 CCS21 配置时，用 `-ExtensionDir` 指定包含 `package.json` 和 `extension.js` 的 `extension` 目录。`-CcsExe` 可指定 CCS21 可执行文件；`-NoRestart` 安装后保留现有进程，再在 CCS 命令面板执行 **Reload Window**。

## 修复原理

CCS21 使用 Theia 的 `http://<view-id>.webview.localhost:<port>` 承载扩展页面。当前 Antigravity 后端的 `frame-ancestors` 和前端消息来源校验没有包含这个来源。

适配器从 `asWebviewUri` 获取当前视图的精确来源，在随机端口创建只监听 `127.0.0.1` 的代理。它为 HTML 的 `frame-ancestors` 增加该精确来源以及 Electron 父窗口所需的 `file:`，并在经过哈希校验的 agy 前端中为这一来源增加消息校验分支。HTTP、认证头、CSRF 头和 WebSocket 透传；扩展退出时关闭代理。

原始 `extension.js` 保存在扩展目录的 `ccs21-antigravity-backup/extension.js.original`。重复运行保留首次备份；恢复会核对原始哈希并移除本工具的适配文件。扩展或 agy 更新后需要重新确认版本兼容性，官方扩展更新也可能覆盖补丁。

本项目是第三方兼容补丁，不是 TI 或 Google 的官方发布。只发布修复代码，不包含原始 Google 扩展包、账号数据、聊天记录或本机日志。

## 验证与开发

已检查 Windows PowerShell 5.1 语法、扩展 JavaScript 语法、精确来源校验、CSP 保留、认证头透传、WebSocket 升级、未知版本拒绝，以及真实 agy 1.4.2 的前端适配。已验证脚本安装、重复运行和原始哈希一致的恢复。本机重新加载并由用户完成首次使用确认后，聊天输入框、模型选择器和 Antigravity Settings 页面均已正常显示；未发送模型请求。

开发验证需要 Node.js：

```powershell
node .\test-adapter.cjs
# 可选：用当前运行的本机 agy 地址做真实前端验证
node .\test-adapter.cjs http://127.0.0.1:PORT
```

修改 `ccs21-antigravity-proxy.cjs` 或 `Fix-CCS21-Antigravity.template.ps1` 后运行 `Build-Script.ps1`，重新生成自包含脚本。
