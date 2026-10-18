# UtenDepartmentEmployeePicker · 部门员工选择器

> 源码：[`department_employee_picker.dart`](../../lib/features/employee/widgets/department_employee_picker.dart) ·
> 通用员工展示契约：[UtenEmployeePicker](UtenEmployeePicker.md) ·
> 统一层级搜索契约：[UtenHierarchySearch](UtenHierarchySearch.md) · 最后核对：2026-10-17。

## 一、用途与入口

`showUtenDepartmentEmployeePicker(context, ref)` 用于模具保管人、客户/供应商业务员等表单选择员工，返回 `UtenEmployeePickerItem?`；取消返回 `null`。`DepartmentEmployeePickerField` 是主档表单包装。

它支持两种找人方式：按部门树浏览所选部门及其子树人员，或在左树顶部直接按部门名称/编号、员工姓名/工号搜索并反向定位所属部门。

**二次操作契约(2026-08-27，全站滑窗统一)**：点员工表格行仅高亮暂存，点底部「确定」才返回；「取消」/关闭 = 放弃。候选表格将姓名、工号、部门、账号状态、在职状态分列，只显示接口已授权的信息；字段与底部确认栏仍使用 ASCII 半角括号 `姓名(工号)`，接口没有返回工号时回退为姓名。确认栏为共享 [UtenPickerConfirmBar](UtenPickerConfirmBar.md)。账号状态来自账号记录，在职状态来自员工档案；接口缺失字段显示未提供，不将缺失、停用或锁定误报为未开通。

## 二、响应式与交互

- compact 使用自适应底部抽屉，medium/expanded 使用 `min(屏宽, max(720, 屏宽 × 75%))` 右侧滑入面板（2026-10-17 全站滑窗档位 `UtenPanelWidth.browse`），与销售客户选择器一致。
- 内部为“左部门树 + 右员工表格”，公司实际父子层级与深绿无缩进层级色同时保留，右侧复用 `MasterDataTableView`。宽屏使用可拖动的 `UtenSplitView`，初始左宽按部门文本量测，手动最小宽度为 160dp；字号放大或触控目标需要更多空间时提高安全下限，宽度记忆和双击复位保持有效。
- 搜索框按左栏实际宽度调整两侧留白：不足 240dp 时为 8dp，其余为 12dp；缩窄后仍能输入、清除和展开/选择部门，长部门名称保留完整路径提示。紧凑布局将搜索和部门入口放到表格上方，表格在自身区域横向滚动。
- 统一搜索按 100 条逐页收集命中员工的 `departmentId`，展开祖先路径并默认定位首个有效部门；右侧通过“加载更多员工”继续追加后续页，不会把可选范围截断在前 100 人。
- 点击包含命中员工的相关部门时保留关键词，右侧查询该部门子树内的同词员工；只命中部门名称/编号时展示该部门子树全部员工。
- request version 防止旧响应覆盖；部门树、人员搜索、完整定位、空结果都有明确状态。清空输入恢复普通浏览。
- 组织树加载、候选请求与最终返回共用 `EmployeePickerAccess` 身份/服务器/权限边界；即使切换后又恢复原值，旧请求与旧选择也失效。失效时清空选择并仅关闭自身滑窗，后来打开的对话框不受影响。

## 三、最小权限树

选择器不得复用部门管理用的 `/api/org/departments/tree`，因为后者要求 `department:view`。当前使用：

- `GET /api/org/departments/employee-picker-tree`，仅供内部员工主体。已有 `employee:view`、`account:support`、`notice:publish`、`client:assign`、`warehouse:edit`、`employee:handover`、`employee:offboard`、`audit_log:view` 任一候选选择权限，或同时满足超级管理员与 `authorization:manage`，即可读取最小组织路径；访客主体不可读取。
- DTO 仅含 `id/code/name/level/parentId/children`，不返回负责人、编制、统计或员工数据。
- 本专用选择器的员工候选仍走 `GET /api/org/employees`，权限保持 `employee:view`；搜索支持工号、姓名，服务端也支持车牌，返回摘要中的 `departmentId` 仅用于定位。开通账号、客户授权、通知、仓库负责人、交接、审计等共享员工选择场景继续使用各自的业务候选接口，组织树不会增加候选人。

该端点只提供公司真实的组织层级，候选人和业务可操作性仍由原接口决定，不授予或替代 `department:view`、`employee:view`。共享员工选择器按已有授权候选的 `departmentId` 保留所属部门及祖先；访客接待人选择关闭部门分类，不加载组织树。

## 四、回归测试

[`department_employee_picker_test.dart`](../../test/features/employee/department_employee_picker_test.dart) 覆盖表格重要列、独立账号/在职状态与缺失字段、暂存与确认、员工搜索后展开所属部门、纯部门命中、旧请求竞态、后续页加载与选择，以及缩窄分类区的搜索和部门操作；同时覆盖身份/服务器/权限切换后恢复原值、迟到树/候选、仅关闭自身滑窗、弹窗返回前身份变化与打开前的请求间隙。
[`uten_employee_picker_display_test.dart`](../../test/components/inputs/uten_employee_picker_display_test.dart)
覆盖字段及确认值 `姓名(工号)` 和历史回显补查。服务端
`DepartmentEmployeePickerSecurityContractTest` 通过真实 Spring 方法授权代理覆盖各项业务权限独立可读、访客与无关权限拒绝、超管条件、强制改密、员工名册仍受限及最小 DTO 边界。共享的分页收集与请求取消规则由
`category_tree_search_test.dart` 覆盖。
