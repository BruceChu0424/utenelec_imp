# UtenLocationField（+ showUtenPickerSheet）

> 路径：`lib/shared/widgets/uten_location_field.dart`
> 共享组件（跨 `basic_data` / `department` 复用），不在 `components/` 目录下，但按组件库规范维护。

## 一、用途

**「添加位置」统一交互**——给"新增/编辑树节点"（分类、部门）的对话框用，解决旧版两个问题：

1. **叠弹窗**：旧版选父级是「对话框里再开一个 Dialog」，窄屏灾难。本组件改用**响应式抽屉**（手机底部抽屉 / 桌面右侧抽屉）。
2. **层级不透明**：旧版选了父级也看不出新节点会落在第几级（"几级几级不知道怎么选"）。本组件把**父级路径 + 结果层级**做成一张显眼卡片，实时可见。

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
| `childBuilder(ctx, onSelect, onSelectRoot)` | 调用方构造自己的树（`UtenCategoryTreeView` / `UtenDepartmentTreeView`），在 `onToggleSelect` 里调 `onSelect` |
| `showRootOption` | `true`（默认）。**编辑模式传 `false`** 隐藏顶级行——后端 `update` 把 `parentId=null` 当作"不改父级"，编辑选顶级会静默无效 |
| 返回 | `null`=取消；`isRoot:true`=选了顶级；`node`=选了该节点 |

## 三、响应式行为

- **compact（手机）**：`showModalBottomSheet`，约 85% 屏高，从底部滑入。
- **medium / expanded（桌面）**：`showGeneralDialog` 右侧抽屉，420 宽，从右滑入。
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
  childBuilder: (ctx, onSelect, _) => UtenCategoryTreeView(
    mode: UtenCategoryTreeMode.single,
    nodes: tree,
    selectedIds: {_parent?.id ?? ''},
    onToggleSelect: onSelect,
  ),
);
if (result == null) return;          // 取消
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

1. **level 由父级推导，不让用户手选**：这是核心设计决策。旧版部门用下拉框随便选 level、却挂在任意父级下，level 与父级不一致（后端 `DepartmentService.create/update` 信任前端 level）。本组件强制"选父级 → 自动算 level"，杜绝不一致。部门移动时后端还会 `relevelSubtree` 重算子树。
2. **编辑模式 `showRootOption: false`**：分类与部门的 `update` 都把 `parentId=null` 当"不改父级"，所以编辑不能移到根——隐藏顶级行避免静默无效。（要支持移到根需改两边 update 语义，待办。）
3. **泛型 `showUtenPickerSheet<T>`**：树内容由调用方传入（保留领域差异：部门有骨架层级、分类扁平），外壳只管响应式 + 标题 + 顶级行。返回用 record `({T? node, bool isRoot})?` 区分「取消 / 选顶级 / 选节点」。
4. **防成环**：调用方在树的 `nodeEnabledPredicate` 里禁掉自己及后代（编辑态），后端另有 `isDescendant` 兜底校验。

---

**最后更新**：2026-07-24 · **被调用方**：`CategoryEditDialog`（货品/模具）、`department_page._showCreateDialog/_showEditDialog`
