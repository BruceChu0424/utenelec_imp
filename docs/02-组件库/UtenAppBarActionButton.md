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
- **桌面紧凑最小高度36，触屏保底48**（`UtenAppBarActionButton.height` 提供36的桌面目标）：
  系统文字较大时允许内容撑高；动作进入面板的时机由实际可用顶栏宽度决定。
- **保留完整文字**，`compact` 参数只为兼容旧调用保留。
  窄宽或系统文字较大时由 `UtenAppBar` 将动作放入完整操作面板，普通控件遵循触屏48的命中下限。
- 相邻可见按钮的实际轮廓间距统一为 **4px**，由 `UtenAppBarActionRow` 管理。
  按钮自身不叠加外侧留白，页面不再为顶栏动作添加横向 `Padding` 或空 `SizedBox`；
  权限/功能隐藏的零宽动作不占间距。自定义动作组内部也使用同一4px口径。

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
忙态不另加高度：沿用桌面紧凑36、触屏至少48的最小目标；实际高度可随系统文字内容增长。

同日把全站 17 个页面共 20 处顶栏动作（清一色
`Padding + UtenButton(size: large, type: tonal)` 的「刷新」）收敛到本组件——
用户反馈「刷新和权限设置按钮高度不一致，统一都和权限设置一致」。
仍有少量顶栏用裸 `IconButton`（纯图标、无文案），那是另一种形态，不在本次收敛范围。

## 2026-10-20：统一点击反馈与请求生命周期

当前界面修改默认使用 `frontend-design`，继续复用既有 Uten 主题与按钮尺寸。
`UtenAppBarActionButton.onPressed` 接受 `FutureOr<void>`；返回真实网络 Future 后，
顶栏自动转圈、防止连点，并在请求结束后恢复。加载提示覆盖在原文字位置，保留
按钮原宽度和相邻间隔，避免等待期间把操作挤进「更多操作」。业务已有的
`isLoading` 仍可联动，完成/失败通知继续由原业务处理。

刷新优先使用 `UtenRefreshButton(onRefresh: _load)`：`busy` 只表示真实加载，
`enabled` 保留权限、编辑中或其它业务锁，不能把所有禁用状态都画成转圈。
请求组合必须返回 `Future.wait` 或显式 `await`，不能发出请求就立即结束按钮的等待。
使用 `refreshTick` 驱动正文的宿主，必须等待可见子视图的真实加载完成；
`UtenRefreshScope` 提供这一完成信号，未挂载分段不参与等待。

导航、确认、打印预览和选择面板本身就是点击反馈。弹窗/下一路由出现后，
被覆盖的顶栏停止进度动画，动作仍保持防重入；取消、返回和异步完成沿用原有逻辑。

回归覆盖混合按钮的实际4px间隔、隐藏动作、等待/连点/宽度稳定、模态生命周期，
以及真实页面的刷新请求链，不以截图或源码匹配代替异步行为验证。


2026-10-13：窄宽或大系统文字的顶栏动作放入完整操作面板，不把标题挤没。`UtenAppBarActionScope`携带原页presentation context，仅负责动作面板生命周期，不提供权限/业务数据。同步草稿/权限导航关闭旧面板后从原页打开；有状态异步导出保留挂载至prepare/password/download完成或取消，随后只关闭所属面板。不得用pointerDown预先销毁按钮。
