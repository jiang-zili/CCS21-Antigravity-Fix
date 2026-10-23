# CCS21 Antigravity 一键修复

修复 Windows CCS/Theia 中 Antigravity 的 `Couldn't load this view` 兼容问题。

**v1.3.0：去除固定安装路径、配置编号和版本号限制，按实际文件结构检测。**

[下载最新修复包](https://github.com/jiang-zili/CCS21-Antigravity-Fix/releases/latest) · [下载源码 ZIP](https://github.com/jiang-zili/CCS21-Antigravity-Fix/archive/refs/heads/main.zip)

## 使用

1. 下载 Release 页面提供的完整 ZIP（`Source code (zip)` 同样包含全部修复文件），完整解压。
2. 建议先打开需要修复的 CCS 和 Antigravity，然后双击 `Run-Fix.cmd`。
3. 找到唯一目标时自动处理；存在多个副本时选择正确目录；自动发现失败时通过文件选择窗口定位 `ccstudio.exe` 或包含 Google Antigravity `package.json` 的扩展目录。
4. 修复完成后重载 CCS 窗口。只有能确认原启动进程及其参数时，脚本才尝试正常关闭并保留参数重启；否则提示执行 **Developer: Reload Window**。保存提示由本人处理。

无需另外安装 Node.js，使用所选 CCS 自带的运行时。补丁和检查逻辑已嵌入单个 PS1，可离线运行。CMD 仅为本次进程设置执行策略。普通用户可写的扩展目录不需要管理员权限；受系统权限保护的目录仍需有写入权限。

`Run-Check.cmd` 仅检查，`Run-Restore.cmd` 恢复备份。关闭 CCS 时也可安装；未检测到后端地址时，报告明确标记 `backendVerified: false`，首次打开页面由适配器检查实际后端。不要将“安装完成”当成页面或模型请求验证通过。

## 路径发现

- CCS 安装位置来自正在运行的程序、环境变量 `CCS_HOME` / `CCS_INSTALL_DIR` / `TI_CCS_ROOT`、卸载注册表、开始菜单/桌面快捷方式以及指定搜索根目录。根据 `ccstudio.exe`、相邻 `resources` 和自带 Node 的实际结构识别，不要求目录叫 `ccs21*`，没有固定盘符。
- 扩展目录优先从 CCS 启动参数的 `--user-data-dir`、`--plugins`、`--extensions-dir` 获取，同时识别 Electron 配置的同级 Theia 目录；未发现时检查当前用户 CCS 配置位置。安装位置和配置位置独立处理。
- 配置目录可以使用任意名称。扩展身份通过 `publisher=google`、`name=google-antigravity` 识别，入口读取 `package.main`，支持 `dist/entry.js` 等嵌套路径和省略 `.js` 的入口。
- 支持中文、空格及 Windows 合法特殊字符路径。备份和文件写入使用 Windows 扩展路径形式，避免旧 PowerShell 在深目录下创建备份失败。路径仍须符合 Windows 文件系统、权限和 CCS 自身的要求。
- 自动搜索限定在有关目录内、跳过链接循环；不会遍历整盘。任意深层位置可用 `-ExtensionDir` 直接指定，或以 `-ProfileDir` / `-SearchRoot` 提供较近的搜索起点。自动搜索深度为 6 层，CCS 安装搜索为 3 层，选择窗口不受搜索深度限制。

例如，安装和配置均位于自定义目录时：

```powershell
.\Fix-CCS21-Antigravity.ps1 -CcsExe 'D:\Development Tools\IDE\ccs\theia\ccstudio.exe' -ProfileDir 'E:\CCS profiles\My profile' -NoRestart
```

完全指定目标、禁止选择窗口，适合自动化：

```powershell
.\Fix-CCS21-Antigravity.ps1 -CcsExe 'D:\Tools\IDE' -ExtensionDir 'E:\Plugins\Antigravity\extension' -NonInteractive -NoRestart
```

其他参数：`-CheckOnly`、`-Restore`、`-ReportDir`、`-SearchRoot`、`-BackendUrl http://127.0.0.1:PORT`。端口动态变化，应使用本轮正在运行的后端地址。多个后端默认逐个检查，可显式指定一个目标。

## 版本兼容方式

Antigravity 扩展与 agy 后端可以独立更新。**没有扩展版本号白名单，也不要求某个 agy 安装目录或固定端口。**

脚本唯一匹配渲染方法，支持参数改名、已有 `async`、空白变化、省略日志，以及 `var` / `let` / `const` 和返回调用。写入前由 CCS Node 检查补丁语法。

后端已知前端使用核对过的哈希规则；未知版本必须完整匹配来源校验算法。兼容压缩符号改名、空白、引号风格、布尔值写法和域名列表变化，每次新建页面代理和请求前端脚本时重新检查，只增加当前 Theia 页面精确来源，保留原判断、CSP、认证头和 WebSocket 转发。

**这实现的是路径自由和按结构适配，不是对任意历史或未来协议的保证。** 若版本更改了渲染接口、协议或来源校验算法，工具会报告不兼容；不会为了显示“成功”删除校验或下载其他版本替代。首次安装预检不兼容时保留扩展原文件；运行中更新到不兼容后端时，代理拒绝加载未验证的前端。

官方扩展更新覆盖补丁后，重新运行同一个启动器即可检测新入口、保存新原件并重新适配。

## 备份与报告

扩展原件和每次变更前快照保存在扩展目录的 `AgentOutput/CCS21-Antigravity/<原件哈希前12位>/`，完整 SHA-256 验证，保留原始字节、BOM 和换行。嵌套入口的适配器放在入口同级。`installed.json` 记录原件、补丁和适配器哈希；支持 v1.2 升级、重复运行、更新后的新原件和恢复。

安装报告默认在启动器同级 `AgentOutput`，分别记录安装路径、入口、后端检查和 `uiVerified: false`。`-CheckOnly` 不写安装文件和报告，语法及后端检查只使用完成后清理的临时文件。未知本地改动不会被覆盖。工具不修改 `agy.exe`、工程、工作区、登录数据或 CCS 工程配置。

## 本版验证

Windows PowerShell 5.1 隔离测试覆盖自定义 CCS 根目录、中文/空格/括号/方括号/感叹号路径、非数字配置、嵌套入口、超过传统 MAX_PATH 的备份文件、已有 async、重复/未知接口拒绝、只读检查、安装、重复运行、更新后重装、逐字节恢复及本地修改保护。`99.42.0-future` 是测试夹具，用于确认版本号不被硬编码，不是官方实测发行版。

代理测试覆盖已知规则、模拟未来版本、改名及格式变化、精确来源、CSP、认证头和 WebSocket。另在本机已安装 agy 1.4.5 的环境下，对运行后端进行了只读协议检查和代理测试；未知前端按结构及哈希记录，不将磁盘版本直接等同于运行版本。**本版未覆盖所有 Antigravity 发行版，未在真实 CCS 安装中应用补丁后重启验证页面，也未发送模型请求。**

开发时使用 CCS 自带 Node 运行 `test-adapter.cjs`；`test-installer.ps1 -NodeExe <CCS自带node.exe> -BackendUrl <本地夹具地址>` 测试隔离安装。`test-backend.cjs` 提供仅监听本机的协议夹具。`Build-Script.ps1` 仅将适配器及发现函数嵌入 PS1，是文本生成器，不涉及编译、链接或 CCS 工程构建。

本项目是第三方兼容补丁，不是 TI 或 Google 官方发布。发布包仅含本项目修复代码和文档。
