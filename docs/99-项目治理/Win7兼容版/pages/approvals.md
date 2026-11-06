# approvals：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-228 · lib/features/approvals/pages/approval_center_page.dart

模块 `approvals`；337 行；SHA256 `1c751bd8789cda8c01a93089dc4a44d36561fb8d1d24b7c968d26d4a0a34aacb`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | ApprovalCenterPage @23 (page-class)<br>_ApprovalCenterPageState @38 (state-class) |
| 真实路由绑定 | /approvals/:departmentCode；router @756；builder ['ApprovalCenterPage']；redirect None<br>/sales/manager-review；router @1941；builder ['ApprovalCenterPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | expense:approve @85；定义 lib/shared/auth/permissions.dart:58<br>expense:approve:finance_initial @86；定义 lib/shared/auth/permissions.dart:60<br>expense:approve:finance_review @87；定义 lib/shared/auth/permissions.dart:61<br>expense:pay @88；定义 lib/shared/auth/permissions.dart:109<br>expense:view @89；定义 lib/shared/auth/permissions.dart:56<br>expense:approve:executive @92；定义 lib/shared/auth/permissions.dart:62<br>expense:approve:department @93；定义 lib/shared/auth/permissions.dart:59<br>application:approve:finance_initial @96；定义 lib/shared/auth/permissions.dart:78<br>application:approve:finance_review @97；定义 lib/shared/auth/permissions.dart:80<br>application:receive @98；定义 lib/shared/auth/permissions.dart:87<br>application:pay @99；定义 lib/shared/auth/permissions.dart:88<br>application:prepayment:link_finance @100；定义 lib/shared/auth/permissions.dart:89<br>application:view @101；定义 lib/shared/auth/permissions.dart:76<br>application:approve:executive @105；定义 lib/shared/auth/permissions.dart:84<br>application:approve:vice_executive @106；定义 lib/shared/auth/permissions.dart:82<br>application:approve:department @110；定义 lib/shared/auth/permissions.dart:77<br>application:approve:procurement @111；定义 lib/shared/auth/permissions.dart:85<br>application:approve:department @113；定义 lib/shared/auth/permissions.dart:77<br>sales_order_manager:view @121；定义 lib/shared/auth/permissions.dart:527<br>sales_quote_manager:view @122；定义 lib/shared/auth/permissions.dart:523<br>approval_policy:manage @280；定义 lib/shared/auth/permissions.dart:63 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/expense/repositories/expense_repository.dart；接口：/expense-claims |
| 动作处理 | 未静态确认；不能当作不存在 |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/expenseclaim/ExpenseClaimController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 同页存在多个路由/参数实例；不能据此认定业务、权限或生命周期等价。<br>存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/buttons/uten_refresh_button.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/components/layout/uten_refresh_scope.dart` (sharedComponents)；`lib/components/feedback/uten_segment_badge_label.dart` (sharedComponents)；`lib/core/theme/uten_tokens.dart` (core)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/shared/badges/badge_registry.dart` (sharedComponents)；`lib/features/applications/pages/business_application_list_page.dart` (other)；`lib/features/expense/pages/expense_approval_list_page.dart` (other)；`lib/features/expense/providers/expense_providers.dart` (providers)；`lib/features/expense/repositories/expense_repository.dart` (repositories)；`lib/features/sales/pages/sales_manager_review_page.dart` (other)。

## W7-BIZ-229 · lib/features/approvals/pages/approval_policy_settings_page.dart

模块 `approvals`；447 行；SHA256 `972e3b9eb0b6e03606167a6836a29491517d1014dd1f1ffad0f2c05e734e0a94`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | ApprovalPolicySettingsPage @32 (page-class)<br>_ApprovalPolicySettingsPageState @39 (state-class)<br>_PolicyEditor @220 (supporting-class)<br>_PolicyEditorState @227 (state-class) |
| 真实路由绑定 | /approvals/settings；router @751；builder ['ApprovalPolicySettingsPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | approval_policy:manage @95；定义 lib/shared/auth/permissions.dart:63<br>approval_policy:manage @278；定义 lib/shared/auth/permissions.dart:63<br>approval_policy:manage @322；定义 lib/shared/auth/permissions.dart:63 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/approvals/repositories/approval_policy_repository.dart；接口：/approval-policy/departments |
| 动作处理 | _edit @60 [method-declaration-candidate] 提示 ['edit']；Future<void> _edit(ApprovalDepartmentPolicy policy) async {<br>UtenCloseButton @74 [action-like-invocation] 提示 ['close']；UtenCloseButton(<br>_edit @168 [action-like-invocation] 提示 ['edit']；? () => _edit(row)<br>_edit @194 [action-like-invocation] 提示 ['edit']；? _edit(row)<br>_reconcile @239 [method-declaration-candidate] 提示 ['reconcile']；Future<void> _reconcile() async {<br>_save @266 [method-declaration-candidate] 提示 ['save']；Future<void> _save() async {<br>save @289 [action-like-invocation] 提示 ['save']；.save(_policy, _selected?.id);<br>UtenCloseButton @334 [action-like-invocation] 提示 ['close']；UtenCloseButton( |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/approvalpolicy/DepartmentApprovalPolicyController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/buttons/uten_close_button.dart` (sharedComponents)；`lib/components/buttons/uten_refresh_button.dart` (sharedComponents)；`lib/components/feedback/uten_busy_overlay.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/inputs/uten_employee_picker.dart` (sharedComponents)；`lib/components/inputs/uten_field_hint_icon.dart` (sharedComponents)；`lib/components/layout/uten_adaptive_panel.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/core/network/api_exception.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/shared/auth/sensitive_write.dart` (sharedComponents)；`lib/shared/badges/badge_registry.dart` (sharedComponents)；`lib/shared/models/retained_async_page.dart` (models)；`lib/shared/providers/export_context_epoch_provider.dart` (sharedComponents)；`lib/shared/providers/sensitive_read_boundary_provider.dart` (sharedComponents)；`lib/shared/providers/session_provider.dart` (sharedComponents)；`lib/shared/widgets/sensitive_content_boundary.dart` (sharedComponents)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/approvals/repositories/approval_policy_repository.dart` (repositories)。
