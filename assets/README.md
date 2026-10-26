# 应用图标

`lingzhi.ico` 是 EXE 与 WinForms 窗口共用的正式图标，采用用户确认的蓝色渐变圆底、简化白狐。

- 原图：[简化版 PNG](icon-concepts/2026-10-26/B-灵狐-圆形-蓝色渐变-简化版.png)。
- ICO 包含 16、24、32、48、64、128、256 像素七种尺寸，保留透明背景。
- `tools/Build.ps1` 将 ICO 写入 EXE 图标资源，并加入内置发布包；仅打包正式 ICO，不打包候选图和提示词。
- 更换图标后重新运行 `tools/Build.ps1`。原图和候选版保留在 `icon-concepts/` 供后续修改。
