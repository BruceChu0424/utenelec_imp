# UtenSearchBar

> 源码：`lib/components/inputs/uten_search_bar.dart`
> 2026-09-01 起为**全平台唯一搜索框组件**：胶囊圆角 + 内容驱动高度（≈44）+ 清除按钮 +
> 300ms 防抖；业务代码不得再手写搜索 `TextField`。
> 相关：[UtenFilterToolbar](UtenFilterToolbar.md)（分类分段 + 本组件的统一工具条）

## 一、形态（唯一，无变体参数）

- **胶囊圆角**：边框半径远大于高度，RRect 归一化后即高度一半的 stadium，
  与 M3 SegmentedButton 默认 StadiumBorder 同形；描边 `outline`、聚焦主色 2px。
- **高度由内容驱动（≈44，contentPadding 10 + 单行文本），不设 minHeight 48**（2026-09-10 曾加
  `constraints: minHeight 48`，因 `UtenFilterToolbar` 的 IntrinsicHeight+stretch 会把分段条一起拉到
  48，全站分类分段肉眼变高，用户反馈后当日回退）：与工具条同排的行尾控件自行对齐到 ≈44——
  `UtenFilterPickerField`（2026-09-11 起页面层级筛选的统一形态，见
  [UtenFilterPickerField](UtenFilterPickerField.md)）按同一口径算内边距；表单内下拉若同排，
  传紧凑 `contentPadding`（`WarehouseHierarchyDropdown` 的 `contentPadding` 参数）。M3 默认给 prefix/suffix 图标各 48×48 最小
  约束会顶高输入框，本组件已显式收紧到 32。与分段导航条并排时的「严格同高」
  由 `UtenFilterToolbar` 的 IntrinsicHeight+stretch 结构保证——不要在页面里给
  分段设 minimumSize 对齐。
- 内置：搜索前缀图标、清除按钮（有内容时）、300ms 防抖、自动聚焦控制。
- **`dense: true`（2026-09-11）**：收紧内边距与图标（高约 36 而非 44），字号降一档。
  **只给「筛选面板里的一格」用**——报表/明细表左侧筛选区里搜索框只是一堆筛选项中的一项，
  默认高度显得笨重（用户要求「搜索的框显示小点」）。
  ⚠️ **不要给页面主搜索框或 `UtenFilterToolbar` 里的搜索框传 dense**：工具条用
  IntrinsicHeight+stretch 让分类分段跟搜索框同高，改高度会把全站分段一起带走
  （2026-09-10 已因此回退过一次）。

## 二、用法

```dart
UtenSearchBar(
  hint: '搜索单号 / 供应商',
  initialValue: _keyword,
  onChanged: _applySearch,        // 300ms 防抖后触发（异步检索/发请求）
  // onInputChanged: _onInput,    // 每次输入同步触发（本地即时过滤/作废旧请求）
  // controller: myController,    // 需要外部接管文本时
)
```

- 本地列表即时过滤 → `onInputChanged`（无防抖，输入即筛）。
- 异步检索 → `onChanged`（防抖）；可在 `onInputChanged` 里先作废旧请求。

## 三、迁移注意

- 原手写「TextField + prefixIcon 搜索 + suffixIcon 清除」一律替换为本组件，
  保留原 controller/hint/autofocus 语义，删除手写清除逻辑。
- 图标按钮上的 `Icons.search_rounded`（选择器入口按钮）不是搜索框，不在迁移范围。
- **「查询」按钮 2026-09-11 全站撤除**（用户要求）：报表/明细表/账户流水/应收应付总览/
  对账单/计划行选择器共 11 处。新口径——改日期/下拉**即刻重查**，关键词走搜索框自身的
  300ms 防抖与**回车立刻查**（`onSubmitted`）。页面侧把「存偏好 + 回第一页 + 重查」收敛成
  一个 `_persistAndReload()` 出口，筛选项的每个 `onChanged` 都走它，避免漏掉某一项。
