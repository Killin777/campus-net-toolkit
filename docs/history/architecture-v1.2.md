# v1.2 架构约定摘要

现行替代：[../architecture.md](../architecture.md)。本页记录整理前的主要约定，供理解旧脚本和兼容入口使用。

旧结构以根目录 CMD 和本机快捷方式启动 src/网络优化器.ps1，启动即提权。GUI 调用 ModeCtl、ProxyCtl 子进程；Common 提供文本、Ping、维护窗口。配置和运行数据均从项目根推导，分别位于 config、runtime。legacy 保留独立 Clash、WiFi、漫游、批量优化脚本。

原路径约定：不在源码中写绝对路径，src 下用 `$script:ProjRoot = Split-Path -Parent $PSScriptRoot` 推导根。CMD 留在根目录，避免旧快捷方式失效。

原进程隔离理由：带 param 的脚本直接点源会覆盖调用方参数。ModeCtl 复用 ProxyCtl -NoRun 时先保存再恢复 Action。新增模式需要修改 ModeCtl 函数、ValidateSet/switch 和 GUI 模式按钮。

保留的有效经验：netsh 文本依赖系统语言，采集优先 CIM/WMI；网卡重启和高级属性写入可能造成断链，必须记录 Add-IgnoreWindow；属性已是目标值时不要重复写入。PowerShell 5.1 脚本必须带 BOM；原测试包含双版本语法、编码、本地代理协议识别。

本轮将权限选择、稳定数据根、发布资源和恢复入口补齐。旧批量调优函数保留于 legacy/GuiActions-v1.2.ps1，现行 GUI 以只读检查为主。
