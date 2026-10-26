# 历史与兼容材料

当前使用入口为根目录 `网络优化器.exe`，维护入口为 [docs/README.md](../docs/README.md)。本目录保留旧代码和原入口材料，避免把历史做法当作现行能力。

- `ClashCtl.ps1`、`Fix-WifiStability.ps1`、`Fix-Roaming-Param.ps1`、`Optimize-Network.ps1`：旧版独立脚本，根目录对应 CMD 仍保留兼容转发。旧脚本不属于单 EXE 发布包。
- `GuiActions-v1.2.ps1`：已从现行 GUI 移除的批量优化与低延迟函数，仅保留源码参考，不作为当前主入口执行。
- `shortcuts/`：原根目录的 9 个本机快捷方式，移动前已核对其目标存在。快捷方式含本机绝对路径，不能作为便携发布入口；目标 CMD/EXE 的根目录位置保留。
- `releases/网络优化器-v1.2启动壳.exe`：原 5 KB 启动壳，替代品为根目录新版 EXE。仅作为历史对照，仍依赖旁边的源码目录。

原始对比文件与临时检查材料在 `_qa/before`；原有配置、运行日志和恢复备份继续保留。高级 CLI 的 `game` 仍可按明确确认调用，但不会宣传为降低游戏延迟的保证。
