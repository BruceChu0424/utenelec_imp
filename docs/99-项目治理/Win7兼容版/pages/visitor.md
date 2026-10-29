# visitor：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-165 · lib/features/visitor/pages/visitor_application_detail_page.dart

模块 `visitor`；256 行；SHA256 `d54763aeda345a1c2132301fe3cef5365c7fceafd4c594c457cc2fc795e871e7`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | VisitorApplicationDetailPage @26 (page-class)<br>_StatusCard @142 (supporting-class)<br>_StepRow @201 (supporting-class) |
| 真实路由绑定 | /visitor/apply/:id；router @528；builder ['VisitorApplicationDetailPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | copyWith @102 [action-like-invocation] 提示 ['copy']；?.copyWith(<br>copyWith @221 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>copyWith @228 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @234 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 访客门户前端已被全局redirect下线；保留源码不等于本次需要恢复该门户，需确认范围。<br>存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_refresh_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/data_display/uten_detail_summary_card.dart` (sharedComponents)；`lib/components/data_display/uten_status_badge.dart` (sharedComponents)；`lib/components/feedback/uten_empty.dart` (sharedComponents)；`lib/components/feedback/uten_skeleton.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/features/visitor/models/visitor_application.dart` (models)；`lib/features/visitor/providers/visitor_providers.dart` (providers)；`lib/features/visitor/widgets/visitor_qr_widget.dart` (featureWidgets)；`lib/features/visitor/widgets/visitor_status_ui.dart` (featureWidgets)。

## W7-BIZ-166 · lib/features/visitor/pages/visitor_apply_page.dart

模块 `visitor`；442 行；SHA256 `ffba8d272cfc68a9eb801a5991b197e9eb5a9bd5c86589df3ce25486dc6a1b12`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | VisitorApplyPage @32 (page-class)<br>_VisitorApplyPageState @39 (state-class) |
| 真实路由绑定 | /visitor/apply；router @523；builder ['VisitorApplyPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/visitor/repositories/visitor_repository.dart；接口：/visitor/applications、/visitor/applications/mine、/visitor/applications/{id}、/visitor/auth/login、/visitor/auth/logout、/visitor/auth/send-code、/visitor/directory/employees、/visitor/me |
| 动作处理 | _submit @170 [method-declaration-candidate] 提示 ['submit']；Future<void> _submit() async {<br>submit @207 [action-like-invocation] 提示 ['submit']；final app = await repo.submit({<br>copyWith @406 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith( |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/visitor/VisitorAccountController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/visitor/VisitorAuthController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/visitor/VisitorController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/visitor/VisitorDirectoryController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 访客门户前端已被全局redirect下线；保留源码不等于本次需要恢复该门户，需确认范围。<br>存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/feedback/uten_busy_overlay.dart` (sharedComponents)；`lib/components/inputs/uten_employee_picker.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/components/inputs/required_field_decoration.dart` (sharedComponents)；`lib/components/inputs/uten_input_decoration.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_section_header.dart` (sharedComponents)；`lib/core/input/china_input_formatters.dart` (core)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/responsive/scale.dart` (core)；`lib/core/utils/china_datetime.dart` (core)；`lib/core/utils/id_card_utils.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/features/visitor/models/visitor_application.dart` (models)；`lib/features/visitor/repositories/visitor_repository.dart` (repositories)。

## W7-BIZ-167 · lib/features/visitor/pages/visitor_home_page.dart

模块 `visitor`；256 行；SHA256 `4421aa61ed8c5f3609c0983098d8be6841c535abe7854f2dda5c9bbf8468a623`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | VisitorHomePage @37 (page-class)<br>_VisitorHomePageState @44 (state-class) |
| 真实路由绑定 | /visitor/home；router @513；builder ['VisitorHomePage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | _logout @59 [method-declaration-candidate] 提示 ['logout']；Future<void> _logout() async {<br>logout @63 [action-like-invocation] 提示 ['logout']；await ref.read(visitorSessionProvider.notifier).logout(); |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 访客门户前端已被全局redirect下线；保留源码不等于本次需要恢复该门户，需确认范围。<br>存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/shared/models/retained_async_page.dart` (models)；`lib/shared/models/paged_result.dart` (models)；`lib/components/layout/uten_floating_action_group.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/buttons/uten_app_bar_action_button.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/layout/uten_filter_toolbar.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/features/basic_data/widgets/master_data_table_view.dart` (featureWidgets)；`lib/features/visitor/models/visitor_application.dart` (models)；`lib/features/visitor/providers/visitor_providers.dart` (providers)；`lib/features/visitor/providers/visitor_session_provider.dart` (providers)；`lib/features/visitor/widgets/visitor_status_ui.dart` (featureWidgets)；`lib/components/data_display/uten_status_cell_color.dart` (sharedComponents)。

## W7-BIZ-168 · lib/features/visitor/pages/visitor_login_page.dart

模块 `visitor`；323 行；SHA256 `7c1f03b31679833406b6b568b7d765918aeb3fb7a20ec8bda65be721e6e311f8`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | VisitorLoginPage @31 (page-class)<br>_VisitorLoginPageState @40 (state-class) |
| 真实路由绑定 | /visitor/login；router @506；builder ['VisitorLoginPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | VisitorLoginPage @32 [action-like-invocation] 提示 ['login']；const VisitorLoginPage({super.key, this.returnTo});<br>_VisitorLoginPageState @37 [action-like-invocation] 提示 ['login']；ConsumerState<VisitorLoginPage> createState() => _VisitorLoginPageState();<br>cancel @52 [action-like-invocation] 提示 ['cancel']；_timer?.cancel();<br>_sendCode @60 [method-declaration-candidate] 提示 ['send']；Future<void> _sendCode() async {<br>sendCode @74 [action-like-invocation] 提示 ['send']；.sendCode(phone);<br>_startCountdown @80 [action-like-invocation] 提示 ['start']；_startCountdown();<br>_startCountdown @90 [method-declaration-candidate] 提示 ['start']；void _startCountdown() {<br>cancel @91 [action-like-invocation] 提示 ['cancel']；_timer?.cancel();<br>cancel @94 [action-like-invocation] 提示 ['cancel']；if (_countdown <= 0) t.cancel();<br>_login @98 [method-declaration-candidate] 提示 ['login']；Future<void> _login() async {<br>login @115 [action-like-invocation] 提示 ['login']；await ref.read(visitorSessionProvider.notifier).login(phone, code);<br>copyWith @201 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleLarge?.copyWith(<br>copyWith @210 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodyMedium?.copyWith(<br>_login @239 [action-like-invocation] 提示 ['login']；onFieldSubmitted: (_) => _login(),<br>copyWith @272 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @301 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 访客门户前端已被全局redirect下线；保留源码不等于本次需要恢复该门户，需确认范围。<br>存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/buttons/uten_back_button.dart` (sharedComponents)；`lib/components/brand/uten_wordmark_logo.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/input/china_input_formatters.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/security/input_validators.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/theme/brand_theme.dart` (core)；`lib/shared/platform_branding/platform_branding_provider.dart` (sharedComponents)；`lib/features/visitor/providers/visitor_session_provider.dart` (providers)。

## W7-BIZ-169 · lib/features/visitor/pages/visitor_settings_page.dart

模块 `visitor`；152 行；SHA256 `77847e4f36c8131590669a698ac35b08a8ac1b45fa61e5ae3321cf0573a3e6f8`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | VisitorSettingsPage @35 (page-class) |
| 真实路由绑定 | /visitor/settings；router @518；builder ['VisitorSettingsPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | _confirmLogout @111 [action-like-invocation] 提示 ['confirm', 'logout']；onTap: () => _confirmLogout(context, ref),<br>copyWith @122 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>_confirmLogout @134 [method-declaration-candidate] 提示 ['confirm', 'logout']；Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {<br>logout @146 [action-like-invocation] 提示 ['logout']；await ref.read(visitorSessionProvider.notifier).logout(); |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 访客门户前端已被全局redirect下线；保留源码不等于本次需要恢复该门户，需确认范围。<br>存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/components/settings/uten_font_scaler.dart` (sharedComponents)；`lib/components/settings/uten_locale_switcher.dart` (sharedComponents)；`lib/components/settings/uten_performance_switcher.dart` (sharedComponents)；`lib/components/settings/uten_theme_switcher.dart` (sharedComponents)；`lib/shared/platform_branding/platform_branding_provider.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/uten_notify.dart` (core)；`lib/features/settings/widgets/settings_section.dart` (featureWidgets)；`lib/features/settings/widgets/app_version_tile.dart` (featureWidgets)；`lib/features/visitor/providers/visitor_session_provider.dart` (providers)。
