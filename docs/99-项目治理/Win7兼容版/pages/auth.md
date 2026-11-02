# auth：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-015 · lib/features/auth/pages/change_password_page.dart

模块 `auth`；213 行；SHA256 `b74acba7d29a56fdebf721f138f1102e59535785df56907422c443c12f9296e9`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | ChangePasswordPage @22 (page-class)<br>_ChangePasswordPageState @35 (state-class) |
| 真实路由绑定 | /change-password；router @512；builder ['ChangePasswordPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | _submit @51 [method-declaration-candidate] 提示 ['submit']；Future<void> _submit() async {<br>logout @79 [action-like-invocation] 提示 ['logout']；await ref.read(sessionProvider.notifier).logout();<br>logout @89 [action-like-invocation] 提示 ['logout']；await ref.read(sessionProvider.notifier).logout();<br>copyWith @149 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleMedium?.copyWith(<br>_submit @178 [action-like-invocation] 提示 ['submit']；onFieldSubmitted: (_) => _submit(),<br>copyWith @186 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/security/input_validators.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/action_feedback.dart` (core)；`lib/shared/providers/session_provider.dart` (sharedComponents)。

## W7-BIZ-016 · lib/features/auth/pages/login_page.dart

模块 `auth`；462 行；SHA256 `1211b2af1259163e904f974507674205a651f236cab5632cb438e656078785c3`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | LoginPage @42 (page-class)<br>_LoginPageState @51 (state-class) |
| 真实路由绑定 | /login；router @505；builder ['LoginPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/shared/repositories/account_history_store.dart；接口： |
| 动作处理 | LoginPage @43 [action-like-invocation] 提示 ['login']；const LoginPage({super.key, this.returnTo});<br>_LoginPageState @48 [action-like-invocation] 提示 ['login']；ConsumerState<LoginPage> createState() => _LoginPageState();<br>_updateSafety @65 [method-declaration-candidate] 提示 ['update']；WebUpdateSafetyState _updateSafety() => WebUpdateSafetyState(<br>WebUpdateSafetyState @65 [action-like-invocation] 提示 ['update']；WebUpdateSafetyState _updateSafety() => WebUpdateSafetyState(<br>removeListener @98 [action-like-invocation] 提示 ['remove']；_passwordController.removeListener(webUpdateSafety.changed);<br>_handleLogin @112 [method-declaration-candidate] 提示 ['login']；Future<void> _handleLogin() async {<br>isCurrentLogin @126 [method-declaration-candidate] 提示 ['login']；bool isCurrentLogin() =><br>login @153 [action-like-invocation] 提示 ['login']；await session.login(<br>isCurrentLogin @158 [action-like-invocation] 提示 ['login']；if (!isCurrentLogin()) return;<br>isCurrentLogin @164 [action-like-invocation] 提示 ['login']；if (mounted && isCurrentLogin()) {<br>isCurrentLogin @174 [action-like-invocation] 提示 ['login']；if (isCurrentLogin()) {<br>_loginFailureText @176 [action-like-invocation] 提示 ['login']；_errorMessage = _loginFailureText(context, e);<br>isCurrentLogin @180 [action-like-invocation] 提示 ['login']；if (isCurrentLogin()) {<br>_loginFailureText @182 [action-like-invocation] 提示 ['login']；_errorMessage = _loginFailureText(context, null);<br>DesktopLoginLayout @204 [action-like-invocation] 提示 ['login']；child: DesktopLoginLayout(<br>copyWith @310 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>_handleLogin @346 [action-like-invocation] 提示 ['login']；onFieldSubmitted: (_) => _handleLogin(),<br>copyWith @373 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>loginFooter @400 [action-like-invocation] 提示 ['login']；? l10n.loginFooter(DateTime.now().year)<br>copyWith @402 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @418 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>_loginFailureText @429 [method-declaration-candidate] 提示 ['login']；String _loginFailureText(BuildContext context, ApiException? error) { |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/brand/uten_brand_mascot.dart` (sharedComponents)；`lib/components/brand/uten_wordmark_logo.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/network/login_server_preparation.dart` (core)；`lib/core/network/server_config.dart` (core)；`lib/core/network/server_selection.dart` (core)；`lib/core/platform/desktop_window.dart` (core)；`lib/shared/platform_branding/platform_branding_provider.dart` (sharedComponents)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_anim.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/web_update/web_update_safety.dart` (core)；`lib/shared/drafts/form_draft_navigation.dart` (sharedComponents)；`lib/shared/providers/session_provider.dart` (sharedComponents)；`lib/shared/providers/shared_providers.dart` (sharedComponents)；`lib/shared/repositories/account_history_store.dart` (repositories)；`lib/features/auth/widgets/account_field.dart` (featureWidgets)；`lib/features/auth/widgets/desktop_login_layout.dart` (featureWidgets)；`lib/core/l10n/disaster_recovery_text.dart` (core)。
