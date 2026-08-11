# UtenLocationField（+ showUtenPickerSheet）

> 路径：`lib/shared/widgets/uten_location_field.dart`
> 共享组件（跨 `basic_data` / `department` 复用），不在 `components/` 目录下，但按组件库规范维护。

## 一、用途

**「添加位置」统一交互**——给"新增/编辑树节点"（分类、部门）的对话框用，解决旧版两个问题：

1. **叠弹窗**：旧版选父级是「对话框里再开一个 Dialog」，窄屏灾难。本组件改用**响应式抽屉**（手机底部抽屉 / 桌面右侧抽屉）。
2. **层级不透明**：旧版选了父级也看不出新节点会落在第几级（"几级几级不知道怎么选"）。本组件把**父级路径 + 结果层级**做成一张显眼卡片，实时可见。

3. **误触与无反馈**：树节点点击只更新抽屉内的暂存选择和勾选态；底部固定提供「取消 / 确定」，只有确定后才更新外层编辑表单。

配套的 `showUtenPickerSheet<T>` 是响应式选择器外壳（标题栏 + 可选「顶级」行 + 调用方传入的树），`UtenLocationField` 是位置展示卡片。

**何时用**：任何"给树节点选父级/位置"的场景（货品分类、模具分类、部门）。
**何时不用**：选叶子实体（如选员工、选单个部门归属）用各自的领域 Picker（`UtenDepartmentPicker` 等），不用本组件。

## 二、API

### `UtenLocationField`

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `pathLabel` | `String?` | — | 父级路径/名称；空 → 显示 `rootLabel`（顶级） |
| `rootLabel` | `String` | `'顶级'` | 无父级时显示的文案（分类「顶级分类」/ 部门「公司」） |
| `resultLevelLabel` | `String` | — | 新节点结果层级徽标（分类「L2」/ 部门「二级班组」） |
| `headingLabel` | `String` | `'添加位置'` | 卡片小标题 |
| `changeLabel` | `String` | `'更改'` | 更改入口文案 |
| `onTap` | `VoidCallback` | 必填 | 点卡片/「更改」打开选择器 |
| `enabled` | `bool` | `true` | false 时只读、不显示「更改」 |

### `showUtenPickerSheet<T>(...) → Future<({T? node, bool isRoot})?>`

| 参数 | 说明 |
|---|---|
| `title` | 抽屉标题 |
| `rootLabel` | 顶级行文案 |
| `rootHint` | 顶级行副标题（如「一级部门」，说明选顶级会创建哪级） |
| `childBuilder(ctx, pendingSelection, onSelect, onSelectRoot)` | 调用方构造自己的树，并用 `pendingSelection` 刷新选中勾选；节点点击只暂存 |
| `initialSelection` | 打开时的当前父级/顶级选择，用于初始勾选和确定按钮状态 |
| `showRootOption` | `true`（默认）。**编辑模式传 `false`** 隐藏顶级行——后端 `update` 把 `parentId=null` 当作"不改父级"，编辑选顶级会静默无效 |
| `cancelLabel` / `confirmLabel` | 底部操作按钮文案，默认「取消 / 确定」 |
| 返回 | 取消/X/遮罩/系统返回为 `null`；点击确定后，`isRoot:true`=顶级，`node`=所选父级 |

## 三、响应式行为

- **compact（手机）**：`showModalBottomSheet`，约 85% 屏高，从底部滑入。
- **medium / expanded（桌面）**：`showGeneralDialog` 右侧抽屉，420 宽，从右滑入。
- 两种尺寸都使用固定底栏，取消与确定按钮不随树列表滚走，并遵循底部安全区。
- 与 `UtenDepartmentPicker` 的响应式外壳同款，保证全站选择器手感一致。

## 四、性能档行为

无重动画/模糊，三档一致。

## 五、主题与国际化适配

- 颜色取 `theme.colorScheme`（primary / surfaceContainerHighest / outline），不硬编码。
- 文案目前为参数传入（`pathLabel`/`resultLevelLabel` 由调用方算），标题类硬编码处标了 `TODO(l10n)` 待补 arb。

## 六、示例代码

### 分类新增对话框（货品/模具共用 `CategoryEditDialog`）

```dart
// 卡片：显示当前父级 + 新节点层级
UtenLocationField(
  pathLabel: _parent?.name,
  rootLabel: '顶级分类',
  resultLevelLabel: 'L${(_parent?.level ?? -1) + 1}', // 根=L0，子=父+1
  onTap: _pickParent,
),

// 点「更改」打开抽屉选父级
final result = await showUtenPickerSheet<ProductCategoryNode>(
  context: context,
  title: '选择添加位置',
  rootLabel: '顶级分类',
  showRootOption: !_isEdit, // 编辑不能移到根
  initialSelection: (node: _parent, isRoot: _parent == null),
  childBuilder: (ctx, pending, onSelect, _) => UtenCategoryTreeView(
    mode: UtenCategoryTreeMode.single,
    nodes: tree,
    selectedIds: {pending?.node?.id ?? ''},
    onToggleSelect: onSelect,
  ),
);
if (result == null) return;          // 取消：外层父级不变
setState(() => _parent = result.isRoot ? null : result.node);
```

### 部门新增/编辑（level 由父级推导）

```dart
UtenLocationField(
  pathLabel: parent?.name,
  rootLabel: l10n.departmentLevelCompany,
  resultLevelLabel: _levelLabel(l10n, _childDeptLevel(parent?.level)),
  onTap: () => pickParent(setSt),
),
// _childDeptLevel: 公司/根→一级；一级→二级；二级→三级；三级封顶
```

## 七、实现要点 / 避坑

1. **level 由父级推导，不让用户手选**：这是核心设计决策。旧版部门用下拉框随便选 level、却挂在任意父级下，level 与父级不一致。本组件强制"选父级 → 自动算 level"；后端创建使用该派生层级，实际移动则按父链递归重算整棵子树的 level/path。
2. **编辑模式 `showRootOption: false`**：分类与部门的 `update` 都把 `parentId=null` 当"不改父级"，所以编辑不能移到根——隐藏顶级行避免静默无效。（要支持移到根需改两边 update 语义，待办。）
3. **泛型 `showUtenPickerSheet<T>`**：树内容由调用方传入（保留领域差异：部门有骨架层级、分类扁平），外壳只管响应式 + 标题 + 顶级行。返回用 record `({T? node, bool isRoot})?` 区分「取消 / 选顶级 / 选节点」。
4. **防成环**：调用方在树的 `nodeEnabledPredicate` 里禁掉自己及后代（编辑态），后端另有 `isDescendant` 兜底校验。
5. **两阶段提交**：节点点击只改抽屉 draft；确定才 `Navigator.pop(result)`，取消/X/遮罩/系统返回统一丢弃 draft。调用方必须用 `pendingSelection` 驱动树的 `selectedIds`，否则点击后没有勾选反馈。
6. **部门骨架仅作结构父级**：部门编辑的“上级位置”允许选择管理中心等骨架节点，以维护其下一级部门；员工归属、权限等普通部门选择器仍保持骨架不可选。
7. **骨架自身不可移动**：公司/管理中心等组织骨架编辑时，位置卡片为只读并显示原层级；只有业务部门可以更改上级。分类/部门未实际改变父级时客户端不发送 `parentId`，服务端也先比较真实父级；实际移动在事务级锁内防环，并以递归 CTE 同步整棵子树的 level/path（含软删后代），避免只改名称误触重算或并发移动成环。

---

**最后更新**：2026-08-02 · **被调用方**：`CategoryEditDialog`（货品/模具/客户/供应商）、`DepartmentEditDialog`
