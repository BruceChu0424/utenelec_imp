# UtenSectionHeader

> 文件：`lib/components/layout/uten_section_header.dart`
> 分类：Layout · Phase 1

## 一、用途

统一的**区块标题**，替代此前散落在各页面的多套实现：

| 旧实现 | 样式 | 现状 |
|---|---|---|
| `expense_detail._sectionTitle` | titleSmall · w700 · onSurface · 无图标 | 已迁移 |
| `payroll_detail._buildSectionTitle` | titleSmall · w700 · onSurface · 带图标 | 已迁移 |
| `settings._SectionTitle` | titleSmall · w600 · onSurfaceVariant · letterSpacing 0.5 | 弱化样式保留为 `subdued` |
| 各页内联裸 `Text` | 字号 / 字重不一 | 已迁移 |

**何时用：** 卡片或区块上方的小标题（如"报销明细""应发明细""合计""外观"）。

**何时不用：** 页面级大标题（用 `headlineSmall`/`titleLarge`）；dashboard 的主区块标题
（用更大的 `titleMedium`，保留各页独立的 `_buildSectionHeader`）。

## 二、API（参数表）

| 参数 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `title` | `String` | 必填 | 标题文字 |
| `icon` | `IconData?` | `null` | 可选前缀图标（青绿 `teal600`，仅非 `subdued` 时着色） |
| `trailing` | `Widget?` | `null` | 可选尾部控件（如"添加"按钮、计数徽章） |
| `subdued` | `bool` | `false` | 弱化样式：颜色更浅、字重更轻，用于设置页分组标签 |

两种强调度：

| | `subdued: false`（默认，内容区标题） | `subdued: true`（分组标签） |
|---|---|---|
| 字色 | `onSurface` | `onSurfaceVariant` |
| 字重 | `w700` | `w600` |
| letterSpacing | 0 | 0.5 |

字号统一 `titleSmall`。

## 三、响应式行为

无三档差异。

## 四、性能档行为

无动画 / 无模糊，三档一致。

## 五、主题与国际化适配

- 字色全部取自 `theme.colorScheme`（`onSurface` / `onSurfaceVariant`），自动适配深浅主题。
- 图标固定品牌色 `UtenColors.teal600`。
- `title` 为业务文案，由调用方负责 i18n。

## 六、示例代码

**基础：**

```dart
UtenSectionHeader(title: '报销明细')
```

**带前缀图标：**

```dart
UtenSectionHeader(title: '应发明细', icon: Icons.add_circle_outline_rounded)
```

**带尾部操作（标题 + 添加按钮同一行）：**

```dart
UtenSectionHeader(
  title: '报销明细 (${items.length})',
  trailing: TextButton.icon(
    onPressed: addItem,
    icon: const Icon(Icons.add_rounded, size: 18),
    label: const Text('添加'),
  ),
)
```

**弱化（设置页分组标签）：**

```dart
UtenSectionHeader(title: l10n.settingsSectionAppearance, subdued: true)
```

## 七、实现要点

- 内部用 `Flexible(child: Text(...))` 而非 `Expanded`。`Expanded` 要求主轴有界高度，
  放进 `ListView`（无界高度）会抛异常；`Flexible` 仅约束水平主轴，可安全用于滚动列表。
- `trailing` 与标题之间固定 `SizedBox(width: 8)` 间距，标题 `Flexible` 可在窄屏省略号截断，
  保证尾部按钮不被挤掉。
- 这只解决"区块标题"这一层；页面级大标题不在本组件职责内。
