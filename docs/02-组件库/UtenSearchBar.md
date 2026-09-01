# UtenSearchBar

> 源码：`lib/components/inputs/uten_search_bar.dart`
> 2026-09-01 起为**全平台唯一搜索框组件**：胶囊圆角 + 最小高 48 + 清除按钮 +
> 300ms 防抖；业务代码不得再手写搜索 `TextField`。
> 相关：[UtenFilterToolbar](UtenFilterToolbar.md)（分类分段 + 本组件的统一工具条）

## 一、形态（唯一，无变体参数）

- **胶囊圆角**：边框半径远大于高度，RRect 归一化后即高度一半的 stadium，
  与 M3 SegmentedButton 默认 StadiumBorder 同形；描边 `outline`、聚焦主色 2px。
- **高度内容驱动**（约 43，随字号自然增高）：M3 默认给 prefix/suffix 图标各
  48×48 最小约束会顶高输入框，本组件已显式收紧到 32。与分段导航条并排时的
  「严格同高」由 `UtenFilterToolbar` 的 IntrinsicHeight+stretch 结构保证——
  visualDensity 对两侧折减不一致（桌面端实测分段 32/搜索框 40），各自算高度
  算不平，不要在页面里给分段设 minimumSize 对齐。
- 内置：搜索前缀图标、清除按钮（有内容时）、300ms 防抖、自动聚焦控制。

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
- 图标按钮上的 `Icons.search_rounded`（查询按钮、选择器入口按钮）不是搜索框，
  不在迁移范围。
