# CCS21 Antigravity 一键修复

修复 CCS21 左侧 Google Antigravity 显示 **Couldn't load this view** 的兼容性问题。

**v1.2.0：自动检测版本并按实际代码结构修复。** Antigravity 扩展与 agy 后端独立更新；扩展仍是 1.8.0 时，后端可能已经变成 1.4.3。旧版只支持固定前端哈希，导致“CMD 提示成功，页面仍打不开”。

在 **CCS 21.0.1 / Windows x64** 上实测 Antigravity 1.8.0、agy 1.4.2 和 1.4.3。版本号、压缩函数名、变量名或前端哈希变化不再直接拒绝修复：工具会检查实际兼容结构，并单独记录版本和 SHA-256。

每次运行 CMD 都检测扩展版本、已安装 agy 版本以及实际运行的后端前端。每次新建页面代理和请求前端脚本时都重新判断后端兼容性，无需为了常规后端更新重新下载补丁。已知前端使用核对过的哈希规则；未知前端必须匹配完整的来源校验算法，唯一匹配后只增加当前页面的精确来源。

官方扩展更新若覆盖了补丁文件，再运行同一个 `Run-Fix.cmd`，工具会重新检测渲染结构、保留更新后的原文件并重新适配。**不需要为单纯的版本号或压缩命名变化增加白名单。** 若更新改变了协议、渲染接口或完整校验算法，工具会报告具体不兼容结构，保留原文件；无法预先保证任意未来大改都兼容。

## 使用

1. [下载最新完整 ZIP](https://github.com/jiang-zili/CCS21-Antigravity-Fix/archive/refs/heads/main.zip) 并解压，不能只下载 CMD。
2. 先打开 CCS21 和左侧 Antigravity，让 agy 启动；即使页面显示错误也可以继续。
3. 双击 `Run-Fix.cmd`。脚本检查实际运行后端、保存备份、升级旧补丁，并尝试正常重启 CCS21。若出现保存提示，请自行保存。若提示无法定位窗口，在 CCS 命令面板执行 **Reload Window**。
4. 确认左侧聊天输入框和 Antigravity Settings 可以打开。Google 的首次使用条款、数据收集选项和登录由本人处理。

`Fix-CCS21-Antigravity.ps1` 内含全部适配代码，使用 CCS 自带的 Node.js 检查本地后端，修复过程可离线执行，不需要单独安装 Node.js 或重新下载扩展。正常安装不需要管理员权限。CMD 启动器仅为这次脚本进程设置执行策略，不改系统的永久执行策略。

**输出含义：** “installed”表示文件安装及正在运行的后端兼容性检查通过，页面仍需重新加载确认。脚本不会把写入成功当成 UI 验证成功。报告保存在启动器目录的 `AgentOutput`，其中 `uiVerified` 保持 `false`，由实际页面验证另行确认。

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

脚本查找所有数字编号配置目录。存在多个 CCS21 配置时，用 `-ExtensionDir` 指定包含 `package.json` 和 `extension.js` 的实际 `extension` 目录；不会猜测或修改所有副本。`-CcsExe` 可指定 CCS21 可执行文件；`-BackendUrl http://127.0.0.1:PORT` 可指定当前本机后端；`-NoRestart` 安装后保留现有进程，再执行 **Reload Window**。端口每次可能变化，不要复制旧端口。

## 修复原理

CCS21 使用 Theia 的 `http://<view-id>.webview.localhost:<port>` 承载扩展页面。当前 Antigravity 后端的 `frame-ancestors` 和前端消息来源校验没有包含这个来源。

适配器从 `asWebviewUri` 获取当前视图的精确来源，在随机端口创建只监听 `127.0.0.1` 的代理。它为 HTML 的 `frame-ancestors` 增加该精确来源以及 Electron 父窗口所需的 `file:`，并在经过哈希或完整结构验证的 agy 前端中为这一来源增加消息校验分支。原有其他来源判断保留，HTTP、认证头、CSRF 头和 WebSocket 透传；扩展退出时关闭代理。

原始 `extension.js` 和每次修改前的文件保存在扩展目录的 `AgentOutput/CCS21-Antigravity/<原始哈希前12位>/`，按完整 SHA-256 验证，避免不同版本备份混用，并兼容 Windows PowerShell 5.1 路径长度限制。升级时自动识别 v1 的原始备份，并保留旧适配器快照。`installed.json` 记录本次原文件、补丁和适配器哈希。恢复会核对原始哈希并移除本工具的适配文件；未知本地修改会被拒绝覆盖。工具不修改 agy.exe、用户工程、工作区和登录数据，不安装后台常驻服务。

本项目是第三方兼容补丁，不是 TI 或 Google 的官方发布。只发布修复代码，不包含原始 Google 扩展包、账号数据、聊天记录或本机日志。

## 验证与开发

已检查 Windows PowerShell 5.1 语法、来源校验、CSP 保留、认证头透传、WebSocket 升级，以及真实 agy 1.4.2、1.4.3 前端。自动适配测试覆盖模拟新哈希、函数与参数改名、HTTPS 域名列表变化、重复或不兼容校验逻辑拒绝。隔离安装测试覆盖 v1 升级、重复运行、恢复、模拟官方更新覆盖补丁和模拟扩展版本 1.99.0。1.99.0 仅为测试夹具，并非宣称实测了尚未核对的官方发行版。恢复均核对原始哈希。重新加载本机 CCS21 后，1.4.3 聊天输入框、模型选择器和 Settings 页面已恢复显示；未发送模型请求。

开发验证需要 Node.js：

```powershell
& 'C:\ti\ccs2101\ccs\tools\node\node.exe' .\test-adapter.cjs
# 可选：用当前运行的本机 agy 地址做真实前端验证
& 'C:\ti\ccs2101\ccs\tools\node\node.exe' .\test-adapter.cjs http://127.0.0.1:PORT
```

开发时保持 `Fix-CCS21-Antigravity.ps1` 与模板中嵌入的适配器一致。`Build-Script.ps1` 仅进行文本嵌入，不编译或构建 CCS 工程。本项目不包含 TI 工程构建操作。
