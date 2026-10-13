# UtenSearchBar

> 源码：`lib/components/inputs/uten_search_bar.dart`
> 2026-09-01 起为**全平台唯一搜索框组件**：胶囊圆角 + 内容驱动高度（桌面≥40、触屏目标≥48）+ 清除按钮 +
> 300ms 防抖 + 输入法组合保护（拼音未上屏不触发回调，见 §二·五）；业务代码不得再手写搜索
> `TextField`。
> 相关：[UtenFilterToolbar](UtenFilterToolbar.md)（分类分段 + 本组件的统一工具条）

## 一、形态与统一高度（2026-10-13）

- 全平台唯一胶囊搜索框，圆角从 `UtenRadius.pill`取值；普通输入内容16，dense内容14。
- 桌面最小内容高40，触屏目标至少48窗口像素；前后图标约束与清除按钮同源使用 `UtenControlMetrics`。应用缩小不能把清除目标缩到48以下，文字放大可以撑高。
- 内边距水平12/16、垂直6；高度由内容和图标约束共同决定。不能在外部只拉高盒子而不让描边跟随。
- `UtenFilterToolbar`给分类和搜索提供实际有界宽度；分类放不下时完整面板，搜索不被强行压成窄条。
- dense仅用于内容密集筛选/表格，不意味着触控目标可以缩到28。旧36/约30高度口径退役。
- 保留清除、300ms防抖、输入法组合保护、立即输入回调、回车取消挂起回调；本次尺寸整改不改查询时序。

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
