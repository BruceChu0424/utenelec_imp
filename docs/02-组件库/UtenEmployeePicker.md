# UtenEmployeePicker · 通用员工选择器

> 源码：[`uten_employee_picker.dart`](../../lib/components/inputs/uten_employee_picker.dart)、
> [`uten_employee_multi_picker.dart`](../../lib/components/inputs/uten_employee_multi_picker.dart)；
> 部门树变体见 [UtenDepartmentEmployeePicker](UtenDepartmentEmployeePicker.md)；
> 最后核对：2026-08-27。

## 一、适用范围

- `UtenEmployeePicker`：业务员、采购员、经办人、收货人、负责人等单选字段。
- `UtenEmployeeMultiPicker`：通知对象、额外可见人等多选字段。
- `showUtenDepartmentEmployeePicker`：先浏览部门树再选员工，或按姓名/工号跨部门搜索。

业务页面不应重新拼一套员工弹窗。候选加载由调用方注入，公共组件只负责交互、状态和统一展示。

## 二、身份展示契约

1. 主行、确认栏、已选字段和多选 Chip 统一显示 `姓名(工号)`。
2. 括号固定使用 ASCII 半角 `()`，遵守
   [命名规范 §3.3](../00-项目准则/01-命名规范.md#33-文案与标点)。
3. 部门显示在下一行，不得再写成 `姓名(部门)`。
4. `UtenEmployeePickerItem.employeeCode` 必须传真实员工工号；不得用员工 UUID、登录账号或可变姓名代替。
5. 历史详情只带 id/姓名时，单选组件会通过当前 loader 补查工号；补查失败保留姓名，不阻塞业务表单。
6. 隐私受限或历史不可解析接口确实没有工号时才回退为姓名，不展示空括号。

统一格式来自
[`employee_display.dart`](../../lib/shared/formatters/employee_display.dart) 的
`formatEmployeeDisplayName`，自建员工列表也必须复用该格式器。

## 三、候选信息层级

| 层级 | 内容 | 示例 |
|---|---|---|
| 主行 | 姓名 + 工号 | `张三(E001)` |
| 副行 | 部门；必要时追加状态 | `销售部` |
| 选择状态 | 勾选图标、selected 语义和确认栏 | `已选择：张三(E001)` |

状态、历史只读说明或归属数量可以放在副行后半段或独立标签，但不能塞进姓名括号。

## 四、必填与错误反馈

- `required: true` 时标签显示红色 `*`。
- 启用且未选时字段立即显示错误色边框。
- 提交校验失败时通过 `validator` / `errorText` 在字段附近给出恢复提示。
- 不能只靠红色表达必填；标签、边框和错误文案必须同时保持语义。
- 异步加载期间显示骨架，失败显示重试，空结果显示业务空态。

## 五、调用要求

```dart
UtenEmployeePickerItem(
  id: employee.id,
  name: employee.fullName,
  employeeCode: employee.code,
  departmentName: employee.departmentName,
)
```

- 选中回写使用稳定员工 UUID `id`；`姓名(工号)`只用于展示。
- loader 搜索应覆盖姓名和工号，并只允许最新请求回写。
- 已选员工不得因分页不在首屏而消失；历史员工无法再进入候选时保留安全回显。
- 外部访客目录继续遵守最小隐私字段，不为满足内部展示规则额外暴露员工工号。

## 六、回归测试

- [`uten_employee_picker_display_test.dart`](../../test/components/inputs/uten_employee_picker_display_test.dart)：
  ASCII 括号、主行/副行、确认栏、历史补查和多选 Chip。
- [`uten_employee_picker_race_test.dart`](../../test/components/inputs/uten_employee_picker_race_test.dart)：
  弱网旧请求不得覆盖新搜索。
- [`department_employee_picker_test.dart`](../../test/features/employee/department_employee_picker_test.dart)：
  部门定位、分页、竞态和姓名(工号)候选。
