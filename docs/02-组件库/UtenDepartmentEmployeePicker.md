# UtenDepartmentEmployeePicker · 部门员工选择器

> 源码：[`department_employee_picker.dart`](../../lib/features/employee/widgets/department_employee_picker.dart) · 统一层级搜索契约：[UtenHierarchySearch](UtenHierarchySearch.md) · 最后核对：2026-08-14。

## 一、用途与入口

`showUtenDepartmentEmployeePicker(context, ref)` 用于模具保管人、客户/供应商业务员等表单选择员工，返回 `UtenEmployeePickerItem?`；取消返回 `null`。`DepartmentEmployeePickerField` 是主档表单包装。

它支持两种找人方式：按部门树浏览所选部门及其子树人员，或在左树顶部直接按部门名称/编号、员工姓名/工号搜索并反向定位所属部门。

## 二、响应式与交互

- compact 使用自适应底部抽屉，medium/expanded 使用 720dp 右侧滑入面板。
- 内部为“左部门树 + 右员工列表”，左栏 compact 150dp、其余 240dp。
- 统一搜索按 100 条逐页收集命中员工的 `departmentId`，展开祖先路径并默认定位首个有效部门；右侧通过“加载更多员工”继续追加后续页，不会把可选范围截断在前 100 人。
- 点击包含命中员工的相关部门时保留关键词，右侧查询该部门子树内的同词员工；只命中部门名称/编号时展示该部门子树全部员工。
- request version 防止旧响应覆盖；部门树、人员搜索、完整定位、空结果都有明确状态。清空输入恢复普通浏览。

## 三、最小权限树

选择器不得复用部门管理用的 `/api/org/departments/tree`，因为后者要求 `department:view`。当前使用：

- `GET /api/org/departments/employee-picker-tree`，权限 `employee:view`。
- DTO 仅含 `id/code/name/level/parentId/children`，不返回负责人、编制、统计或员工数据。
- 员工候选仍走 `GET /api/org/employees`，权限同为 `employee:view`；搜索支持工号、姓名，服务端也支持车牌，返回摘要中的 `departmentId` 仅用于定位。

该端点只是让已有 `employee:view` 的业务用户获得完成员工选择所需的最小组织路径，不授予或替代 `department:view`。

## 四、回归测试

[`department_employee_picker_test.dart`](../../test/features/employee/department_employee_picker_test.dart) 覆盖员工搜索后展开所属部门、纯部门命中、旧请求竞态、后续页加载与选择；服务端 `DepartmentEmployeePickerSecurityContractTest` 覆盖端点权限和最小 DTO 边界。共享的分页收集与请求取消规则由 `category_tree_search_test.dart` 覆盖。
