# 验证入口

统一从根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-all.ps1
```

| 套件 | 验证内容 |
|---|---|
| Test-Syntax | Windows PowerShell 5.1 与可用的 7 版本语法解析，包括 tools |
| Test-Encoding | `.ps1` UTF-8 BOM、根目录 `.cmd` GBK |
| Test-Protocol | 本机回环假服务，验证 HTTP、需认证 HTTP、SOCKS5、非代理 |
| Test-Product | 状态保存、还原失败、DNS 来源、参数转义和模式切换 |
| Test-Diagnostics | 门户 URL、配置数据根、MTU 未知、远端代理与监听范围 |
| Test-Launcher | 权限选择保存/取消、损坏记录、旧版白名单导入及不覆盖 |
| Test-Package | EXE 资源清单、个人数据隔离及与源码一致性 |

测试不会实际切换系统代理、DNS、服务或网卡。修改行为采用替代系统调用和隔离文件验证。协议测试会短暂启动本机回环监听及 PowerShell 子进程；受限沙箱可能要求批准，不能将此环境拒绝误记为产品功能失败。

界面验证另用源码的 `-Screenshot`、`-Settings`、`-Help`、`-AutoClose`，或 EXE 的 `--smoke-test`。生成截图后实际查看。当前验证结果见 [verification.md](../docs/verification.md)。
