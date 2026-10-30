# visitor_approval：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-170 · lib/features/visitor_approval/pages/my_visitors_page.dart

模块 `visitor_approval`；489 行；SHA256 `33aa5b55beba2ce87052bcb3c44a8526cf67f8221b7bdc72acc512fe2688f44b`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | MyVisitorsPage @45 (page-class)<br>_MyVisitorsPageState @52 (state-class) |
| 真实路由绑定 | /my-visitors；router @2201；builder ['MyVisitorsPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/visitor/repositories/visitor_staff_repository.dart；接口：/security/blacklist、/security/blacklist/{id}、/security/check-in/{id}、/security/verify、/visitor-approval、/visitor-approval/as-host、/visitor-approval/facets、/visitor-approval/{id}、/visitor-approval/{id}/action、/visitor-approval/{id}/host-confirm |
| 动作处理 | _confirm @75 [method-declaration-candidate] 提示 ['confirm']；Future<void> _confirm(<br>hostConfirm @84 [action-like-invocation] 提示 ['confirm']；.hostConfirm(app.id, confirmed: confirmed);<br>_batchConfirm @154 [method-declaration-candidate] 提示 ['confirm']；Future<void> _batchConfirm(<br>hostConfirm @211 [action-like-invocation] 提示 ['confirm']；await repo.hostConfirm(id, confirmed: true);<br>_batchConfirm @254 [action-like-invocation] 提示 ['confirm']；? () => _batchConfirm(Set<String>.of(selectedIds), pageItems)<br>_confirm @354 [action-like-invocation] 提示 ['confirm']；onTap: () => _confirm(context, app, true, l10n),<br>_confirm @360 [action-like-invocation] 提示 ['confirm']；onTap: () => _confirm(context, app, false, l10n), |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/visitor/SecurityVisitorController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/visitor/VisitorApprovalController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/feedback/uten_dialog.dart` (sharedComponents)；`lib/shared/models/retained_async_page.dart` (models)；`lib/shared/models/paged_result.dart` (models)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/data_display/uten_status_cell_color.dart` (sharedComponents)；`lib/components/feedback/uten_context_menu.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/features/basic_data/models/master_facet.dart` (models)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/visitor/models/visitor_application.dart` (models)；`lib/components/feedback/uten_segment_badge_label.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/core/theme/uten_tokens.dart` (core)；`lib/features/visitor/repositories/visitor_staff_repository.dart` (repositories)；`lib/features/visitor/providers/visitor_column_queries.dart` (providers)；`lib/features/visitor/widgets/visitor_status_ui.dart` (featureWidgets)；`lib/features/visitor_approval/providers/visitor_approval_providers.dart` (providers)；`lib/features/visitor_approval/providers/visitor_pending_count_provider.dart` (providers)；`lib/shared/badges/badge_registry.dart` (sharedComponents)。

## W7-BIZ-171 · lib/features/visitor_approval/pages/visitor_approval_detail_page.dart

模块 `visitor_approval`；330 行；SHA256 `76fce2588bbec71638382998dc0ff079def768d4259fe61a3b74f3b343b05c26`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | VisitorApprovalDetailPage @29 (page-class)<br>_VisitorApprovalDetailPageState @38 (state-class) |
| 真实路由绑定 | /visitor-approval/:id；router @2194；builder ['VisitorApprovalDetailPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/visitor/repositories/visitor_staff_repository.dart；接口：/security/blacklist、/security/blacklist/{id}、/security/check-in/{id}、/security/verify、/visitor-approval、/visitor-approval/as-host、/visitor-approval/facets、/visitor-approval/{id}、/visitor-approval/{id}/action、/visitor-approval/{id}/host-confirm |
| 动作处理 | _approve @98 [method-declaration-candidate] 提示 ['approve']；Future<void> _approve() async {<br>_reject @123 [method-declaration-candidate] 提示 ['reject']；Future<void> _reject() async {<br>canApprove @311 [callback-reference] 提示 ['approve']；onPressed<br>canApprove @318 [callback-reference] 提示 ['approve']；onPressed |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/visitor/SecurityVisitorController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/visitor/VisitorApprovalController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/layout/uten_page_layout.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/data_display/uten_detail_summary_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_busy_overlay.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/feedback/uten_reviewer_responsibility_notice.dart` (sharedComponents)；`lib/components/feedback/uten_skeleton.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/feedback/uten_dialog.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/features/visitor/models/visitor_application.dart` (models)；`lib/features/visitor/repositories/visitor_staff_repository.dart` (repositories)；`lib/features/visitor/widgets/visitor_status_ui.dart` (featureWidgets)；`lib/features/visitor_approval/providers/visitor_approval_providers.dart` (providers)；`lib/shared/badges/badge_registry.dart` (sharedComponents)。

## W7-BIZ-172 · lib/features/visitor_approval/pages/visitor_approval_list_page.dart

模块 `visitor_approval`；593 行；SHA256 `d4b4ea28618689f94bad085b5afb4303d8fdc74510e73fbc5fd71a6a5b37514c`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | VisitorApprovalListPage @52 (page-class)<br>_VisitorApprovalListPageState @60 (state-class) |
| 真实路由绑定 | /visitor-approval；router @2189；builder ['VisitorApprovalListPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/visitor/repositories/visitor_staff_repository.dart；接口：/security/blacklist、/security/blacklist/{id}、/security/check-in/{id}、/security/verify、/visitor-approval、/visitor-approval/as-host、/visitor-approval/facets、/visitor-approval/{id}、/visitor-approval/{id}/action、/visitor-approval/{id}/host-confirm |
| 动作处理 | _batchApprove @156 [method-declaration-candidate] 提示 ['approve']；Future<void> _batchApprove(Set<String> ids) async {<br>showUtenReviewerConfirmDialog @160 [action-like-invocation] 提示 ['confirm']；final confirmed = await showUtenReviewerConfirmDialog(<br>visitorBatchApproveTitle @162 [action-like-invocation] 提示 ['approve']；title: l10n.visitorBatchApproveTitle(count),<br>visitorBatchApproveMessage @163 [action-like-invocation] 提示 ['approve']；message: l10n.visitorBatchApproveMessage(count),<br>visitorBatchApproveResponsibility @166 [action-like-invocation] 提示 ['approve']；responsibilityDescription: l10n.visitorBatchApproveResponsibility(count),<br>_batchReject @176 [method-declaration-candidate] 提示 ['reject']；Future<void> _batchReject(Set<String> ids) async {<br>showUtenBatchRejectDialog @179 [action-like-invocation] 提示 ['reject']；final reason = await showUtenBatchRejectDialog(<br>visitorBatchRejectTitle @184 [action-like-invocation] 提示 ['reject']；title: l10n.visitorBatchRejectTitle(ids.length),<br>visitorBatchRejectDescription @185 [action-like-invocation] 提示 ['reject']；description: l10n.visitorBatchRejectDescription(ids.length),<br>showUtenReviewerConfirmDialog @219 [action-like-invocation] 提示 ['confirm']；final confirmed = await showUtenReviewerConfirmDialog(<br>_batchApprove @301 [action-like-invocation] 提示 ['approve']；? () => _batchApprove(Set<String>.of(selectedIds))<br>visitorBatchApproveButton @303 [action-like-invocation] 提示 ['approve']；child: Text(l10n.visitorBatchApproveButton(selectedIds.length)),<br>_batchReject @322 [action-like-invocation] 提示 ['reject']；? () => _batchReject(Set<String>.of(selectedIds))<br>visitorBatchRejectButton @324 [action-like-invocation] 提示 ['reject']；child: Text(l10n.visitorBatchRejectButton(selectedIds.length)), |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/visitor/SecurityVisitorController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/visitor/VisitorApprovalController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/layout/uten_page_layout.dart` (sharedComponents)；`lib/shared/models/retained_async_page.dart` (models)；`lib/shared/models/paged_result.dart` (models)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/data_display/uten_status_cell_color.dart` (sharedComponents)；`lib/components/feedback/uten_batch_reject_dialog.dart` (sharedComponents)；`lib/components/feedback/uten_reviewer_responsibility_notice.dart` (sharedComponents)；`lib/components/feedback/uten_segment_badge_label.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/features/basic_data/models/master_facet.dart` (models)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/visitor/models/visitor_application.dart` (models)；`lib/features/visitor/repositories/visitor_staff_repository.dart` (repositories)；`lib/features/visitor/providers/visitor_column_queries.dart` (providers)；`lib/features/visitor/widgets/visitor_status_ui.dart` (featureWidgets)；`lib/features/visitor_approval/providers/visitor_approval_providers.dart` (providers)；`lib/shared/badges/badge_registry.dart` (sharedComponents)。
