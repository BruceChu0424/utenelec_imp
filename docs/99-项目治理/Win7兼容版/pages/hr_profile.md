# hr_profile：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-079 · lib/features/hr_profile/pages/hr_profile_change_detail_page.dart

模块 `hr_profile`；422 行；SHA256 `ed719067fcb1b185f792ac08139f7208288ae0600faa562c8b49d6e6b9ab2ab0`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | HrProfileChangeDetailPage @37 (page-class)<br>_HrProfileChangeDetailPageState @46 (state-class) |
| 真实路由绑定 | /hr/profile-changes/:id；router @2282；builder ['HrProfileChangeDetailPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/profile/repositories/profile_change_repository.dart；接口：/hr/profile-changes、/hr/profile-changes/facets、/hr/profile-changes/{id}、/hr/profile-changes/{id}/review、/profile/me/changes |
| 动作处理 | addPostFrameCallback @65 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) {<br>addPostFrameCallback @81 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) {<br>removeRoute @82 [action-like-invocation] 提示 ['remove']；if (route?.isActive == true) route!.navigator?.removeRoute(route);<br>addPostFrameCallback @91 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) {<br>removeRoute @92 [action-like-invocation] 提示 ['remove']；if (route?.isActive == true) route!.navigator?.removeRoute(route);<br>_onReject @168 [action-like-invocation] 提示 ['reject']；: () => _onReject(context, l10n),<br>_onApprove @176 [action-like-invocation] 提示 ['approve']；: () => _onApprove(context, l10n),<br>copyWith @271 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleSmall?.copyWith(<br>_onApprove @293 [method-declaration-candidate] 提示 ['approve']；Future<void> _onApprove(BuildContext context, AppLocalizations l10n) async {<br>_onReject @363 [method-declaration-candidate] 提示 ['reject']；Future<void> _onReject(BuildContext context, AppLocalizations l10n) async {<br>UtenBatchRejectDialog @374 [action-like-invocation] 提示 ['reject']；UtenBatchRejectDialog( |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/org/employee/MyProfileController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/org/employee/MyVehiclePhoneController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/feedback/uten_dialog.dart` (sharedComponents)；`lib/core/utils/china_datetime.dart` (core)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_detail_summary_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/data_display/uten_user_avatar.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/feedback/uten_batch_reject_dialog.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/network/api_client.dart` (core)；`lib/core/network/authenticated_request_scope.dart` (core)；`lib/core/network/server_config.dart` (core)；`lib/core/router/nav_helpers.dart` (core)；`lib/core/router/route_access_policy.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/features/profile/models/profile_change_request.dart` (models)；`lib/features/profile/providers/profile_change_providers.dart` (providers)；`lib/features/profile/repositories/profile_change_repository.dart` (repositories)；`lib/features/profile/widgets/profile_change_diff_row.dart` (featureWidgets)；`lib/shared/badges/badge_registry.dart` (sharedComponents)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/shared/providers/authenticated_scope_provider.dart` (sharedComponents)。

## W7-BIZ-080 · lib/features/hr_profile/pages/hr_profile_changes_list_page.dart

模块 `hr_profile`；514 行；SHA256 `016e7567beffdc63eb482c4a72514604efea5bb8b3cd263ddd88af886da2afe3`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | HrProfileChangesListPage @58 (page-class)<br>_HrProfileChangesListPageState @66 (state-class) |
| 真实路由绑定 | /hr/profile-changes；router @2277；builder ['HrProfileChangesListPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/profile/repositories/profile_change_repository.dart；接口：/hr/profile-changes、/hr/profile-changes/facets、/hr/profile-changes/{id}、/hr/profile-changes/{id}/review、/profile/me/changes |
| 动作处理 | addPostFrameCallback @97 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) {<br>_batchApprove @173 [method-declaration-candidate] 提示 ['approve']；Future<void> _batchApprove(Set<String> ids) async {<br>showUtenReviewerConfirmDialog @176 [action-like-invocation] 提示 ['confirm']；final confirmed = await showUtenReviewerConfirmDialog(<br>_batchReject @191 [method-declaration-candidate] 提示 ['reject']；Future<void> _batchReject(Set<String> ids) async {<br>showUtenBatchRejectDialog @193 [action-like-invocation] 提示 ['reject']；final reason = await showUtenBatchRejectDialog(<br>_batchApprove @258 [action-like-invocation] 提示 ['approve']；? () => _batchApprove(Set<String>.of(selectedIds))<br>_batchReject @269 [action-like-invocation] 提示 ['reject']；? () => _batchReject(Set<String>.of(selectedIds)) |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/org/employee/MyProfileController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/org/employee/MyVehiclePhoneController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/core/utils/china_datetime.dart` (core)；`lib/shared/models/retained_async_page.dart` (models)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/data_display/uten_status_cell_color.dart` (sharedComponents)；`lib/components/feedback/uten_batch_reject_dialog.dart` (sharedComponents)；`lib/components/feedback/uten_reviewer_responsibility_notice.dart` (sharedComponents)；`lib/components/feedback/uten_segment_badge_label.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_collapsing_header_scroll_view.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/router/nav_helpers.dart` (core)；`lib/core/router/page_resume_provider.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/features/basic_data/models/master_facet.dart` (models)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/profile/field_policy.dart` (other)；`lib/features/profile/models/profile_change_request.dart` (models)；`lib/features/profile/providers/profile_change_providers.dart` (providers)；`lib/features/profile/repositories/profile_change_repository.dart` (repositories)；`lib/features/profile/widgets/profile_change_diff_row.dart` (featureWidgets)；`lib/shared/badges/badge_registry.dart` (sharedComponents)。
