# UtenTableCellAction - 表格单元格内联动作

2026-10-06 行高统一口径引入: 读表(MasterDataTableView 系)单元格里放动作时用本组件。
高度 = 单行文本(继承宿主格字号), 不带按钮主题的最小触控高 —— TextButton 默认最小高 40、
UtenButton 最小高 44, 都会把单行文本行(≈37)撑到 52-60, 造成跨页面行高不齐。

## 用法

```dart
UtenTableCellAction(
  label: '固定追加量 · 续报',
  tooltip: '打开固定追加量续报入口',
  onPressed: () => _openTask(task),
)
```

- `label`: 动作文案, 单行省略号; 超宽由宿主列 `value`/`textOf` 自动加宽兜底。
- `icon`: 可选 14px 前置图标(主色)。
- `tooltip`: 悬停说明(动作语义或被省略号截断的完整信息)。
- `onPressed`: null 时文字置灰(保留占位)。
- `error`: 必填未填等错误态, 文字(含图标)转 error 红, 仍可点击——接住原先
  TextButton `foregroundColor: error` 一类的「需要填写」红字语义。
- 文字样式继承宿主格 `DefaultTextStyle`(读表是 bodySmall), 与同行文本格同字号同高;
  主色 + w600 表达可点。

## 与相邻组件的分工

| 场景 | 用什么 |
|---|---|
| 读表格子里的动作 | 本组件 |
| 读表格子里的内联下拉 | `UtenDropdownField(flat: true)` |
| 编辑表(UtenEditableGrid / 有输入控件的 MDTV)里的按钮位 | 本组件(超过 39 控件标准时) |
| 表头工具条/悬浮组的按钮 | `UtenButton` / 工具条规范件, 与行高无关 |

## 测试

行高口径的回归锁在
[`test/components/layout/master_table_row_height_uniformity_test.dart`](../../test/components/layout/master_table_row_height_uniformity_test.dart)。
