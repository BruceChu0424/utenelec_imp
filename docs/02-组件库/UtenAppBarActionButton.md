# UtenAppBarActionButton（顶栏动作按钮）

> 源码：[`lib/components/buttons/uten_app_bar_action_button.dart`](../../lib/components/buttons/uten_app_bar_action_button.dart)
> 建立日期：2026-09-11（用户要求「这些按钮颜色大小都统一起来」）
> 接入方：[`UtenDraftsButton`](UtenDraftsButton.md)（新建页「草稿(N)」）、
> `PagePermissionAction`（业务页「权限设置」，`lib/shared/auth/page_permission_action.dart`）

---

## 一、要解决的问题

顶栏右上角此前一页一个样：

| 入口 | 改造前 |
|---|---|
| 草稿(N) | `UtenButton(type: tonal)` —— 浅底深字，44 高 |
| 权限设置（宽屏） | 裸 `TextButton.icon` —— 无底色，48 高 |
| 权限设置（窄屏） | `IconButton` —— 纯图标，另一种形态 |

三种底色三种高度，同一条 AppBar 上并排时尤其扎眼。

---

## 二、唯一形态

- **配色走 `UtenButtonType.primary`**：浅色主题 `colorScheme.primary = teal700`（深绿）+
  `onPrimary` 白字；深色主题自动提亮为 teal400，不在暗底上糊成一块。与表格工具条的
  「表头设置 x/y」「预览打印」同一视觉语言。
- **高度固定 36**（`UtenAppBarActionButton.height`）：顶栏 56 高，全站默认的 44/52 会顶满
  上下留白。
- **`compact: true` 只渲染图标**（窄屏顶栏放不下文案），底色/高度/圆角**不变**——窄屏缩的是
  文案不是形态，避免「一个按钮两种长相」。文案仍进 tooltip 与语义标签。
- 自带左右 4px 间距，直接放进 `UtenAppBar(actions: [...])` 即可。

```dart
UtenAppBarActionButton(
  icon: Icons.admin_panel_settings_outlined,
  label: '权限设置',
  tooltip: '设置「销售订货单」本页权限',
  compact: !context.breakpoint.isExpanded,
  onPressed: open,
)
```

---

## 三、新增顶栏入口时

一律用本组件，不要再写 `TextButton` / `IconButton` / 自定义 `UtenButton`。需要计数的（如
草稿）把计数拼进 `label`（`草稿(3)`），计数形态遵循
[徽章与计数口径](../00-项目准则/14-徽章与计数口径.md)——草稿是浏览型，用括号不用红徽章。

---

## 四、测试

- [`test/components/uten_drafts_button_test.dart`](../../test/components/uten_drafts_button_test.dart)
  （权限隐藏 / 计数 / 落点带 returnTo / tooltip；**Tooltip 在按钮内部**，按后代查而非祖先）


## isLoading（2026-09-11）

顶栏「刷新」这类要等网络的动作传 `isLoading: true`：走 UtenButton 自带的转圈，
**高度不变**（仍是 36），不会在加载时把整条顶栏顶高一格。

同日把全站 17 个页面共 20 处顶栏动作（清一色
`Padding + UtenButton(size: large, type: tonal)` 的「刷新」）收敛到本组件——
用户反馈「刷新和权限设置按钮高度不一致，统一都和权限设置一致」。
仍有少量顶栏用裸 `IconButton`（纯图标、无文案），那是另一种形态，不在本次收敛范围。
