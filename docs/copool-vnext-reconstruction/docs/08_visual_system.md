# 08. 视觉系统要求

## 必须继承的 P1 视觉规则

- 菜单栏窗口、固定宽度与轻量层级。
- 页面水平内边距 16pt；section 间距 16pt；列表行间距 10pt。
- 卡片圆角 14pt。
- 主导航为胶囊容器；选中项使用 Material/Glass + 低透明度 accent tint。
- SF Symbols、系统字体、系统语义色。
- NoticeBanner 统一承载 success/warning/error，不在每个页面复制 toast。
- 高密度数据优先卡片摘要 + detail sheet，不使用企业 Dashboard 式大表格堆叠。

## 新增视觉 token

| Token | 建议 |
|---|---|
| `statusDotSize` | 8pt |
| `metadataChipRadius` | 8pt |
| `detailSheetMinWidth` | 520pt，仅独立窗口/大屏；菜单栏内保持当前宽度 |
| `compactChartHeight` | 72pt |
| `decisionScoreBarHeight` | 6pt |
| `dangerSurfaceOpacity` | 0.08 |

## 组件扩展原则

- 新组件优先组合 `SectionSurface`、`SectionActionStyle`、`NoticeBanner` 和现有 progress/tag。
- Provider/Target/Agent 卡片共享 `ResourceCardShell`，但内容 slot 独立。
- 状态颜色必须同时配图标/文字，不能仅靠颜色。
- Expert Mode 字段使用 disclosure group，默认折叠。
- 不复制 P2/P3 的 Web/Tauri Dashboard、品牌色、图标和截图构图。
