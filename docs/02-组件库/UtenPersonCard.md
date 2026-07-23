# UtenPersonCard

> 文件：`lib/components/cards/uten_person_card.dart`
> 分类：Cards · Phase 2

## 一、用途

业务无关的"人物/实体卡片"：头像 + 标题 + 副标题 + 尾部控件，**卡片化、改一处全站生效**。

用于员工、审批人、发布人、联系人、部门负责人等任何"头像+名称+一行说明+徽章"形态的展示。配合 `UtenStatusBadge`/`EmployeeStatusBadge` 放在 `trailing`。

**何时用：** 列表、网格、详情页关联人员、卡片墙里的"人"。
**何时不用：** 纯文本行（用 ListTile/ListView）；非"人/实体"的纯数据卡（用 `UtenStatCard`）。

## 二、API（参数表）

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| title | String | 必填 | 标题（如姓名） |
| subtitle | String? | null | 副标题（如 工号·部门·岗位） |
| avatarText | String? | null | 头像字符（缺省取 title 首字） |
| avatarColor | Color? | null | 头像背景（缺省 primaryContainer） |
| trailing | Widget? | null | 尾部（常放状态徽章/操作） |
| onTap / onLongPress | VoidCallback? | null | 点击/长按 |
| margin | EdgeInsetsGeometry? | 12/4 | 外边距 |
| elevation | UtenCardElevation | low | 阴影 |

## 三、响应式行为

无固定宽度，自适应父容器；列表单列、网格多列均可用（配合 `UtenResponsiveGrid`）。卡片视觉由 `UtenCard` 承载（性能档/主题自适应）。

## 四、性能档行为

沿用 `UtenCard`：lite 档去阴影、玻璃降级实心。

## 五、主题与国际化

颜色全走 `colorScheme`；`title`/`subtitle` 由调用方负责 i18n。

## 六、示例代码

```dart
UtenPersonCard(
  title: e.fullName,
  subtitle: '${e.code} · ${e.departmentName} · ${e.positionName}',
  avatarText: e.fullName,
  trailing: EmployeeStatusBadge(status: e.status),
  onTap: () => context.push('/employee/${e.id}'),
);
```

## 七、实现要点

- 内部复用 `UtenCard`（padding 设 0，由 `ListTile` 的 contentPadding 控内边距），ink ripple 正常。
- 业务无关：组件不含任何业务模型，调用方传入字符串/Widget。
