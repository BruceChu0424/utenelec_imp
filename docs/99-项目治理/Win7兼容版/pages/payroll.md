# payroll：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-088 · lib/features/payroll/pages/payroll_generate_page.dart

模块 `payroll`；595 行；SHA256 `c660be38aad1bae8249f74e683cd5b893dbff34c86e4b0bfa75ae9295f6c6319`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | PayrollGeneratePage @28 (page-class)<br>_PayrollGeneratePageState @36 (state-class)<br>_PayrollItemSwitch @462 (supporting-class)<br>_ServerBatchPreview @483 (supporting-class)<br>_SlipPreviewRow @571 (supporting-class) |
| 真实路由绑定 | /payroll/generate；router @602；builder ['PayrollGeneratePage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/payroll/repositories/payroll_repository.dart；接口：/org/departments/tree、/payroll/batches、/payroll/slips |
| 动作处理 | restoreFormDraft @58 [method-declaration-candidate] 提示 ['restore']；Future<void> restoreFormDraft(Map<String, dynamic> data) async {<br>addPostFrameCallback @80 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) => initializeFormDraft());<br>copyWith @302 [action-like-invocation] 提示 ['copy']；?.copyWith(<br>_submitDraft @389 [action-like-invocation] 提示 ['submit']；await _submitDraft();<br>createPayrollBatch @399 [action-like-invocation] 提示 ['create']；() => createPayrollBatch(<br>PayrollBatchCreateInput @401 [action-like-invocation] 提示 ['create']；PayrollBatchCreateInput(<br>saveFormDraftNow @422 [action-like-invocation] 提示 ['save']；await saveFormDraftNow();<br>_submitDraft @435 [method-declaration-candidate] 提示 ['submit']；Future<void> _submitDraft() async {<br>submitPayrollBatch @443 [action-like-invocation] 提示 ['submit']；await submitPayrollBatch(ref, batch.id);<br>completeFormDraft @444 [action-like-invocation] 提示 ['complete']；await completeFormDraft();<br>copyWith @551 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @562 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @586 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith( |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/org/department/DepartmentController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/payroll/PayrollController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_info_row.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_busy_overlay.dart` (sharedComponents)；`lib/components/inputs/uten_dropdown_field.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_form_grid.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/router/nav_helpers.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/core/utils/china_datetime.dart` (core)；`lib/shared/drafts/form_draft_mixin.dart` (sharedComponents)；`lib/shared/drafts/form_draft_catalog.dart` (sharedComponents)；`lib/features/payroll/repositories/payroll_repository.dart` (repositories)；`lib/features/payroll/models/payroll_batch.dart` (models)；`lib/features/payroll/models/payroll_slip.dart` (models)；`lib/features/payroll/providers/payroll_providers.dart` (providers)。

## W7-BIZ-089 · lib/features/payroll/pages/payroll_review_page.dart

模块 `payroll`；625 行；SHA256 `9dcb5a3c20f1d1fa7ec752ca350a49ab73a6414d8a256373ab9c433f0d97a7f6`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | PayrollReviewPage @42 (page-class)<br>_PayrollReviewPageState @49 (state-class)<br>_BatchChip @383 (supporting-class)<br>_BatchDetail @441 (supporting-class)<br>_BatchDetailState @450 (state-class) |
| 真实路由绑定 | /payroll/review；router @607；builder ['PayrollReviewPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | payroll:generate @190；定义 lib/shared/auth/permissions.dart:51<br>payroll:review @204；定义 lib/shared/auth/permissions.dart:52<br>payroll:publish @226；定义 lib/shared/auth/permissions.dart:53 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | showUtenReviewerConfirmDialog @249 [action-like-invocation] 提示 ['confirm']；final confirmed = await showUtenReviewerConfirmDialog(<br>_askRejectReason @286 [action-like-invocation] 提示 ['reject']；reason = await _askRejectReason();<br>submitPayrollBatch @294 [action-like-invocation] 提示 ['submit']；await submitPayrollBatch(ref, batch.id);<br>approvePayrollBatch @296 [action-like-invocation] 提示 ['approve']；await approvePayrollBatch(ref, batch.id);<br>rejectPayrollBatch @298 [action-like-invocation] 提示 ['reject']；await rejectPayrollBatch(ref, batch.id, reason!);<br>_askRejectReason @318 [method-declaration-candidate] 提示 ['reject']；Future<String?> _askRejectReason() async {<br>copyWith @421 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleSmall?.copyWith(<br>copyWith @429 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.labelSmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/feedback/uten_dialog.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/data_display/uten_detail_summary_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_reviewer_responsibility_notice.dart` (sharedComponents)；`lib/components/inputs/uten_field_message.dart` (sharedComponents)；`lib/components/inputs/uten_input_decoration.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/layout/uten_paged_grid.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/shared/formatters/money_display.dart` (sharedComponents)；`lib/components/layout/uten_collapsing_header_scroll_view.dart` (sharedComponents)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/payroll/models/payroll_batch.dart` (models)；`lib/features/payroll/models/payroll_slip.dart` (models)；`lib/features/payroll/providers/payroll_providers.dart` (providers)。

## W7-BIZ-090 · lib/features/payroll/pages/payroll_slip_detail_page.dart

模块 `payroll`；361 行；SHA256 `fb5e6f503c17ac2a58972e1bf2bd5e351193d2f801d077560236bb04180b7ff4`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | PayrollSlipDetailPage @30 (page-class)<br>_PayrollSlipDetailPageState @40 (state-class)<br>_LoadingView @119 (supporting-class)<br>_DetailContent @133 (supporting-class) |
| 真实路由绑定 | /payroll/slip/:id；router @596；builder ['PayrollSlipDetailPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | _download @55 [method-declaration-candidate] 提示 ['download']；Future<void> _download(PayrollSlip slip) async {<br>downloadPayrollSlip @57 [action-like-invocation] 提示 ['download']；final bytes = await downloadPayrollSlip(ref, slip.id);<br>saveBytes @61 [action-like-invocation] 提示 ['save']；final savedPath = await saveBytes(<br>addPostFrameCallback @93 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) => _markViewed());<br>_download @109 [action-like-invocation] 提示 ['download']；onAction: () => _download(slip),<br>copyWith @258 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @287 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/core/utils/china_datetime.dart` (core)；`lib/components/buttons/click_guard.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_detail_summary_card.dart` (sharedComponents)；`lib/components/data_display/uten_info_row.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/feedback/uten_skeleton.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/io/file_saver.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/features/payroll/models/payroll_download.dart` (models)；`lib/features/payroll/models/payroll_item.dart` (models)；`lib/features/payroll/models/payroll_slip.dart` (models)；`lib/features/payroll/providers/payroll_providers.dart` (providers)。

## W7-BIZ-091 · lib/features/payroll/pages/payroll_slip_list_page.dart

模块 `payroll`；217 行；SHA256 `d43747d18cf8d400b09d44cfabe6c8537f4c6f48d66adde1830bb38032997d07`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | PayrollSlipListPage @37 (page-class)<br>_PayrollSlipListPageState @45 (state-class) |
| 真实路由绑定 | /payroll/slip；router @591；builder ['PayrollSlipListPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | 未静态确认；不能当作不存在 |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/core/utils/china_datetime.dart` (core)；`lib/shared/models/retained_async_page.dart` (models)；`lib/shared/models/paged_result.dart` (models)；`lib/components/data_display/uten_status_cell_color.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/shared/formatters/money_display.dart` (sharedComponents)；`lib/features/basic_data/models/master_facet.dart` (models)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/payroll/models/payroll_slip.dart` (models)；`lib/features/payroll/providers/payroll_providers.dart` (providers)。
