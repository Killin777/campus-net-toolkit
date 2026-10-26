# 修改须知

> 给后续接手这个项目的人（包括 AI 助手）。
> 这份文件只写**会真的出事**的东西，不是风格指南。
> 每一条都对应一次实际事故。

---

## 0. 三十秒速查

```powershell
# 改完代码，跑这个。不通过就别提交。
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1

# 改完界面，跑这个。肉眼看图，不要凭想象。
powershell -NoProfile -ExecutionPolicy Bypass -File src\网络优化器.ps1 -Screenshot -Out docs\_ui.png

# 验证关闭行为（进程应自行退出，退出码 0）
powershell -NoProfile -ExecutionPolicy Bypass -File src\网络优化器.ps1 -AutoClose
```

三条都过，再谈提交。

---

## 1. 运行环境：只能是 PowerShell 5.1

目标机器是 Windows 自带的 `powershell.exe`（5.1），**不是 PowerShell 7**。

**禁止使用**以下语法，5.1 会直接语法错误：

| 禁用 | 原因 | 替代 |
|---|---|---|
| `$a ?? $b` | 空合并运算符是 7.0+ | `if ($null -eq $a) { $b } else { $a }` |
| `$a?.b` | 空条件运算符是 7.0+ | `if ($a) { $a.b }` |
| `$x ? 'a' : 'b'` | 三元运算符是 7.0+ | `if ($x) { 'a' } else { 'b' }` |
| `ConvertFrom-Json -AsHashtable` | 6.0+ | 用 `PSObject.Properties` 遍历 |
| `Get-Content -AsByteStream` | 6.0+ | `[IO.File]::ReadAllBytes()` |

写完后用解析器自检，**这是最便宜的一道保险**：

```powershell
$e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    'src\网络优化器.ps1', [ref]$null, [ref]$e)
$e.Count   # 必须是 0
```

---

## 2. 编码：这是本项目第一大事故源

### 2.1 所有 `.ps1` 必须有 UTF-8 BOM

没有 BOM 时，PowerShell 5.1 按 **GBK** 读文件，中文变乱码，**语法直接崩**。

```powershell
# 补 BOM（无 BOM → 有 BOM）
$p = 'src\lib\Whatever.ps1'
$t = [IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($p, $t, [Text.UTF8Encoding]::new($true))
```

**实际事故**：`NetworkState.ps1` 以无 BOM 落地，`Common.ps1` 点源它，整个程序启动即崩（退出码 1），表现为"双击 exe 没反应"。
**这条不是风格问题，是"打不开"级别的问题。**

### 2.2 `.cmd` / `.bat` 必须是 GBK（cp936）

命令提示符不认 UTF-8 的中文。`tests\Test-Encoding.ps1` 会检查这一点。

### 2.3 lib 模块必须声明 UTF-8 输出

被主程序用 `Start-Process -RedirectStandardOutput` 捕获时，输出编码决定一切。

新建 `src/lib/*.ps1` 时，在 `$ErrorActionPreference = 'Continue'` 之后加上：

```powershell
# 输出编码统一为 UTF-8：被 GUI 重定向捕获时，避免按 GBK 解码出现乱码
if ([Console]::IsOutputRedirected) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}
```

### 2.4 捕获子进程输出，只能用 `Invoke-ChildCapture`

不要写 `$out = & powershell.exe -File xxx.ps1`——主程序是无控制台的 WinForms 进程，直接用 `&` 会按错误的代码页解码。

`Invoke-ChildCapture` 做的是**字节级解码**：先试严格 UTF-8，失败回退 GBK。这样无论子脚本用哪种编码都能正确处理。

---

## 3. 目录与数据

```
项目根/
├─ 网络优化器.exe        启动器（winexe，无控制台）
├─ 网络优化器.cmd        命令行入口（GBK 编码）
├─ src/
│  ├─ 网络优化器.ps1     主程序（WinForms）
│  ├─ ProxyCtl.ps1       代理状态与验证
│  ├─ ModeCtl.ps1        模式切换与还原
│  └─ lib/               可独立运行/测试的模块
│     ├─ Common.ps1
│     ├─ NetworkState.ps1
│     ├─ RouteGuard.ps1
│     ├─ CampusPortal.ps1
│     └─ CampusCheck.ps1
├─ config/               用户配置（proxy-config.json 等，已 gitignore）
├─ runtime/              运行期数据、备份、日志（已 gitignore）
├─ legacy/               旧脚本，保留参考
├─ docs/                 文档与截图
└─ tests/                测试套件
```

**铁律：**

- **写数据只写 `runtime\`**，永远不要往 `config\` 或 `src\` 写运行期数据
- `config\` 里放的是**用户手改的配置**，程序只读
- `runtime\` 保存启动偏好、生成设置和还原记录。尚未还原时不可清空；清空会丢失恢复依据。EXE 的程序缓存 `app\` 可以重新释放，但不能与运行数据混淆

---

## 4. 点源（dot-source）约定

`lib/` 下的文件会被主程序和其他模块点源，必须遵守：

1. **Common/NetworkState 这类纯函数库绝不要在顶层定义 `param()`** —— 点源时会把调用方的同名变量覆盖掉。Portal/CampusCheck/RouteGuard 这类独立 CLI 可以按第 13 节保留 `param()`，调用方必须隔离或保存恢复同名参数。
   真事故：`ProxyCtl.ps1` 的 `param($Action)` 覆盖了主程序的 `$Action`，导致一系列诡异行为。
2. **必须有 `-NoRun` 开关** —— 直接运行能出结果，被点源时不执行主逻辑。
3. **`Common.ps1` 要求调用方先定义 `$script:ProjRoot`**，否则它会 `throw`。
4. 需要"临时改全局变量"时，用保存/恢复：

```powershell
$oldAction = $Action
. (Join-Path $PSScriptRoot 'ProxyCtl.ps1') -NoRun
$Action = $oldAction
```

---

## 5. 修改网络状态：先备份，再动手

任何修改系统的操作，必须满足：

1. **先备份**到 `runtime\*.json`（DNS、代理三键、跃点、服务启动类型）
2. **能还原**——还原逻辑必须真的把原值写回去，写不回去就别声称"可回滚"
3. **要确认**——停服务、重启网卡、改路由这类操作，交互模式必须问一次；非交互模式（`[Console]::IsInputRedirected`）**默认跳过**，绝不静默执行

**真事故**：界面写着"所有改动均可回滚"，但代码里根本没生成备份。承诺跑在实现前面，等于欺骗。

### 不要把自己的断网算进统计

工具自己重启网卡导致的断链，必须从统计里排除：

```powershell
Add-IgnoreWindow '操作名称' 40   # 40 秒窗口
```

否则用户会看到"我一用这个工具就断网"的假象。

---

## 6. 发布与同步：绝对不要整目录覆盖

**真事故**：把脱敏后的发布副本整个同步回安装目录，代码里的 `223.5.5.5` 变成了字面量 `<IP>`，`Resolve-DnsName '<IP>'` 直接抛异常，程序崩溃。

规则：

- 同步**只能按文件清单**逐个复制，不能 `Copy-Item -Recurse` 整个 `src/`
- **脱敏只能作用于文档和个人标识**（SSID、主机名、学号、安装路径、私有 IP），**绝不能碰代码常量**
- 公开 DNS（`223.5.5.5`、`119.29.29.29`）不是隐私，脱敏它们是错的
- 同步后立刻对比哈希：

```powershell
Get-ChildItem src -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring((Resolve-Path src).Path.Length + 1)
    $a = (Get-FileHash $_.FullName -Algorithm MD5).Hash
    $b = (Get-FileHash (Join-Path $repo "src\$rel") -Algorithm MD5).Hash
    if ($a -ne $b) { "差异: $rel" }
}
```

---

## 7. 字符串替换：不要盲替换

**真事故**：全局把 `Administrator` 替换成占位符，结果打断了 `#Requires -RunAsAdministrator` 和 `[WindowsBuiltInRole]::Administrator`，5 个文件语法损坏。

规则：

- 替换前先统计命中数（`Select-String | Measure-Object`）
- 替换后立刻跑语法检查
- 宁可逐个精确替换，也不要 `-replace` 全文件

---

## 8. 界面改动：必须出图验证

改 UI 后**不能凭想象确认**，必须渲染截图并真的看图：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File src\网络优化器.ps1 -Screenshot -Out docs\_ui.png
```

已内置的截图/自测开关：

| 开关 | 用途 |
|---|---|
| `-Screenshot -Out <png>` | 渲染主界面并存图 |
| `-Help -Out <png>` | 渲染使用说明窗口 |
| `-Settings -Out <png>` | 渲染设置对话框 |
| `-AutoClose` | 1.2 秒后自动关窗，用于验证"关闭后进程退出" |

**坑**：`Form.Hide()` 在 `ShowDialog()` 模态下**不生效**。所以"关闭窗口最小化到托盘"这类设计在本项目里验证过是坏的，已移除。关闭就是退出。

---

## 9. 已知的平台坑（改代码前先看）

| 现象 | 根因 | 处理 |
|---|---|---|
| 中文乱码 | 文件无 BOM / 输出编码不一致 | 见第 2 节 |
| `Count` 永远是 1 | PS 5.1 `ConvertFrom-Json` 把单元素数组拆成对象 | 用 `Get-JsonList` |
| 链路速率算不出来 | `LinkSpeed` 返回 `"0 bps"` 这种字符串 | 先正则解析再除 |
| 断网时流量进黑洞 | 断开状态的以太网仍留着默认路由 | 只统计 `Status -eq 'Up'` 的网卡 |
| 网关被当成 DNS 服务器 | 网关不提供 DNS | 超时标灰「网关不提供 DNS（正常）」 |
| 外部进程关不掉窗口 | UIPI：低权限进程不能给提权窗口发 `WM_CLOSE` | 用 `-AutoClose` 自测，别用外部进程测 |
| 进程关了还有 conhost | `powershell.exe` 是控制台程序 | 启动器用 `CreateNoWindow`；这是正常现象 |
| `Start-Process -Verb RunAs` 不能同时重定向输出 | 参数集互斥 | 让被测脚本自己写文件 |

---

## 10. 合规红线（不可协商）

这个工具运行在校园网环境，以下行为**永远不要实现**：

- ❌ 自动登录、代填账号密码、保存凭据
- ❌ 绕过认证、破解限速、伪造 DHCP
- ❌ MAC 克隆、多拨、单线多号
- ❌ 共享账号、开热点给他人、把代理端口开放到局域网（`allow-lan`）
- ❌ 代替学校官方认证系统

**可以做**：检测是否已认证、打开登录页（用户自己输密码）、只读测量、本地配置修正（DNS/MTU/跃点）。

代码里已有的边界声明（`CampusPortal.ps1` 头部注释）请保持。

---

## 11. 产品原则：不要说过头话

- 声称"可回滚" → 必须真的有备份和还原
- 声称"优化" → 必须能给出前后对比数据
- 做不到的事直接写"不做"（游戏加速、注册表 TCP 调参都是伪优化）
- 界面文案和实际行为**必须一致**；不一致时改文案，或者改行为，不能放着

---

## 12. 提交规范

**一个改动一个提交。** 不要把"修 bug + 加功能 + 改文档"塞进同一条 commit——
出问题时没法只回滚其中一项，也没法说清是哪次改动引入的。

判断标准：提交信息里如果出现"和""以及""顺便""同时"，基本就该拆开。

```
<type>: <一句话说明>

fix      修 bug
feat     新功能
refactor 重构（行为不变）
docs     文档
test     测试
chore    构建、依赖、格式
```

拆分的实操顺序：

1. 先只暂存 A 改动的文件/片段 → 提交
2. 再暂存 B → 提交
3. 同一文件里两处不相关的改动，用 `git add -p` 分块暂存

**修改顺序建议**：先修 bug（可回滚），再加功能（可单独回滚），最后改文档。

不要做的事：

- 一条提交里既改代码又改版本号（版本号单独一条 `chore: bump x.y.z`）
- 一条提交里既有功能又有格式全量重排（格式改动单独一条，便于 `git blame` 跳过）
- 提交前不跑测试就推（本项目已发生多次：推上去才发现红）
## 13. 新增一个 lib 模块的完整步骤

以 `src/lib/Foo.ps1` 为例：

1. 文件头写 `#Requires -Version 5.1` + 说明注释（职责、边界、用法）
2. 加 `param([ValidateSet('check','json')][string]$Action='check', [switch]$NoRun)`
3. `$ErrorActionPreference = 'Continue'` 之后加 UTF-8 输出声明
4. 主函数返回结构化对象（`Findings` 数组 + `Worst` 汇总），不要直接 `Write-Host` 里夹逻辑
5. **只读模块绝不能改系统**
6. 结尾加：
   ```powershell
   if (-not $NoRun) {
       switch ($Action) {
           'check' { [void](Show-FooReport) }
           'json'  { Get-FooReport | ConvertTo-Json -Depth 5 }
       }
   }
   ```
7. **保存为 UTF-8 with BOM**
8. 在 `tests\Test-Encoding.ps1` 的文件清单里加一行
9. 用 CLI 实际跑一遍，确认中文正常：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File src\lib\Foo.ps1 check
   ```
10. 需要接进界面时，用 `Invoke-LibCheck 'lib\Foo.ps1' '标题'`

---

## 14. 提交前自检清单

- [ ] 所有改动过的 `.ps1` 有 BOM
- [ ] 所有 `.ps1` 解析错误为 0
- [ ] `tests\run-all.ps1` 全绿
- [ ] 界面改动出过截图，并且**真的看过图**
- [ ] 新增的写操作有备份 + 还原路径
- [ ] 没有把真实隐私（SSID / 主机名 / 私有 IP / 学号）写进代码
- [ ] 没有整目录覆盖安装目录
- [ ] 文案与实际行为一致
- [ ] `CHANGELOG.md` 已更新

## 15. 构建与发布：只能用 tools\Build.ps1

**真事故**：手工用 `csc` 编译了一个 5 KB 的简易启动器覆盖了部署的 exe，导致发布包测试全线失败——因为正式启动器内嵌了 `Toolkit.Payload.zip` 和 `Toolkit.Manifest.json`，手写的没有。

```powershell
# 正确做法：先构建到候选目录，测试通过再替换
powershell -NoProfile -File .\tools\Build.ps1 -OutputDirectory .\_qa\candidate
powershell -NoProfile -File .\tests\run-all.ps1 -ExecutablePath .\_qa\candidate\网络优化器.exe
Copy-Item .\_qa\candidate\网络优化器.exe .\网络优化器.exe -Force
```

规则：

- 改了 `src/`、`assets/`、`VERSION` 之后**必须重建 exe**，否则 EXE 内置的哈希与源码不一致，`Test-Package` 会报"需重建"
- 新增运行依赖文件必须同步加进 `tools\package-files.json` 白名单
- 部署后的 exe 不在仓库里（构建产物），仓库只存源码

## 16. 测试脚本的路径陷阱

`param()` 的默认值里**不能**用 `$PSScriptRoot`：

```powershell
# 错：用 -File 调用时 $PSScriptRoot 还是空的
param([string]$ExecutablePath = (Join-Path (Split-Path -Parent $PSScriptRoot) '网络优化器.exe'))

# 对：先取根目录，再补默认值
param([string]$ExecutablePath)
$root = Split-Path -Parent $PSScriptRoot
if (-not $ExecutablePath) { $ExecutablePath = Join-Path $root '网络优化器.exe' }
```

现象是 `Split-Path : Cannot bind argument to parameter 'Path' because it is an empty string`，
而用 `.\tests\run-all.ps1` 这种点斜杠方式调用又不会触发——很容易被误判成"测试坏了"。

---

### 改完源码必须"重建 + 重启"

EXE 会把程序解包到 `%LOCALAPPDATA%\CampusNetToolkit\app\<版本号-内容哈希>\` 再运行。
只改 `src\` 不重建，或者重建了但**没有关掉正在运行的窗口**，界面里跑的都还是旧代码——
表现为"我已经修好了但报错照旧"。

判断当前跑的是哪份代码：

```powershell
Get-ChildItem "$env:LOCALAPPDATA\CampusNetToolkit\app" -Directory |
    ForEach-Object { "$($_.Name)  $($_.LastWriteTime)" }
```

最新的那个目录里的 `src\ModeCtl.ps1` 哈希应与源码一致；不一致就是旧版。