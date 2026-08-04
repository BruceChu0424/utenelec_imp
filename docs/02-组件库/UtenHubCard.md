# UtenHubCard

> 源码：[`lib/components/cards/uten_hub_card.dart`](../../lib/components/cards/uten_hub_card.dart)
> 适用：二级模块页（销售/采购/委外/生产/钱流/仓库/基础资料 hub）的入口卡片。
> 新增：2026-08-04（收口原本散落在各 hub 里 7~8 份 copy 的 `_EntryTile` / `_ResourceTile` / `_WarehouseTaskCenterTile`）。

## 一、定位

统一的「图标 + 标题 + 副标题 + 右上角徽章」入口卡。徽章通过 `Stack` + `Positioned(top/right)` 恒定渲染在卡片右上角，不再随标题文字或图标行漂移——这正是各 hub 之前徽章摆放不一致（图标行右侧 / 标题右侧 / 无徽章位）的根因。

## 二、API

| 参数 | 类型 | 说明 |
|---|---|---|
| `icon` | `IconData` | 必填，图标 |
| `label` | `String` | 必填，标题 |
| `onTap` | `VoidCallback` | 必填，点击回调 |
| `description` | `String?` | 副标题；为空则只显图标 + 标题（仓库出入库/库存/报表 tile） |
| `color` | `Color?` | 图标底色与图标色，默认 `theme.colorScheme.primary`（基础资料按条目传绿/青） |
| `badge` | `Widget?` | 右上角浮层徽章（如 `PurchaseTaskBadge` / `UtenNotificationBadge`） |
| `enabled` | `bool` | `false` → 图标/标题置灰 + 右上角「未启用」chip |
| `onDisabledTap` | `VoidCallback?` | 禁用态点击回调（如提示「该单据类型暂未启用」） |
| `labelStyle` | `TextStyle?` | 标题样式，默认 `titleSmall·w600`（基础资料传 `titleMedium` 保留较大标题） |

## 三、用法

常规入口（带角标）：

```dart
UtenHubCard(
  icon: Icons.pending_actions_rounded,
  label: '采购任务中心',
  description: '查看计划申请，按供应商分解为订货单',
  onTap: () => goFrom(context, RouteName.operationsPurchaseWorkbench),
  badge: const PurchaseTaskBadge(showLabel: true),
)
```

未启用单据（委外询价/申请）：

```dart
UtenHubCard(
  icon: cfg.icon,
  label: cfg.label,
  description: cfg.shortLabel,
  onTap: () => goFrom(context, location),
  enabled: cfg.enabled,
  onDisabledTap: () => context.appInfo('该单据类型暂未启用（老库无数据）'),
)
```

## 四、约定

- 徽章一律用 `UtenNotificationBadge` 系（`count<=0` 时自身不渲染）；hub 任务中心徽章统一 `showLabel: true`（显示数字）。
- 图标盒统一 40×40 / 图标 size 22，颜色取自 `color`，不复用裸 `Color(0x...)`。
- 底部留白由各 hub 的外层 `ListView` padding 负责（compact `s16` / 桌面 `s40`，叠在工作台外壳对 compact 子页面已预留的胶囊高度之上），不在卡片内处理。
- 新增 hub 入口只需在各 hub 的 `_Entry` 列表加一条，`itemBuilder` 走 `_EntryTile`（薄包装，映射到 `UtenHubCard`）；不再为单页新写卡片样式。
