# UtenInlineNotice

页内「常驻」提示框(2026-09-16 新组件，随 V596 / ADR-090「先入库后质检」落地)：信息 / 警告 / 错误三档，
不弹出、不自动消失，放在内容区顶部或表格上方。与顶部通知条 `UtenNotify.banner`(会消失)和
`UtenCenterAlert`(弹窗)互补。

## 用法

```dart
UtenInlineNotice(
  level: UtenInlineNoticeLevel.error,
  title: '货品已入库，需到对应储放区域检查',
  message: '本单 3 行已先入库上架：五金仓库 / A-01 …',
  trailing: TextButton(onPressed: _refresh, child: const Text('刷新')),
)
```

| 参数 | 说明 |
|---|---|
| `message` | 必填正文 |
| `level` | `info`(主题信息色淡底，默认) / `warning`(琥珀) / `error`(红，标红作业提醒) |
| `title` | 可选标题；info 档标题用正文色，其余档用档位色加粗 |
| `trailing` | 右侧动作(按钮等)，null 不渲染 |
| `semanticLabel` | 无障碍整句；null 时用「标题。正文」 |

## 行为契约

| 语义 | 约定 |
|---|---|
| 颜色不是唯一表达 | 图标 + 正文始终同时在场；error 档 `liveRegion: true` 让读屏立即播报 |
| 圆角 / 边框 | `UtenRadius.mdAll`；底色 = 档位色 10%(深色 18%)，边框 = 档位色 45% |
| 不可关闭 | 常驻说明由宿主决定何时移除(条件为假就不渲染)，组件不带关闭按钮 |

## 接入方

- 品质：IQC 单张处置页、批量审批页——先入库后检的收货单顶部标红「货品已入库，需到对应储放区域检查」
  (逐行列「货品 → 仓库 / 库位」)
- 仓库：品质部检查结果详情页「本单 n 行已先入库上架」信息横幅；先入库上架页的说明 / 错误提示
- 候选迁移(未做)：各页自写的 `_MessagePanel` / `_OwnReleaseNotice` 一类页内提示，统一收口到本组件
