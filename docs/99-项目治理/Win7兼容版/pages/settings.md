# settings：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-146 · lib/features/settings/pages/device_audit_receipts_page.dart

模块 `settings`；452 行；SHA256 `58766bd7ecca8ff686c6877ecc4772e988bb473d72bc81fde8d86ebf3055cfc2`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | DeviceAuditReceiptsPage @26 (page-class)<br>_DeviceAuditReceiptsPageState @41 (state-class)<br>_IntroCard @189 (supporting-class)<br>_DeviceProfileCard @201 (supporting-class)<br>_SearchCard @239 (supporting-class)<br>_ReceiptResultCard @301 (supporting-class)<br>_Fact @390 (supporting-class)<br>_CopyFact @417 (supporting-class) |
| 真实路由绑定 | /settings/device-receipts；router @591；builder ['DeviceAuditReceiptsPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | ApiEndpoints.adminAuditLocalReceiptVerification @148 → /admin/audit-logs/local-receipt-verifications/{operationId} |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | DeviceAuditReceiptsPage @27 [action-like-invocation] 提示 ['audit']；const DeviceAuditReceiptsPage({<br>_DeviceAuditReceiptsPageState @38 [action-like-invocation] 提示 ['audit']；_DeviceAuditReceiptsPageState();<br>addPostFrameCallback @55 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) => _search());<br>_copyReceipt @113 [action-like-invocation] 提示 ['copy']；onCopy: () => _copyReceipt(receipt),<br>post @148 [action-like-invocation] 提示 ['post']；.post(ApiEndpoints.adminAuditLocalReceiptVerification(operationId));<br>adminAuditLocalReceiptVerification @148 [action-like-invocation] 提示 ['audit']；.post(ApiEndpoints.adminAuditLocalReceiptVerification(operationId));<br>_copyReceipt @179 [method-declaration-candidate] 提示 ['copy']；Future<void> _copyReceipt(LocalAuditReceipt receipt) async {<br>_CopyFact @230 [action-like-invocation] 提示 ['copy']；_CopyFact(label: '本机安装标识', value: profile.installationId),<br>copyWith @262 [action-like-invocation] 提示 ['copy']；).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),<br>_CopyFact @339 [action-like-invocation] 提示 ['copy']；_CopyFact(label: '本地操作 ID', value: receipt.clientEventId),<br>_CopyFact @340 [action-like-invocation] 提示 ['copy']；_CopyFact(label: '本机安装标识', value: receipt.installationId),<br>copyWith @405 [action-like-invocation] 提示 ['copy']；style: Theme.of(context).textTheme.labelSmall?.copyWith(<br>_CopyFact @418 [action-like-invocation] 提示 ['copy']；const _CopyFact({required this.label, required this.value});<br>onCopy @379 [callback-reference] 提示 ['copy']；onPressed |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/audit/AuditController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/admin/AdminPermissionController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/admin/AdminUserController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/admin/PermissionConfigurationTransferController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/admin/PermissionTemplateController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/utils/china_datetime.dart` (core)；`lib/components/buttons/uten_back_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/inputs/uten_field_message.dart` (sharedComponents)；`lib/components/inputs/uten_input_decoration.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/core/audit/device_audit_store.dart` (core)；`lib/core/network/api_client.dart` (core)；`lib/core/network/api_endpoints.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/core/ui/capsule_nav_metrics.dart` (core)。

## W7-BIZ-147 · lib/features/settings/pages/settings_page.dart

模块 `settings`；352 行；SHA256 `def88b0f98b2a48a8f258571437361348c47da0c27319453b81f62e75fae14be`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | SettingsPage @42 (page-class)<br>_LogoutTile @291 (supporting-class)<br>_LogoutTileState @298 (state-class) |
| 真实路由绑定 | /settings；router @586；builder ['SettingsPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | audit_log:view @52；定义 lib/shared/auth/permissions.dart:45 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | copyWith @84 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleSmall?.copyWith(<br>copyWith @103 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleSmall?.copyWith(<br>copyWith @113 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>_LogoutTile @256 [action-like-invocation] 提示 ['logout']；const _LogoutTile(),<br>copyWith @264 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>_LogoutTile @292 [action-like-invocation] 提示 ['logout']；const _LogoutTile();<br>_LogoutTileState @295 [action-like-invocation] 提示 ['logout']；ConsumerState<_LogoutTile> createState() => _LogoutTileState();<br>_confirmLogout @301 [method-declaration-candidate] 提示 ['confirm', 'logout']；Future<void> _confirmLogout() async {<br>logout @319 [action-like-invocation] 提示 ['logout']；await ref.read(sessionProvider.notifier).logout(); |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_user_avatar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/settings/uten_font_scaler.dart` (sharedComponents)；`lib/components/settings/uten_locale_switcher.dart` (sharedComponents)；`lib/components/settings/uten_performance_switcher.dart` (sharedComponents)；`lib/components/settings/uten_theme_switcher.dart` (sharedComponents)；`lib/components/settings/uten_time_display_switcher.dart` (sharedComponents)；`lib/shared/platform_branding/platform_branding_provider.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/server_config.dart` (core)；`lib/core/network/server_selection.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/core/ui/uten_notify.dart` (core)；`lib/shared/auth/permissions.dart` (sharedComponents)；`lib/shared/providers/session_provider.dart` (sharedComponents)；`lib/shared/providers/shared_providers.dart` (sharedComponents)；`lib/features/settings/widgets/settings_section.dart` (featureWidgets)；`lib/features/settings/widgets/app_version_tile.dart` (featureWidgets)；`lib/shared/widgets/settings_about_extensions.dart` (sharedComponents)；`lib/core/l10n/remote_access_text.dart` (core)；`lib/core/l10n/disaster_recovery_text.dart` (core)。
