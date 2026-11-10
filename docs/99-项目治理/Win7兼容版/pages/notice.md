# notice：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-084 · lib/features/notice/pages/notice_detail_page.dart

模块 `notice`；497 行；SHA256 `b07fd25a042bae14e70b63a19641fcc94895c1cf443d21478e30c7e4133d1da3`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | NoticeDetailPage @30 (page-class)<br>_Content @92 (supporting-class)<br>_CompleteTodoButton @458 (supporting-class)<br>_CompleteTodoButtonState @468 (state-class) |
| 真实路由绑定 | /notice/:id；router @862；builder ['NoticeDetailPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | copyWith @173 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.headlineSmall?.copyWith(<br>copyWith @201 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @221 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @245 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @266 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @284 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),<br>_CompleteTodoButton @312 [action-like-invocation] 提示 ['complete']；_CompleteTodoButton(noticeId: notice.id),<br>copyWith @329 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @358 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @422 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>_CompleteTodoButton @459 [action-like-invocation] 提示 ['complete']；const _CompleteTodoButton({required this.noticeId});<br>_CompleteTodoButtonState @465 [action-like-invocation] 提示 ['complete']；_CompleteTodoButtonState();<br>_complete @471 [method-declaration-candidate] 提示 ['complete']；Future<void> _complete() async {<br>completeNoticeTodo @475 [action-like-invocation] 提示 ['complete']；await completeNoticeTodo(ref, widget.noticeId); |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/core/utils/china_datetime.dart` (core)；`lib/components/buttons/uten_back_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/feedback/uten_dialog.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/core/ui/capsule_nav_metrics.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/features/dashboard/providers/dashboard_overview_provider.dart` (providers)；`lib/features/notice/models/notice.dart` (models)；`lib/features/notice/providers/notice_providers.dart` (providers)；`lib/features/notice/widgets/celebration_subjects.dart` (featureWidgets)；`lib/features/notice/widgets/notice_blessing.dart` (featureWidgets)。

## W7-BIZ-085 · lib/features/notice/pages/notice_list_page.dart

模块 `notice`；438 行；SHA256 `bf9181996e8ac94ce7d2661518f1430e8d9a0dcc317346ee2827bcac5c5f4278`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | NoticeListPage @43 (page-class)<br>_NoticeListPageState @54 (state-class) |
| 真实路由绑定 | /notice；router @830；builder ['NoticeListPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | addPostFrameCallback @67 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) {<br>remove @103 [action-like-invocation] 提示 ['remove']；if (!_selected.add(id)) _selected.remove(id);<br>_deleteSelected @108 [method-declaration-candidate] 提示 ['delete']；Future<void> _deleteSelected() async {<br>deleteNotices @141 [action-like-invocation] 提示 ['delete']；action: (_) => deleteNotices(ref, _selected.toList()),<br>removeAll @360 [action-like-invocation] 提示 ['remove']；? _selected.removeAll(group.ids)<br>_deleteSelected @429 [callback-reference] 提示 ['delete']；onAction |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/feedback/uten_dialog.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/data_display/uten_selection_summary_pill.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/feedback/uten_skeleton.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/layout/uten_paged_grid.dart` (sharedComponents)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/core/ui/capsule_nav_metrics.dart` (core)；`lib/core/ui/human_error_message.dart` (core)；`lib/components/buttons/click_guard.dart` (sharedComponents)；`lib/features/notice/models/notice.dart` (models)；`lib/features/notice/models/notice_group.dart` (models)；`lib/features/notice/providers/notice_providers.dart` (providers)；`lib/features/notice/widgets/notice_card.dart` (featureWidgets)；`lib/components/feedback/uten_progress_dialog.dart` (sharedComponents)；`lib/features/notice/widgets/notice_action_busy.dart` (featureWidgets)；`lib/features/notice/widgets/notice_detail_dialog.dart` (featureWidgets)；`lib/features/notice/widgets/notice_group_dialog.dart` (featureWidgets)；`lib/features/notice/widgets/notice_popup_settings_dialog.dart` (featureWidgets)。

## W7-BIZ-086 · lib/features/notice/pages/notice_publish_page.dart

模块 `notice`；951 行；SHA256 `8375e46ee7503cd261c1219310bc05b57dd73a94615e24bbffc7c4f7885f7506`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | NoticePublishPage @46 (page-class)<br>_NoticePublishPageState @59 (state-class)<br>_AudienceHint @888 (supporting-class)<br>_CelebrationTemplateCurator @906 (supporting-class) |
| 真实路由绑定 | /notice/publish；router @842；builder ['NoticePublishPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | restoreFormDraft @104 [method-declaration-candidate] 提示 ['restore']；Future<void> restoreFormDraft(Map<String, dynamic> data) async {<br>restoreDraftDepartments @115 [action-like-invocation] 提示 ['restore']；_departments = restoreDraftDepartments(data['departments']);<br>restoreDraftEmployees @117 [action-like-invocation] 提示 ['restore']；restoreDraftEmployees(employees, data['employees']);<br>restoreDraftEmployees @120 [action-like-invocation] 提示 ['restore']；restoreDraftEmployees(subject, data['celebrationSubject']);<br>startFormDraftIdentityGuard @171 [action-like-invocation] 提示 ['start']；startFormDraftIdentityGuard();<br>addPostFrameCallback @179 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) async {<br>_confirmPublish @388 [action-like-invocation] 提示 ['confirm']；final confirmed = await _confirmPublish(l10n, preview);<br>saveFormDraftNow @391 [action-like-invocation] 提示 ['save']；await saveFormDraftNow();<br>completeFormDraft @420 [action-like-invocation] 提示 ['complete']；await completeFormDraft();<br>_confirmPublish @444 [method-declaration-candidate] 提示 ['confirm']；Future<bool?> _confirmPublish(<br>noticePublishConfirmAudience @450 [action-like-invocation] 提示 ['confirm']；: l10n.noticePublishConfirmAudience(<br>copyWith @612 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @703 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @930 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.labelMedium?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/inputs/uten_field_hint_icon.dart` (sharedComponents)；`lib/components/feedback/uten_dialog.dart` (sharedComponents)；`lib/components/inputs/uten_filter_chip.dart` (sharedComponents)；`lib/components/layout/uten_segment_row.dart` (sharedComponents)；`lib/shared/drafts/form_draft_mixin.dart` (sharedComponents)；`lib/shared/drafts/form_draft_catalog.dart` (sharedComponents)；`lib/shared/drafts/form_draft_values.dart` (sharedComponents)；`lib/shared/drafts/people_form_draft_values.dart` (sharedComponents)；`lib/core/router/nav_helpers.dart` (core)；`lib/components/buttons/click_guard.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/inputs/required_field_decoration.dart` (sharedComponents)；`lib/components/inputs/uten_date_field.dart` (sharedComponents)；`lib/components/inputs/uten_employee_multi_picker.dart` (sharedComponents)；`lib/components/inputs/uten_employee_picker.dart` (sharedComponents)；`lib/components/inputs/uten_field_message.dart` (sharedComponents)；`lib/components/inputs/uten_input_decoration.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/shared/widgets/uten_department_picker.dart` (sharedComponents)；`lib/features/hr_task/providers/hr_task_summary_provider.dart` (providers)；`lib/features/notice/models/notice.dart` (models)；`lib/features/notice/models/notice_audience.dart` (models)；`lib/features/notice/providers/notice_providers.dart` (providers)；`lib/features/notice/widgets/notice_type_picker.dart` (featureWidgets)；`lib/shared/badges/badge_registry.dart` (sharedComponents)。
