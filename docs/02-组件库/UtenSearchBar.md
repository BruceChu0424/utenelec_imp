# UtenSearchBar

> 源码：`lib/components/inputs/uten_search_bar.dart`
> 2026-09-01 起为**全平台唯一搜索框组件**：胶囊圆角 + 内容驱动高度（≈44）+ 清除按钮 +
> 300ms 防抖 + 输入法组合保护（拼音未上屏不触发回调，见 §二·五）；业务代码不得再手写搜索
> `TextField`。
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
  约束会顶高输入框，本组件已显式收紧。与分段导航条并排时的「严格同高」：
  InputDecorator 的药丸**描边**只按内容高绘制（`max(前后缀图标约束高,
  contentPadding + 文本行高)`），不吃外部 minHeight——外部约束拉高的只是盒子、
  描边居中浮在盒里（2026-10-07 SDK 源码定位，compact 密度空框实测药丸 33 vs
  分段 40，即用户看到的「搜索栏矮一截」）。因此本组件把前后缀图标约束的
  minHeight 设为与 `UtenSegmentRow.minCellHeight` 同源的
  `UtenFilterRow.minHeight`(36)：两侧描边恒等于 `max(36, 文本内容高)`，任意
  密度/字号下相等；不要在页面里给分段设 minimumSize 对齐。
- 内置：搜索前缀图标、清除按钮（有内容时）、300ms 防抖、自动聚焦控制。
- **`dense: true`（2026-09-11）**：收紧内边距与图标（高约 30 而非 36），字号降一档。
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
  // onInputChanged: _onInput,    // 每次已提交输入同步触发（本地即时过滤/作废旧请求）
  // controller: myController,    // 需要外部接管文本时
)
```

- 本地列表即时过滤 → `onInputChanged`（无防抖，输入即筛）。
- 异步检索 → `onChanged`（防抖）；可在 `onInputChanged` 里先作废旧请求。
- 回车 → `onSubmitted` 立刻触发，并自动取消挂起的防抖回调（回车查完不会又被防抖重查一次）。

## 二·五、输入法组合保护（2026-10-09）

中文输入法（拼音/注音等）组合期间——`TextEditingValue.composing` 非空、候选字还没上屏——
**两个回调都挂起**：既不触发 `onInputChanged` 也不触发 `onChanged`，防抖计时器随每次组合
按键重置。组合结束后统一派发一次完整词：

- 选字上屏（文本变化）→ 走 `TextField.onChanged` 正常路径；
- 原样上屏 / 失焦提交（文本不变、`onChanged` 不会触发）→ 由组件内 controller 监听补发。

在此之前，半截拼音（"l"、"li"）就会触发检索；检索命中 0 条时页面切空态、搜索框被重建，
焦点丢失又把组合中的拼音原样顶上屏——即用户口中的「打一半拼音就被搜索、输入法没了」。
**页面自持 `TextEditingController` 裸监听做过滤的地方拿不到这层保护**，须自己在监听里判
`value.composing != TextRange.empty` 时跳过（树视图、应收应付总览、岗位选择器已按此口径处理）。

## 三、迁移注意

- 原手写「TextField + prefixIcon 搜索 + suffixIcon 清除」一律替换为本组件，
  保留原 controller/hint/autofocus 语义，删除手写清除逻辑。
- 图标按钮上的 `Icons.search_rounded`（选择器入口按钮）不是搜索框，不在迁移范围。
- **「查询」按钮 2026-09-11 全站撤除**（用户要求）：报表/明细表/账户流水/应收应付总览/
  对账单/计划行选择器共 11 处。新口径——改日期/下拉**即刻重查**，关键词走搜索框自身的
  300ms 防抖与**回车立刻查**（`onSubmitted`）。页面侧把「存偏好 + 回第一页 + 重查」收敛成
  一个 `_persistAndReload()` 出口，筛选项的每个 `onChanged` 都走它，避免漏掉某一项。
- **不要在 `UtenSearchBar.onChanged` 之上再叠页面自己的防抖 Timer**（2026-10-09 清理
  销售出货工作台一处）：双层叠加实际触发延迟约 600ms，输入明显迟滞。
