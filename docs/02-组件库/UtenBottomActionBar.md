# UtenBottomActionBar

> 文件：`lib/components/layout/uten_bottom_action_bar.dart`
> 分类：Layout · Phase 1

## 一、用途

详情页 / 表单页的**底部固定操作栏**。上方内容可滚动，主操作按钮固定吸底、常驻可见。

**解决什么问题：**
- 之前 `expense_detail` / `payroll_detail` / `expense_new` 各自手写一遍
  `SafeArea + Container + 顶部分隔线 + child` 的样板，逻辑相同、代码重复。
- 之前 `suggestion_new` 把"提交"按钮内联在列表中段（按钮后面还跟着提示文案），
  与其它表单页不一致——主操作应**吸底、同一行排布**，而不是各占一行。

**何时用：** 页面有一个或多个主操作按钮（提交 / 保存 / 删除 / 撤回 / 下载…），
希望它常驻底部、不随内容滚走。

**已接入（2026-09-10 增补）：** 品质批量审批页 `quality_batch_approval_page.dart` 吸底栏
（`UtenSelectionSummaryPill` 已选计数 + 说明文案 + 提交报告，替换原手写
`SafeArea + Container + 顶部分隔线` 样板）。

**何时不用：** 纯展示页（如 `notice_detail` / `suggestion_detail` 没有主操作）；
列表页的新建入口用 `FloatingActionButton`。

## 二、API（参数表）

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `child` | `Widget` | 必填 | 操作区内容，通常是一个 `Row`，里面放若干 `UtenButton` |
| `padding` | `EdgeInsetsGeometry` | `EdgeInsets.all(16)` | 操作区内边距 |
| `background` | `Color?` | `theme.colorScheme.surface` | 背景色，默认跟随主题 surface |
| `showDivider` | `bool` | `true` | 是否显示顶部分隔线 |

## 三、响应式行为

无三档差异。`SafeArea(top: false)` 自动适配底部安全区（手机刘海/手势条）；
宽度填满父级。多按钮在窄屏会自动换行（取决于 `child` 的 `Row` 是否用 `Expanded`）。

## 四、性能档行为

无动画 / 无模糊，lite / standard / rich 三档表现一致。

## 五、主题与国际化适配

- 背景取 `theme.colorScheme.surface`，分隔线取 `theme.colorScheme.outlineVariant`，
  自动适配浅色 / 深色主题。
- 组件本身无文案，按钮文案由调用方负责 i18n。

## 六、示例代码

**单按钮（下载）：**

```dart
Column(
  children: [
    Expanded(child: ListView(...)),        // 可滚动内容
    UtenBottomActionBar(
      child: UtenButton(
        type: UtenButtonType.primary,
        isExpanded: true,
        icon: Icons.download_outlined,
        onPressed: () => download(),
        child: const Text('下载工资条'),
      ),
    ),
  ],
)
```

**多按钮同一行（删除 + 提交/撤回）：**

```dart
UtenBottomActionBar(
  child: Row(
    children: [
      UtenButton(type: UtenButtonType.ghost, onPressed: delete, child: const Text('删除')),
      const SizedBox(width: 12),
      Expanded(
        child: UtenButton(
          type: UtenButtonType.primary,
          isExpanded: true,
          onPressed: submit,
          child: const Text('提交审批'),
        ),
      ),
    ],
  ),
)
```

## 七、实现要点

- 用 `SafeArea(top: false)` 只吃底部 inset，避免顶部多余留白。
- 用 `DecoratedBox` + `Padding` 而非 `Container`（遵循 `use_decorated_box` lint）。
- `UtenButton.isExpanded: true` 会设 `minWidth: double.infinity`，在 `Row` 中需配合
  `Expanded` 使用，否则会触发无限宽溢出。
- 这是**布局壳**，按钮的样式 / loading / 启用态仍由 `UtenButton` 自己负责。
