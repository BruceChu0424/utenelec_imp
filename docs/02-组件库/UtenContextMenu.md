# UtenContextMenu（行级右键/长按操作菜单 —— 三端一致）

> 位置：`lib/components/feedback/uten_context_menu.dart`
> 用途：给表格行/列表项挂「右击或长按弹出操作小框」的能力。首用于基础资料各主档页
> （货品/颜色/客户/供应商/模具），经 `MasterDataTableView.rowMenuBuilder` 接入。

---

## 一、三端触发方式（平台自然降级）

| 平台 | 触发 |
|---|---|
| 桌面（Windows/macOS/Linux） | 鼠标右击（`onSecondaryTapDown`） |
| Web | 同样吃鼠标右击；**必须**配合 `main.dart` 里的 `BrowserContextMenu.disableContextMenu()` 屏蔽浏览器自带右键菜单（kIsWeb 守卫，已在入口处理好），否则两个菜单叠着出 |
| 手机/触屏 | 长按（`onLongPressStart`）出同一个菜单；菜单里应放「查看详情」等条目作为打开路径的兜底 |

菜单本体是挂在 **root Overlay** 上的自绘小框（不走 `PopupMenu`，便于精确锚定指针位置 +
控制宽度/分隔线/置灰样式）：宽 216、条目高 40、限高 420 可竖滚；点外部、右键空白或选中
条目后关闭；靠近屏幕右/下边缘自动向左/向上翻转，保证不出屏。

---

## 二、API

```dart
UtenContextMenuRegion(
  entriesBuilder: () => [           // 手势触发那一刻才构建（可取最新状态决定可用性）
    UtenMenuItem(
      label: '复制货品',
      icon: Icons.copy_rounded,
      onTap: () => _copy(g),        // 菜单先关闭，再执行回调（回调里可安全弹对话框）
    ),
    UtenMenuItem(
      label: '粘贴货品',
      icon: Icons.content_paste_rounded,
      enabled: clipboard != null,   // false = 置灰不可点（剪贴板为空时粘贴不可用）
      onTap: _paste,
    ),
    const UtenMenuDivider(),        // 分组分隔线
    UtenMenuItem(
      label: '删除货品',
      icon: Icons.delete_outline_rounded,
      destructive: true,            // 图标与文字用错误色（删除/禁用类危险操作）
      onTap: () => _delete(g),
    ),
  ],
  onMenuOpening: () => _selectRow(),// 菜单弹出前同步调用（先把该行置为选中）
  onActionCompleted: _clearSelection,// 可用条目的同步/异步动作结束后调用
  child: row,
)
```

也可脱离包裹组件直接 `showUtenContextMenu(context, globalPosition: ..., entries: ...)`。
其 Future 在菜单真正关闭后完成：点外部返回 `dismissed`；选择可用条目时先关菜单，
再等待条目的同步/异步回调结束并返回 `actionCompleted`。

---

## 三、与 MasterDataTableView 的集成（推荐用法）

表格行不要自己包 `UtenContextMenuRegion`——用组件的 `rowMenuBuilder` 参数：

```dart
MasterDataTableView<GoodsListItem>(
  // ...
  rowMenuBuilder: _goodsMenuItems,  // List<UtenContextMenuEntry> Function(T item)
)
```

组件行为约定（见 [MasterDataTableView.md](MasterDataTableView.md)）：

- 右击/长按一行 → **先把该行置为选中态**再弹菜单（多选模式下：该行未勾选则选择集
  替换为仅该行，已勾选则保留多选——标准文件管理器行为）。
- 选择可用条目后，`MasterDataTableView` 会等待该动作(含后续确认框/异步回执)结束，再清空
  单选或受控多选；只点外部取消菜单时保留当前选择，避免误清用户主动勾选的多行。
- 条目在每次手势时重新构建，可按行数据（状态=使用/禁用）、权限（`Perm.goodsEdit` 等）、
  剪贴板（`goodsClipboardProvider`）实时决定 label 与 `enabled`。
- 触屏无右键 → 长按出菜单；菜单首项通常是「查看详情」，弥补触屏双击打开不直观的短板。

---

## 四、菜单设计约定（基础资料各页现状）

- **首项 = 查看详情**（触屏打开路径兜底），随后分组：主档操作（复制/粘贴/启停/删除）、
  关联操作（货品的组件信息复制/粘贴/删除）。
- 启停类条目按行状态出精确文案（使用中行显「禁用 X」红色 destructive，已禁用行显
  「启用 X」）；列表行不带状态字段的（供应商）用「启用/禁用 X」合并入口，点进去拉详情翻转。
- 写操作（粘贴/启停/编辑/删除）按编辑权限 `enabled` 置灰，**不是隐藏**——让只读用户
  看得到功能边界、又不会误触；后端独立校验兜底。

---

## 五、与 UtenEditableGrid 的集成（单据明细行操作菜单，2026-09-03）

编辑页明细表（销售/采购/委外/钱流/库存/生产计划/生产日报 7 页共用）的行级菜单由
**grid 组件内置**（`_rowCellOrMenuRegion`），页面无需自己包 Region：

- 可编辑模式(`showAddRow=true`)使用复制、粘贴、插入和删除的内置菜单；「只选不编」任务
  办理表默认不挂。只有页面显式提供 `onRemoveRows` 时，任务表才显示选择操作条并挂定制
  “移出本次操作”菜单，避免把上游来源行误解释成持久化删除。
- `canSelectRow=false` 的任务行既不能勾选，也不挂右键/长按移出菜单；两者必须共用同一
  业务资格。保存或提交期间传 `selectionEnabled:false`，组件保留布局但统一禁用表头全选、
  行复选、批量动作和行菜单，避免请求快照与选择集漂移。
- 右键/长按行 → 先选中归位（未勾选则选择集替换为仅该行，已勾选保留多选——与
  MasterDataTableView 同一文件管理器语义），再弹菜单作用于整组。
- 选择菜单条目后等待该动作完成并统一 `clearSelection()`；只关闭菜单不清，操作条主动
  选择也不受影响。
- 任务表的 `removeRowsActionLabel`、`removeRowsDialogTitle`、`removeRowsConfirmLabel`、
  `removeRowsMessageBuilder` 必须准确说明副作用。例如到货登记使用“移出本次登记”，确认文案
  明示来源单、报工、FQC、库存和历史都未删除；真正业务删除必须另走服务端权限与审计 API。
- 条目：复制选中 / 粘贴 / 批量粘贴 / 在上方插入空行 / 删除选中，全部复用操作条同一套
  `UtenEditableGridController` 逻辑与确认弹窗；粘贴统一追加表尾。
- 复制粘贴组仅在页面提供 `cloneRow`（行深拷贝）时显示；缓冲为空时粘贴置灰不隐藏。
- **接入顺序坑**：组件 `_open` 先调 `entriesBuilder` 再回调 `onMenuOpening`——归位选中
  必须写在 `entriesBuilder` 开头（grid 即如此），否则「复制选中 (n)」计数是归位前的旧值。
- 各行模型 `clone()` 的取舍契约：拷用户录入 + 主档透传；**不拷**上游明细 id/来源谱系/
  数量门控/单据自身行 id（粘贴行是新明细，防双引用）；生产计划行额外不拷订单 1:1 溯源
  （防 planned_qty 双计），生产日报行整行拷来源引用（保存端按来源聚合限报兜底）但重置
  isFinal——细节见各 `*_grid_columns.dart` 的 clone 注释与对应 clone 测试。

---

**最后更新**：2026-09-04 · 菜单 Future 改为真实生命周期结果；统一表格在菜单动作完成后清选，纯取消保留选择；显式 `onRemoveRows` 支持到货等任务表安全“移出本次操作”；`canSelectRow` 同时约束任务行菜单，`selectionEnabled` 统一冻结选择派生交互。前序 2026-09-03：UtenEditableGrid 行级操作菜单接入(7 个单据编辑页)。初版 2026-08-12(基础资料五个主档页接入：货品/颜色/客户/供应商/模具)。
