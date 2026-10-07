# UtenEmployeePicker · 通用员工选择器

> 源码：[`uten_employee_picker.dart`](../../lib/components/inputs/uten_employee_picker.dart)、
> [`uten_employee_multi_picker.dart`](../../lib/components/inputs/uten_employee_multi_picker.dart)；
> 部门树变体见 [UtenDepartmentEmployeePicker](UtenDepartmentEmployeePicker.md)；
> 共用面板：[`uten_employee_selection_panel.dart`](../../lib/components/inputs/uten_employee_selection_panel.dart)；
> 最后核对：2026-10-07。

## 一、适用范围

- `UtenEmployeePicker`：业务员、采购员、经办人、收货人、负责人等单选字段。
- `UtenEmployeeMultiPicker`：通知对象、额外可见人等多选字段。
- `showUtenDepartmentEmployeePicker`：先浏览部门树再选员工，或按姓名/工号跨部门搜索。

业务页面不应重新拼一套员工弹窗。候选加载由调用方注入，公共组件只负责交互、状态和统一展示。

单选和多选共用 `UtenEmployeeSelectionPanel`：宽屏右滑窗宽度为 `max(720, 屏宽 × 50%)`，
左侧部门栏、右侧人员列表、深绿层级色、拖动分割线、选中行颜色与销售客户选择器一致；窄屏为底部双栏抽屉。
搜索放左栏顶部，支持部门、姓名和工号。点选只更改抽屉中的选择，确定才回填，取消不更改原值。
多选跨部门和搜索保留已选人员，清空后也可以确定返回空集合；负责人等单人字段继续单选。

左栏只由当前业务接口已授权返回的候选生成，不额外调用人事目录。按 `departmentId` 分组，
同名部门不合并；缺少部门 ID 的候选归入“未提供部门”，不从姓名或提示文字推测部门。
访客申请的接待人搜索保持隐私规则，通过 `showDepartmentFilter: false` 关闭部门目录。

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
- 异步加载期间显示加载状态，失败显示重试，空结果显示业务空态；加载或失败期间不能确认旧选项。

## 五、调用要求

```dart
UtenEmployeePickerItem(
  id: employee.id,
  name: employee.fullName,
  employeeCode: employee.code,
  departmentId: employee.departmentId,
  departmentName: employee.departmentName,
  subtitle: '在职',
)
```

- `id` 保持候选接口的身份语义：员工业务字段使用 employeeId，审计目录使用 actorId（用户或访客 ID）；不能在 userId 与 employeeId 之间猜测或互换。`姓名(工号)`只用于展示。
- loader 搜索应覆盖姓名和工号，并只允许最新请求回写。
- 候选范围会随车间、部门或业务对象切换的字段传 `candidateScopeKey`；范围或上游选中值改变后，旧抽屉不得回填。
- `departmentName` 仅放部门名称，状态、岗位、无账号提示和归属条数放 `subtitle`。
- 候选必须完整分页，不能把首 50/100 人当作完整部门目录；常规员工仓储复用 `listPickerCandidates`。
- 专用候选接口保留各自权限和资格；超过支持的目录上限须明确提示缩小搜索范围，不能悄悄截断。
- 已选员工不得因分页不在首屏而消失；历史员工无法再进入候选时保留安全回显。
- 外部访客目录继续遵守最小隐私字段，不为满足内部展示规则额外暴露员工工号。
- 字段补查、已打开弹层和确认回填均绑定登录身份（含代操作、登录纪元）、服务器地址及有效权限代际。任一边界变化即作废旧请求，即使随后切回原值也不接受；失效只移除自己的弹层，不关闭后来打开的对话框。
- 本地部门过滤与服务端姓名/工号搜索分开处理：部门名称可匹配本次已授权完整目录；姓名/工号搜索返回空时，不得从旧目录重新注入同名人员。正常跨部门、跨关键词多选仍保留已选值，不因一次过滤结果缺席而清空。
- 分页加载须在开始时捕获同一个仓储，并在每个 await 后复核访问代际；不能逐页重新读取仓储，把切换服务器前后的候选混合。直接使用自有弹层的调用方也要在 pop 后、回填前复核同一访问 ticket，并在 finally 中释放订阅。

## 六、回归测试

- [`uten_employee_selection_panel_test.dart`](../../test/components/inputs/uten_employee_selection_panel_test.dart)：
  部门 UUID 分组、单选确认、多选跨部门、取消与清空、禁选、失败重试、异步竞态和窄屏大字。

- [`uten_employee_picker_display_test.dart`](../../test/components/inputs/uten_employee_picker_display_test.dart)：
  ASCII 括号、主行/副行、确认栏、历史补查和多选 Chip。
- [`uten_employee_picker_race_test.dart`](../../test/components/inputs/uten_employee_picker_race_test.dart)：
  弱网旧请求不得覆盖新搜索。
- [`uten_employee_picker_access_test.dart`](../../test/components/inputs/uten_employee_picker_access_test.dart)：
  单选/多选身份、服务器与权限 ABA，迟到补查、仅关闭本弹层、加载失败禁确认及受限空搜索。
- [`audit_actor_picker_pagination_test.dart`](../../test/features/admin/audit_actor_picker_pagination_test.dart)、
  [`audit_actor_picker_return_scope_test.dart`](../../test/features/admin/audit_actor_picker_return_scope_test.dart)：
  同仓储完整分页、每页身份复核及真实审计页 pop 到回填之间的身份切换。
- [`department_employee_picker_test.dart`](../../test/features/employee/department_employee_picker_test.dart)：
  部门定位、分页、竞态和姓名(工号)候选。
