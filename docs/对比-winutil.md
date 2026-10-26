# winutil vs 网络优化器：能力对比

> 对比时间：2026-10-25 23:48
> 测试环境：<SSID> 手机热点，<IP>，网关 <IP>

## 一、被对比的两个东西

| | [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) | 本机「网络优化器」 |
|---|---|---|
| 版本 | 26.10.07（906 KB） | v1.0（自建） |
| 星数 | 64,989 | — |
| 最近提交 | 2026-10-23 | 今天 |
| 许可证 | MIT | 随本目录 |
| 签名 | **未签名**（NotSigned） | 未签名 |
| 语法解析 | 0 错误 | 0 错误 |
| 定位 | Windows 装机/精简工具箱 | 单机网络诊断与调优 |

winutil 的实际体量：**38 个 tweak + 234 个 winget 软件包**，重心在"重装系统后一键配置"。

---

## 二、网络能力逐项对比

| 能力 | winutil 26.10.07 | 网络优化器 | 结论 |
|---|---|---|---|
| **延迟/抖动/丢包实测** | ❌ 只测 DNS 的 TCP 握手 RTT | ✅ 连续采样 + 抖动 + 丢包 + 曲线 | 本机工具 |
| **DNS 优选** | ⚠️ 有，但 8 家全是境外 | ✅ 网关 + 阿里 + 腾讯 + 百度 | **本机工具（关键差距见下）** |
| **代理残留检测/原子开关** | ❌ 无 | ✅ 检测死端口 + 提权停内核 | 本机工具 |
| **路由跃点整理** | ❌ 无（无 `Set-NetIPInterface`） | ✅ Radmin/Tailscale 跃点 | 本机工具 |
| **网卡高级参数** | ❌ 无（无 `Set-NetAdapterAdvancedProperty`） | ✅ 漫游/节能/带宽 | 本机工具 |
| **TCP 栈调优** | ❌ 无（无 `netsh int tcp`） | ❌ 也不做（见第四节） | 都没做 |
| **传递优化限流** | ✅ `DODownloadMode` | ✅ `DODownloadMode` | 平 |
| **停更新降占用** | ✅ 可禁用 Windows Update | ✅ 临时暂停，可一键恢复 | 平 |
| **网络重置** | ⚠️ 只有 `netsh winsock reset` + `netsh int ip reset`，粗暴、需重启 | ✅ 分级：清代理 → 刷新 DNS → 续租 IP → 必要时才重启网卡 | 本机工具 |
| **软件安装/卸载预装** | ✅ 234 个 winget 包 | ❌ | winutil |
| **遥测/隐私/服务精简** | ✅ 38 个 tweak | ❌ | winutil |
| **无界面批量执行** | ✅ `-Config` / `-Preset Standard\|Minimal\|Advanced` | ❌ 只能交互 | winutil |

---

## 三、实测：DNS 优选这一项，winutil 在当前网络里会选错

winutil 用 **TCP 53 握手 RTT** 给它的 8 家 DNS 排序。实测本机到各家的结果：

| DNS | TCP/53 | 判定 |
|---|---|---|
| Google <IP> | 通 354 ms | 慢 |
| Cloudflare <IP> | 通 347 ms | 慢 |
| Quad9 <IP> | 通 236 ms | 慢 |
| OpenDNS <IP> | 通 **190 ms** | 它的"最优" |
| AdGuard <IP> | 通 307 ms | 慢 |
| — | | |
| **网关 <IP>** | 通 **9 ms** | ← 实际最快，但它没有这一项 |
| AliDNS <IP> | 通 77 ms | 名单里也没有 |
| DNSPod <IP> | 通 88 ms | 名单里也没有 |

**结论**：winutil 会选 OpenDNS（190ms），比本地网关慢 **21 倍**。
它没有任何中国 DNS 提供商，对国内网络环境基本不可用。

---

## 四、两边都没做的（说明这不是我不做，是不该做）

网上流传的"TCP 优化"注册表改法（`TcpWindowSize`、`MaxUserPort`、`Tcp1323Opts`、
关闭 Nagle 等）在现代 Windows 上收益极低甚至有害。微软官方文档明确写：

> Windows TCP/IP 堆栈设计为在大多数环境中自行调整，并使用比早期版本更大的默认窗口大小。

所以两边都没碰这些。如果有人卖你"注册表 TCP 加速"，基本是智商税。

---

## 五、结论：不冲突，都留着

| 场景 | 用哪个 |
|---|---|
| 日常：卡了、网页打不开、断网 | **网络优化器**（体检 → 找原因 → 急救） |
| 常开常关 Clash | **网络优化器**（代理开关，保证不留残留） |
| 重装系统后装软件、关遥测、卸预装 | **winutil** |
| 想换 DNS 提速 | **网络优化器**（它认识中国 DNS 和本地网关） |

winutil 是优秀的**装机工具**，但它不是网络优化器——网络部分只覆盖 DNS 和粗暴重置。
在国内网络环境下，它的 DNS 功能反而是负优化。

---

## 六、安全提醒

- winutil 官方推荐的用法是 `irm https://christitus.com/win | iex`（下载即执行），
  且脚本**未签名**。本次是用 release 资产直接下载核验的，没有走管道执行。
- 如果要用，建议本地运行 `winutil.ps1`，而不是 `irm | iex`；
  并用 `-Preset Standard` 先看它准备改什么，再决定。
- 任何 tweak 工具都应在改动前创建还原点。
