# 检测详情页 · 五段结构实现规格

目标：把现在「一张卡片 9 行」改成五段，每段给证据、时间、失败原因、建议动作。

## 结构

```
$detailsPage（Panel 宿主）
 └ $detailScroll（AutoScroll）
    ├ Section 链路      ● 通过   13:20:04
    │   网卡 WLAN · 网关 172.21.69.254 · 14ms
    ├ Section DNS       ● 通过   13:20:04
    │   国内可解析 · 境外域名解析失败（可能被污染）
    ├ Section 国内      ● 通过   13:20:04
    │   小米 ✓ 12ms   百度 ✓ 15ms   腾讯 ✓ 18ms
    ├ Section 国际      ○ 失败   13:20:04
    │   cloudflare trace 超时；google 204 超时
    │   → 建议：需要访问境外时开启代理
    └ Section 代理      — 未启用
        端口 7897 未监听
```

## 每段控件组成

| 元素 | 说明 |
|---|---|
| 状态点 + 标题 | `●`/`○`/`—` + 段名，粗体 11pt |
| 时间 | 右对齐，`HH:mm:ss`，次要色 |
| 证据行 | 10pt，最多两行，次要色 |
| 建议行 | 仅失败段显示，前缀 `→ 建议：`，警示色 |

段间用 1px 分割线（颜色 `#2A2D34`），首尾不画；行高 44px。

## 数据来源

| 段 | 字段 |
|---|---|
| 链路 | `$script:lastSnapshot.Connection` + `Info.Gateway` + `GatewayPing` |
| DNS | `$script:layerCache.Dns` |
| 国内 | `$script:layerCache.Domestic`（Passed/Total + 明细） |
| 国际 | `$script:layerCache.Intl` |
| 代理 | `$script:lastSnapshot.Proxy` |

所有颜色用 `[System.Drawing.Color]::FromArgb(...)` 字面量，**不要**沿用 `$C.*` 查表或 switch 返回值（历史崩溃根因）。

## 验收

1. 五段全部渲染，颜色与首页徽章一致
2. 失败段必须出现 `→ 建议：`
3. 分层数据未就绪时，链路与代理显示真实快照，DNS/国内/国际显示 `— 未验证`
4. 解析 0 错误、13 个测试套件全绿、截图确认