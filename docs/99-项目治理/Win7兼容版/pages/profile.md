# profile：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-118 · lib/features/profile/pages/my_profile_changes_page.dart

模块 `profile`；448 行；SHA256 `96c904924313bcfd9c1ea799a3f22e773b4ab007416ca94b0810fa3d621e14c7`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | MyProfileChangesPage @44 (page-class)<br>_MyProfileChangesPageState @52 (state-class)<br>_MyBatchDetailDialog @369 (supporting-class) |
| 真实路由绑定 | /profile/me/changes；router @2500；builder ['MyProfileChangesPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/profile/repositories/profile_change_repository.dart；接口：/hr/profile-changes、/hr/profile-changes/facets、/hr/profile-changes/{id}、/hr/profile-changes/{id}/review、/profile/me/changes |
| 动作处理 | addPostFrameCallback @66 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) {<br>_cancel @130 [method-declaration-candidate] 提示 ['cancel']；Future<void> _cancel(String batchId) async {<br>cancel @133 [action-like-invocation] 提示 ['cancel']；await ref.read(profileChangeRepositoryProvider).cancel(batchId);<br>_cancel @285 [action-like-invocation] 提示 ['cancel']；onTap: () => _cancel(item.batchId), |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/org/employee/MyProfileController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/org/employee/MyVehiclePhoneController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/layout/uten_page_layout.dart` (sharedComponents)；`lib/components/feedback/uten_dialog.dart` (sharedComponents)；`lib/core/utils/china_datetime.dart` (core)；`lib/shared/models/retained_async_page.dart` (models)；`lib/components/buttons/uten_back_button.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/feedback/uten_context_menu.dart` (sharedComponents)；`lib/components/data_display/uten_status_cell_color.dart` (sharedComponents)；`lib/components/inputs/uten_multi_value_cell.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_segmented_filter.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/router/nav_helpers.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/features/basic_data/models/master_facet.dart` (models)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/profile/models/profile_change_request.dart` (models)；`lib/features/profile/providers/profile_change_providers.dart` (providers)；`lib/features/profile/repositories/profile_change_repository.dart` (repositories)；`lib/features/profile/providers/profile_column_queries.dart` (providers)；`lib/features/profile/widgets/profile_change_diff_row.dart` (featureWidgets)。

## W7-BIZ-119 · lib/features/profile/pages/profile_edit_page.dart

模块 `profile`；641 行；SHA256 `7cbebe650708b44ce4747a5c3c4b84adc7b7d13510672e3c80f7b24f4936f0bb`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | ProfileEditPage @51 (page-class)<br>_ProfileEditPageState @62 (state-class) |
| 真实路由绑定 | /profile/edit；router @2485；builder ['ProfileEditPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/profile/repositories/profile_change_repository.dart；接口：/hr/profile-changes、/hr/profile-changes/facets、/hr/profile-changes/{id}、/hr/profile-changes/{id}/review、/profile/me/changes |
| 动作处理 | ProfileEditPage @52 [action-like-invocation] 提示 ['edit']；const ProfileEditPage({super.key, this.initialField});<br>_ProfileEditPageState @59 [action-like-invocation] 提示 ['edit']；ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();<br>addPostFrameCallback @98 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) => _load());<br>remove @184 [action-like-invocation] 提示 ['remove']；_ctrls.remove(code)?.dispose();<br>remove @185 [action-like-invocation] 提示 ['remove']；_focusNodes.remove(code)?.dispose();<br>remove @186 [action-like-invocation] 提示 ['remove']；_fieldKeys.remove(code);<br>_submit @230 [method-declaration-candidate] 提示 ['submit']；Future<void> _submit() async {<br>submit @258 [action-like-invocation] 提示 ['submit']；.submit(SubmitProfileChangeRequest(changes: dirty, idemKey: idem));<br>SubmitProfileChangeRequest @258 [action-like-invocation] 提示 ['submit']；.submit(SubmitProfileChangeRequest(changes: dirty, idemKey: idem));<br>isDirectEdit @261 [action-like-invocation] 提示 ['edit']；(c) => ProfileFieldPolicy.isDirectEdit(c.fieldCode),<br>_mapSubmitError @276 [action-like-invocation] 提示 ['submit']；context.appError(_mapSubmitError(e));<br>_mapSubmitError @290 [method-declaration-candidate] 提示 ['submit']；String _mapSubmitError(ApiException e) {<br>UtenEditFloatingActions @345 [action-like-invocation] 提示 ['edit']；: UtenEditFloatingActions(<br>addPostFrameCallback @362 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) {<br>profileEditPendingConflictHint @426 [action-like-invocation] 提示 ['edit']；l10n.profileEditPendingConflictHint(count),<br>copyWith @427 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @475 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>copyWith @529 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleSmall?.copyWith(<br>_submit @350 [callback-reference] 提示 ['submit']；onSave |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/org/employee/MyProfileController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/org/employee/MyVehiclePhoneController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_back_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_busy_overlay.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/components/buttons/uten_edit_floating_actions.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/router/nav_helpers.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/security/input_validators.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/features/employee/models/employee_api_models.dart` (models)；`lib/features/profile/field_policy.dart` (other)；`lib/features/profile/models/profile_change_request.dart` (models)；`lib/features/profile/providers/profile_change_providers.dart` (providers)；`lib/features/profile/repositories/profile_change_repository.dart` (repositories)。

## W7-BIZ-120 · lib/features/profile/pages/profile_page.dart

模块 `profile`；1229 行；SHA256 `10b245b82a269a1301bdd1d263fd4000f91f98aa09771c81b48674b63229299b`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | ProfilePage @55 (page-class)<br>_ProfilePageState @62 (state-class)<br>_ProfileFieldRow @760 (supporting-class)<br>_EditFieldPencil @885 (supporting-class)<br>_PolicyBadge @914 (supporting-class)<br>_IdentityGroup @932 (supporting-class)<br>_HeroCard @944 (supporting-class)<br>_RoleChip @1075 (supporting-class)<br>_MyDepartmentShortcut @1123 (supporting-class)<br>_MyChangesShortcut @1175 (supporting-class) |
| 真实路由绑定 | /profile；router @643；builder ['ProfilePage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | copyWith @324 [action-like-invocation] 提示 ['copy']；labelStyle: theme.textTheme.titleSmall?.copyWith(<br>copyWith @783 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>copyWith @794 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>_EditFieldPencil @800 [action-like-invocation] 提示 ['edit']；: _EditFieldPencil(kind: policyKind, onTap: onEdit);<br>_EditFieldPencil @886 [action-like-invocation] 提示 ['edit']；const _EditFieldPencil({required this.kind, this.onTap});<br>copyWith @1002 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleLarge?.copyWith(<br>copyWith @1013 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @1110 [action-like-invocation] 提示 ['copy']；style: Theme.of(context).textTheme.labelSmall?.copyWith(<br>copyWith @1157 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyLarge?.copyWith(<br>copyWith @1208 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyLarge?.copyWith(<br>effectiveEdit @672 [callback-reference] 提示 ['edit']；onEdit<br>onEdit @800 [callback-reference] 提示 ['edit']；onTap |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/layout/uten_page_layout.dart` (sharedComponents)；`lib/features/employee/widgets/employee_identity_archive_section.dart` (featureWidgets)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_info_row.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/shared/attachments/employee_avatar.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/layout/uten_collapsing_header_scroll_view.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/router/nav_helpers.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/capsule_nav_metrics.dart` (core)；`lib/shared/models/user.dart` (models)；`lib/shared/providers/session_provider.dart` (sharedComponents)；`lib/features/department/providers/my_department_providers.dart` (providers)；`lib/features/employee/models/employee_api_models.dart` (models)；`lib/features/employee/widgets/employee_status_badge.dart` (featureWidgets)；`lib/features/profile/field_policy.dart` (other)；`lib/features/profile/models/profile_change_request.dart` (models)；`lib/features/profile/providers/profile_change_providers.dart` (providers)；`lib/features/profile/widgets/my_documents_section.dart` (featureWidgets)；`lib/features/profile/widgets/my_vehicle_phone_cards.dart` (featureWidgets)。
