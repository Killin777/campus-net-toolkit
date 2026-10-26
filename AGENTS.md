# AGENTS.md

本文件给所有在本仓库工作的 AI 助手（Claude / Codex / ChatGPT / DSH 等）阅读。

完整版系统提示词见 [docs/SYSTEM-PROMPT.md](docs/SYSTEM-PROMPT.md)，**开工前请先完整读一遍**。
下面是最小约束集，任何一条违反都会导致返工。

---

## 项目是什么

Windows PowerShell 5.1 + WinForms 桌面工具：校园网代理开关与网络诊断。
运行目录 `D:\desktop\` 下由用户双击 `网络优化器.exe` 使用；本仓库是它的版本库。

## 绝对不能违反的 8 条

1. **`.ps1` 必须 UTF-8 带 BOM + CRLF + 4 空格缩进**，禁止 Tab，禁止行尾空格。
   无 BOM 会被 PS 5.1 当 GBK 读，中文乱码 + 语法错误 = 程序打不开。
2. **`.cmd` / `.bat` 必须 GBK(cp936)**，UTF-8 会让批处理里的中文乱码。
3. **只用 PowerShell 5.1 语法**：禁止 `??`、`?.`、三元运算、`-AsHashtable`。
4. **改完必须重建**：`tools\Build.ps1`。EXE 内嵌发布包，只改 `src\` 不会生效。
   重建后还要**关掉正在运行的窗口**再启动，否则界面里跑的还是旧代码。
5. **禁止手工 `csc` 编译启动器**，只能用 `tools\Build.ps1`（它负责生成 manifest 与内嵌 zip）。
6. **禁止整目录覆盖**、**禁止盲替换字符串**。改之前先数命中数，改之后先做语法校验。
7. **禁止静默吞错**：先 `-ErrorAction SilentlyContinue` 再无脑报成功，会导致还原时必然失败、
   把用户锁死在无法切换模式的状态。
8. **不许声称做不到的事**：不加速、不提速、不做"注册表 TCP 神油"。

## 改动前后必做的验证

```powershell
# 1. 语法校验（必须 0 错误）
$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$e); $e.Count

# 2. 重建
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build.ps1

# 3. 全量测试（8 个套件，必须全绿）
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-all.ps1

# 4. 界面改动必须出图，并且真的看图
powershell -NoProfile -ExecutionPolicy Bypass -File src\网络优化器.ps1 -Screenshot -Out docs\_ui.png
```

## 已知坑（都踩过）

| 现象 | 原因 | 正确做法 |
|---|---|---|
| 双击 exe 没反应 | 文件无 BOM，解析失败 | 补 BOM |
| 修好了但报错照旧 | 运行的是解包后的旧代码 | 重建 + 关窗口 + 重启 |
| `Split-Path : 参数为空` | `param()` 默认值里用了 `$PSScriptRoot` | 改成函数体内取值 |
| 界面中文乱码 | 子进程输出编码不一致 | 用 `Invoke-ChildCapture`（字节级解码） |
| 模式切换被永久卡死 | 受保护服务（DoSvc）改不动却写进了还原记录 | 一开始就不要记录它 |
| 关不掉提权窗口 | UIPI 拦截低权限消息 | 用 `-AutoClose` 等自带开关验证 |

## 汇报格式

1. 改了什么（文件 + 行为变化）
2. 怎么验证的（命令 / 截图 / 日志原文）
3. 还有什么没验证（诚实列出）

不要写"应该可以""理论上没问题"。
