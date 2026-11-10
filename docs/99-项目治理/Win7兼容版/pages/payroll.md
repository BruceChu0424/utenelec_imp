# payroll：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-088 · lib/features/payroll/pages/payroll_generate_page.dart

模块 `payroll`；603 行；SHA256 `a65c98f1216f29a7a5bfd1334aa4f7f6873e0201069db35fd062ade9898cd765`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | PayrollGeneratePage @31 (page-class)<br>_PayrollGeneratePageState @39 (state-class)<br>_PayrollItemSwitch @471 (supporting-class)<br>_ServerBatchPreview @492 (supporting-class)<br>_ServerBatchPreviewState @501 (state-class)<br>_SlipPreviewRow @579 (supporting-class) |
| 真实路由绑定 | /payroll/generate；router @678；builder ['PayrollGeneratePage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/payroll/repositories/payroll_repository.dart；接口：/org/departments/tree、/payroll/batches、/payroll/slips |
| 动作处理 | restoreFormDraft @61 [method-declaration-candidate] 提示 ['restore']；Future<void> restoreFormDraft(Map<String, dynamic> data) async {<br>addPostFrameCallback @83 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) => initializeFormDraft());<br>_submitDraft @398 [action-like-invocation] 提示 ['submit']；await _submitDraft();<br>createPayrollBatch @408 [action-like-invocation] 提示 ['create']；() => createPayrollBatch(<br>PayrollBatchCreateInput @410 [action-like-invocation] 提示 ['create']；PayrollBatchCreateInput(<br>saveFormDraftNow @431 [action-like-invocation] 提示 ['save']；await saveFormDraftNow();<br>_submitDraft @444 [method-declaration-candidate] 提示 ['submit']；Future<void> _submitDraft() async {<br>submitPayrollBatch @452 [action-like-invocation] 提示 ['submit']；await submitPayrollBatch(ref, batch.id);<br>completeFormDraft @453 [action-like-invocation] 提示 ['complete']；await completeFormDraft();<br>copyWith @594 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith( |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/org/department/DepartmentController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/payroll/PayrollController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/core/formatters/exact_number_text.dart` (core)；`lib/components/inputs/uten_field_hint_icon.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_info_row.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_busy_overlay.dart` (sharedComponents)；`lib/components/inputs/uten_dropdown_field.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_ancestor_row_window.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_form_grid.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/router/nav_helpers.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/core/utils/china_datetime.dart` (core)；`lib/shared/drafts/form_draft_mixin.dart` (sharedComponents)；`lib/shared/drafts/form_draft_catalog.dart` (sharedComponents)；`lib/features/payroll/repositories/payroll_repository.dart` (repositories)；`lib/features/payroll/models/payroll_batch.dart` (models)；`lib/features/payroll/models/payroll_slip.dart` (models)；`lib/features/payroll/providers/payroll_providers.dart` (providers)。

## W7-BIZ-089 · lib/features/payroll/pages/payroll_review_page.dart

模块 `payroll`；622 行；SHA256 `d6f88f49f505d3aa154b1e3f9885bea8af15f0e86e9ad58a6f3d6b28d74ec21c`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | PayrollReviewPage @42 (page-class)<br>_PayrollReviewPageState @49 (state-class)<br>_BatchChip @369 (supporting-class)<br>_BatchDetail @427 (supporting-class)<br>_BatchDetailState @436 (state-class) |
| 真实路由绑定 | /payroll/review；router @683；builder ['PayrollReviewPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | payroll:generate @176；定义 lib/shared/auth/permissions.dart:51<br>payroll:review @190；定义 lib/shared/auth/permissions.dart:52<br>payroll:publish @212；定义 lib/shared/auth/permissions.dart:53 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | showUtenReviewerConfirmDialog @235 [action-like-invocation] 提示 ['confirm']；final confirmed = await showUtenReviewerConfirmDialog(<br>_askRejectReason @272 [action-like-invocation] 提示 ['reject']；reason = await _askRejectReason();<br>submitPayrollBatch @280 [action-like-invocation] 提示 ['submit']；await submitPayrollBatch(ref, batch.id);<br>approvePayrollBatch @282 [action-like-invocation] 提示 ['approve']；await approvePayrollBatch(ref, batch.id);<br>rejectPayrollBatch @284 [action-like-invocation] 提示 ['reject']；await rejectPayrollBatch(ref, batch.id, reason!);<br>_askRejectReason @304 [method-declaration-candidate] 提示 ['reject']；Future<String?> _askRejectReason() async {<br>copyWith @407 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleSmall?.copyWith(<br>copyWith @415 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.labelSmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/core/formatters/exact_number_text.dart` (core)；`lib/components/feedback/uten_dialog.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/data_display/uten_detail_summary_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_reviewer_responsibility_notice.dart` (sharedComponents)；`lib/components/inputs/uten_field_message.dart` (sharedComponents)；`lib/components/inputs/uten_input_decoration.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/shared/formatters/money_display.dart` (sharedComponents)；`lib/components/layout/uten_collapsing_header_scroll_view.dart` (sharedComponents)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/payroll/models/payroll_batch.dart` (models)；`lib/features/payroll/models/payroll_slip.dart` (models)；`lib/features/payroll/providers/payroll_providers.dart` (providers)。

## W7-BIZ-090 · lib/features/payroll/pages/payroll_slip_detail_page.dart

模块 `payroll`；358 行；SHA256 `bda72cc3cfbe3c14cdccdea3ed44462e3d1db6851652d68c22b755e25761fc67`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | PayrollSlipDetailPage @33 (page-class)<br>_PayrollSlipDetailPageState @43 (state-class)<br>_LoadingView @140 (supporting-class)<br>_DetailContent @154 (supporting-class) |
| 真实路由绑定 | /payroll/slip/:id；router @672；builder ['PayrollSlipDetailPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | _download @58 [method-declaration-candidate] 提示 ['download']；Future<void> _download(PayrollSlip slip) async {<br>downloadPayrollSlip @67 [action-like-invocation] 提示 ['download']；action: (progress) => downloadPayrollSlip(<br>saveBytes @78 [action-like-invocation] 提示 ['save']；final savedPath = await saveBytes(<br>addPostFrameCallback @114 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) => _markViewed());<br>_download @130 [action-like-invocation] 提示 ['download']；onAction: () => _download(slip),<br>copyWith @282 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/core/formatters/exact_number_text.dart` (core)；`lib/core/utils/china_datetime.dart` (core)；`lib/components/buttons/click_guard.dart` (sharedComponents)；`lib/components/feedback/uten_progress_dialog.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_detail_summary_card.dart` (sharedComponents)；`lib/components/data_display/uten_info_row.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/feedback/uten_skeleton.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/io/file_saver.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/features/payroll/models/payroll_download.dart` (models)；`lib/features/payroll/models/payroll_item.dart` (models)；`lib/features/payroll/models/payroll_slip.dart` (models)；`lib/features/payroll/providers/payroll_providers.dart` (providers)。

## W7-BIZ-091 · lib/features/payroll/pages/payroll_slip_list_page.dart

模块 `payroll`；248 行；SHA256 `1f1d2471411be573ee28862ea1e50045a32d42de63d2f7e291e31095901454e0`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | PayrollSlipListPage @38 (page-class)<br>_PayrollSlipListPageState @46 (state-class) |
| 真实路由绑定 | /payroll/slip；router @667；builder ['PayrollSlipListPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | 未静态确认；不能当作不存在 |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/core/formatters/exact_number_text.dart` (core)；`lib/core/utils/china_datetime.dart` (core)；`lib/shared/models/retained_async_page.dart` (models)；`lib/shared/models/paged_result.dart` (models)；`lib/components/data_display/uten_status_cell_color.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/shared/formatters/money_display.dart` (sharedComponents)；`lib/features/basic_data/models/master_facet.dart` (models)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/payroll/models/payroll_slip.dart` (models)；`lib/features/payroll/providers/payroll_providers.dart` (providers)。
