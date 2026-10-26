# 构建与封装

`Launcher.cs` 是无控制台窗口的 EXE 入口；`Build.ps1` 负责从白名单生成内置资源、编译与输出 SHA-256。需要修改程序内容时先改 `src`，再重新构建。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build.ps1

# 先构建到候选目录，避免提前替换主入口
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Build.ps1 -OutputDirectory .\_qa\candidate
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-all.ps1 -ExecutablePath .\_qa\candidate\网络优化器.exe
```

构建使用系统 .NET Framework C# 编译器。所谓可重复构建是可按同一命令从源码生成相同功能与资源清单；未承诺 PE 文件逐字节同哈希。每次生成的 SHA-256 用来识别实际产物。

应用图标使用 `assets/lingzhi.ico`（蓝色渐变圆底、简化白狐）。构建时将其写入 EXE 的 Windows 图标资源，同时放入内置程序包，供主窗口、设置、时间线和说明窗口使用。ICO 包含 16、24、32、48、64、128、256 像素七种尺寸；更换图标后需要重新构建。

发布清单见 `package-files.json`。新增运行依赖必须同步加入清单。构建先验证脚本编码和 5.1 语法，再读取每个文件的同一份字节生成哈希与 ZIP，避免清单与资源不一致。

`--verify-package <目录>` 只在指定目录解包并校验；`--smoke-test <目录>` 使用隔离数据渲染界面并自动退出，均跳过真实启动偏好与 UAC，不修改网络。

`--startup-settings` 重新选择并保存启动权限，不启动 GUI。`--admin` 是一次性提权入口。普通使用直接双击即可。
