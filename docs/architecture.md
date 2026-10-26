# 架构与维护入口

## 目录职责

| 位置 | 职责 |
|---|---|
| 根目录 EXE / CMD | 主入口与旧路径兼容入口 |
| src/网络优化器.ps1 | WinForms、交互、日志、测量、操作反馈 |
| src/ProxyCtl.ps1 | 配置、代理协议/出口验证与手动系统代理开关 |
| src/ModeCtl.ps1 | 高级 CLI 模式与模式状态还原 |
| src/lib/Common.ps1 | 数据根、参数转义、输出解码、原子 JSON、维护窗口 |
| src/lib/NetworkState.ps1 | 代理、DNS、网络备份采集与恢复，加载时不修改系统 |
| src/lib/CampusPortal.ps1 | 门户探测及 HTTP/HTTPS 登录页地址处理 |
| src/lib/CampusCheck.ps1 | 校园网只读检查与结构化报告 |
| src/lib/RouteGuard.ps1 | 路由、代理目标和监听范围的只读检查 |
| tools / tests | 构建和发布白名单 / 统一验证入口 |
| config / runtime | 只读手工配置 / 生成设置、状态、日志、备份 |
| legacy / docs/history | 旧代码、旧入口 / 历史说明与排障资料 |
| _qa | 本机临时构建、基线与验收证据，不进入发布包 |

## 启动和权限

`EXE → 读取或询问权限偏好 → 必要时请求同一用户的 UAC → 导入旧数据 → 校验并释放资源 → 无控制台启动 PowerShell 5.1 -STA → GUI → 控制器子进程`。

启动器存活到 GUI 退出，用于持有单实例互斥量和记录异常退出码。GUI 不再强制提权覆盖用户选择；普通权限仅在需要机器级修改时提示管理员要求。取消 UAC 不修改网络。跨 Windows 用户的管理员凭据不能管理原用户的 HKCU 代理，因此明确停止该次启动。

关闭窗口即退出。忙碌时禁止并发操作和中途关窗。子进程通过 `Invoke-ChildCapture` 读取原始输出，严格 UTF-8 解码，失败回退 GBK，并检查退出码。等待子进程时处理窗口消息；部分采集与 DNS 测量仍在界面线程，可能有短暂等待。

## 数据根与配置

EXE 的数据根是 `%LOCALAPPDATA%\CampusNetToolkit`，代码缓存在 `app/<版本>-<清单哈希>/`，生成数据保存在 `runtime/`。源码默认以工作区为数据根，也可传 `-DataDirectory`。通过 `CAMPUS_NET_DATA_ROOT` 将路径传给子进程和独立检查模块。

代理设置优先级从低到高：`runtime/imported-proxy-config.json`、`config/proxy-config.json`、`runtime/proxy-settings.json`。校园设置读取导入副本，再读取手工文件覆盖。程序只读 `config`；旧配置导入副本也写在 `runtime`。

首次在旧工作区启动新版 EXE 时，按白名单导入配置和恢复记录，目标存在不覆盖，旧文件不移动，成功后记录 `runtime/legacy-import-v1.json`。导入失败可重试，未完成导入时不会继续修改网络。

## 状态与恢复

| 文件 | 内容与恢复方式 |
|---|---|
| runtime/launcher.json | 启动权限偏好 |
| runtime/proxy-settings.json | GUI 代理设置覆盖值 |
| runtime/proxy-backup.json | 首次修改前的代理、PAC、属性存在性；模式还原恢复 |
| runtime/dns-backup.json | direct CLI 修改前的 DNS 来源和地址；模式还原恢复 |
| runtime/mode-state.json | 服务、电源、无线参数原值；成功逐项消费，失败保留 |
| runtime/network-backup-*.json | DNS、自动/固定跃点、传递优化原值；手动选择恢复 |
| runtime/history | 成功消费的模式备份，保留追溯 |
| runtime/link-events-ignore.json | 工具操作造成的维护窗口 |

JSON 状态先写临时文件，再原子替换；备份失败时中止相应修改。旧格式没有记录的自动/静态来源无法追溯补齐。手动系统代理开关不能代表 TUN、VPN、PAC、WinHTTP 或每个应用的代理状态。

GUI“还原与备份”提供模式还原与网络快照恢复。游戏模式只保留高级 CLI 兼容；切换 direct/proxy 前发现待恢复游戏设置会先还原，失败则停止切换。

## 兼容与维护

Common/NetworkState 是纯函数库，顶层没有 param，点源不执行系统修改。Portal/CampusCheck/RouteGuard 是独立 CLI，保留 param 与 -NoRun；点源者必须保存恢复同名参数，或用子进程隔离。

`.ps1` 必须兼容 Windows PowerShell 5.1 并带 UTF-8 BOM；根目录 CMD 使用 GBK。GUI 的“使用说明”直接读取 [usage.txt](usage.txt)，无需重复维护源码中的文案数组。

构建见 [tools](../tools/README.md)，验证见 [tests](../tests/README.md)，实际证据见 [verification.md](verification.md)。修改源码后必须重新构建 EXE。旧结构摘要保留在 [history](history/architecture-v1.2.md)，以本页为现行入口。
