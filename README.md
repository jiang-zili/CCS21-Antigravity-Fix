# Antigravity / CCS 自动发现修复工具

**v2.0.2：按实际结构适配版本与安装路径，并修复 Theia 面板销毁时的回调异常。**

修复 CCS / Theia 中 Google Antigravity 的 **Couldn't load this view** 问题。同一脚本从 `package.json` 识别扩展身份、版本和实际入口；通过 Webview API 适配侧栏与 Settings，不再搜索或改写某个版本的 `renderIframe`。

## 双击使用

1. 解压包含本说明和 `Run-Fix.cmd` 的完整 ZIP。
2. 双击 `Run-Fix.cmd`。无需填写扩展版本或安装路径，也可以在 CCS 尚未打开时安装。
3. 重新启动 CCS，确认左侧聊天和 Antigravity Settings 正常加载。保存提示、登录和首次使用的隐私选择由本人处理。

`Run-Check.cmd` 仅检查，`Run-Restore.cmd` 恢复原件。两者沿用相同的自动发现策略。

生成的 `Fix-CCS21-Antigravity.ps1` 自包含全部运行文件，可单独复制使用；无需为修复联网下载依赖或另外安装 Node.js。已有运行中的后端时，会自动寻找 Node（包括 CCS 自带运行时）检查真实前端。IDE 关闭时将后端检查推迟到扩展激活，不把“文件已安装”宣称为界面验证成功。

## 自动识别范围

- **版本**：依据 `publisher=google`、`name=google-antigravity` 识别，不对扩展或 agy 设置版本白名单。未知前端使用 Acorn 解析完整的来源校验谓词，核对结构后只增加当前 Webview 的精确来源。
- **入口**：读取清单 `main`，支持自定义子目录、`.js` / `.cjs` 和省略扩展名的 CommonJS 入口。原文件保留在原位置，相对依赖继续正常解析。
- **路径**：搜索当前用户的配置目录、CCS 启动参数、运行中的 CCS、安装环境变量、注册安装位置和常见部署位置，不限制 `ccs21*`、配置编号、盘符或 `extension` 文件夹名称。常规搜索没有结果时自动回退到可访问的文件系统驱动器；深度搜索不跳过依赖目录。支持空格、Unicode、长路径和可访问的挂载目录。
- **副本**：逐一检查搜索范围内发现的安装，分别保存备份和结果。无法验证或含未知修改的副本保持原样，整体返回非零状态提示注意。
- **后端资源**：从 HTML 脚本标签发现资源，也支持带哈希的 `.js` / `.mjs` 文件名、查询参数和静态模块导入，不再假设前端总叫 `/main.js`。

“不限制版本和路径”表示按实际安装及结构判断，**不能预先保证任意未来协议、ESM 宿主架构或校验算法的大改都兼容**。结构无法验证时明确报告，不删除来源校验或盲目放行。没有访问权限的目录不会被强行修改；未挂载的网络共享不能从本机磁盘枚举，使用 `-SearchRoot` 提供可访问的 UNC 根目录即可。

## 命令与参数

```powershell
# 默认自动发现并修复
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-CCS21-Antigravity.ps1

# 只检查发现结果、状态与当前运行的后端
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-CCS21-Antigravity.ps1 -CheckOnly

# 常规位置之外也完整扫描所有可访问驱动器；耗时取决于目录数量
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-CCS21-Antigravity.ps1 -DeepScan

# 将搜索严格限制在指定目录，支持任意安装位置和网络共享
.\Fix-CCS21-Antigravity.ps1 -SearchRoot 'D:\Portable Apps', '\\server\share\Tools' -NoRestart

# 精确指定某个安装；不影响其他安装副本
.\Fix-CCS21-Antigravity.ps1 -ExtensionDir 'D:\自定义位置\插件目录' -CheckOnly -Json

# 恢复原始清单；旧补丁迁移时同时恢复核对过的原始入口
.\Fix-CCS21-Antigravity.ps1 -Restore
```

`-CcsExe` 和 `-NodeExe` 可显式覆盖自动发现的运行时；`-BackendUrl http://127.0.0.1:PORT` 可选择当前本机后端；`-ReportDir` 可改变报告位置。`-ProfileDir` 是 `-SearchRoot` 的兼容别名；保留 `-NonInteractive` 参数以兼容旧启动命令，v2 本身不弹出选择窗口。`-NoRestart` 保留当前进程，随后完整重启 CCS，让宿主刷新扩展清单。只有能读取原启动参数时才尝试正常重启，以保留配置和工作区；多个窗口或保存提示未完成时不强制结束进程，不创建重复实例。

Windows PowerShell 调用多值参数时，推荐先打开 PowerShell 使用上述 `.\Fix-...ps1` 形式。双击启动器无需传参。`-ExecutionPolicy Bypass` 只作用于该次进程，不修改永久系统策略。

## 备份与恢复

普通安装仅把 `package.json` 的根 `main` 指向工具入口；其他清单内容和原始扩展脚本保持不变。工具入口只向当前扩展及其依赖提供包装后的 VS Code API，其他扩展继续使用原 API。退出时释放代理与加载挂钩。

原清单按 SHA-256 保存在扩展内的 `ccs-antigravity-backup/<哈希前16位>/`；`.ccs-antigravity-state.json` 记录实际入口、原始清单及部署文件哈希。原子写入失败时撤回本次文件变化。重复运行不会拿其他版本的备份覆盖新版本；官方更新覆盖清单后，再运行同一脚本会按新清单重新适配。后端常规更新由运行时重新检查，不依赖固定的 agy 哈希。

可自动迁移本仓库 v1 / v1.2 / v1.3 的已核对补丁，包括嵌套入口及其同级适配器：先校验其备份和当前修改，再恢复原入口并切换到新的接口适配。恢复会移除 v2 的运行文件和活动状态，保留备份供追溯；不会把旧补丁重新装回去。未知本地修改会被拒绝覆盖。

报告默认位于启动器旁的 `AgentOutput/`，包含发现的版本、路径、前端检查与逐安装结果；`uiVerified` 始终由实际界面验证另行确认。报告、备份、原始 Google 扩展、账号和聊天数据不在发布文件中。

## 验证

```powershell
node .\test-adapter.cjs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-installer.ps1

# 可选：核对当前本机 agy；端口每次启动可能变化
node .\ccs21-antigravity-proxy.cjs --check-backend http://127.0.0.1:PORT
```

测试覆盖：重命名、格式化、单/双引号和箭头函数；完整谓词和唯一性检查；注释/字符串伪匹配拒绝；带哈希的脚本与模块路径；压缩响应；精确来源、CSP、认证/CSRF、HTTP 正文、WebSocket 升级及拒绝；冻结的宿主 API；侧栏、自定义编辑器、页面恢复、普通面板、渲染竞争和退出；扩展加载隔离；不同版本与路径、多副本、漏失文件恢复、本地修改拒绝、旧补丁迁移、官方更新、精确恢复及写入失败回滚。测试中的未来版本是人工夹具，不代表实测了这些官方发行版。

v2.0.2 针对 Theia 先销毁面板再触发回调的行为添加了回归测试，并验证销毁时取消待完成渲染。本机运行的后端前端通过只读结构、HTTP 和 CSP 代理检查。v2.0.2 尚未在真实 CCS 中安装重启并验证页面，未发送模型请求。其他发行版以实际接口与结构检查结果为准。

修改源码或模板后，执行 `Build-Script.ps1` 重新生成独立脚本与 `SHA256SUMS.txt`。`ccs-discovery.ps1` 保留为 v1.3 的源码参考；v2 使用模板内的发现实现，不加载该旧模块。本项目不构建或修改 TI 用户工程、CCS 核心或 agy.exe，也不安装常驻服务。

## 实现依据与第三方代码

入口发现采用 [VS Code 扩展清单的 `main` 字段](https://code.visualstudio.com/api/references/extension-manifest)。语法检查使用 [Acorn](https://github.com/acornjs/acorn) 8.15.0；其 MIT 许可证保留在 `vendor/ACORN-LICENSE`，安装时一并部署。解析器仅解析/分词前端，不执行其代码。

本项目为第三方兼容工具，不是 TI 或 Google 的官方发布。
