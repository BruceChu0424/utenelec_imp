# auth：业务页面来源

候选/静态线索必须人工核对；完整JSON证据保留在business-inventory.json。

## W7-BIZ-015 · lib/features/auth/pages/change_password_page.dart

模块 `auth`；221 行；SHA256 `f76cf7a54ca15ab41de0ffde4d27350b46101def71582bfcc71be1dc5acebd35`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | ChangePasswordPage @22 (page-class)<br>_ChangePasswordPageState @35 (state-class) |
| 真实路由绑定 | /change-password；router @484；builder ['ChangePasswordPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | 未静态确认；不能当作不存在 |
| 动作处理 | _submit @51 [method-declaration-candidate] 提示 ['submit']；Future<void> _submit() async {<br>logout @79 [action-like-invocation] 提示 ['logout']；await ref.read(sessionProvider.notifier).logout();<br>logout @89 [action-like-invocation] 提示 ['logout']；await ref.read(sessionProvider.notifier).logout();<br>copyWith @149 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.titleMedium?.copyWith(<br>copyWith @158 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>_submit @186 [action-like-invocation] 提示 ['submit']；onFieldSubmitted: (_) => _submit(),<br>copyWith @194 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith( |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/security/input_validators.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/action_feedback.dart` (core)；`lib/shared/providers/session_provider.dart` (sharedComponents)。

## W7-BIZ-016 · lib/features/auth/pages/login_page.dart

模块 `auth`；499 行；SHA256 `7e20119b8843650263c6f28fdace2a4f5a5e81fc7d711d341fca8046622178ac`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | LoginPage @42 (page-class)<br>_LoginPageState @51 (state-class) |
| 真实路由绑定 | /login；router @477；builder ['LoginPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/shared/repositories/account_history_store.dart；接口： |
| 动作处理 | LoginPage @43 [action-like-invocation] 提示 ['login']；const LoginPage({super.key, this.returnTo});<br>_LoginPageState @48 [action-like-invocation] 提示 ['login']；ConsumerState<LoginPage> createState() => _LoginPageState();<br>_handleLogin @115 [method-declaration-candidate] 提示 ['login']；Future<void> _handleLogin() async {<br>isCurrentLogin @130 [method-declaration-candidate] 提示 ['login']；bool isCurrentLogin() =><br>login @159 [action-like-invocation] 提示 ['login']；await session.login(<br>isCurrentLogin @165 [action-like-invocation] 提示 ['login']；if (!isCurrentLogin()) return;<br>isCurrentLogin @171 [action-like-invocation] 提示 ['login']；if (mounted && isCurrentLogin()) {<br>isCurrentLogin @181 [action-like-invocation] 提示 ['login']；if (isCurrentLogin()) {<br>_loginFailureText @186 [action-like-invocation] 提示 ['login']；: _loginFailureText(context, e);<br>isCurrentLogin @191 [action-like-invocation] 提示 ['login']；if (isCurrentLogin()) {<br>_loginFailureText @194 [action-like-invocation] 提示 ['login']；_errorMessage = _loginFailureText(context, null);<br>DesktopLoginLayout @216 [action-like-invocation] 提示 ['login']；child: DesktopLoginLayout(<br>copyWith @322 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>_handleLogin @358 [action-like-invocation] 提示 ['login']；onFieldSubmitted: (_) => _handleLogin(),<br>_handleLogin @384 [action-like-invocation] 提示 ['login']；onFieldSubmitted: (_) => _handleLogin(),<br>copyWith @412 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>loginFooter @439 [action-like-invocation] 提示 ['login']；? l10n.loginFooter(DateTime.now().year)<br>copyWith @441 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>copyWith @457 [action-like-invocation] 提示 ['copy']；style: theme.textTheme.bodySmall?.copyWith(<br>_loginFailureText @468 [method-declaration-candidate] 提示 ['login']；String _loginFailureText(BuildContext context, ApiException? error) { |
| 控制器候选（人工核实） | 未静态确认；不能当作不存在 |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/brand/uten_brand_mascot.dart` (sharedComponents)；`lib/components/brand/uten_wordmark_logo.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/cards/uten_card.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/core/l10n/gen/app_localizations.dart` (core)；`lib/core/network/api_exception.dart` (core)；`lib/core/network/login_server_preparation.dart` (core)；`lib/core/network/server_config.dart` (core)；`lib/core/network/server_selection.dart` (core)；`lib/core/platform/desktop_window.dart` (core)；`lib/shared/platform_branding/platform_branding_provider.dart` (sharedComponents)；`lib/core/responsive/breakpoint.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_anim.dart` (core)；`lib/core/theme/uten_colors.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/shared/providers/session_provider.dart` (sharedComponents)；`lib/shared/providers/shared_providers.dart` (sharedComponents)；`lib/shared/repositories/account_history_store.dart` (repositories)；`lib/features/auth/widgets/account_field.dart` (featureWidgets)；`lib/features/auth/widgets/desktop_login_layout.dart` (featureWidgets)；`lib/features/auth/remote_access_text.dart` (other)；`lib/core/l10n/disaster_recovery_text.dart` (core)。

## W7-BIZ-017 · lib/features/auth/pages/remote_mfa_page.dart

模块 `auth`；382 行；SHA256 `2a23bba3f0225d4b7206305452ac76cf254f12a362a63bd92cce0067da0beac6`。

| 审计项 | 静态来源/线索 |
|---|---|
| 页面/状态类 | RemoteMfaPage @27 (page-class)<br>_MfaSession @38 (supporting-class)<br>_MfaSessionState @44 (state-class) |
| 真实路由绑定 | /settings/remote-mfa；router @596；builder ['RemoteMfaPage']；redirect None |
| 重定向/别名候选 | 未静态确认；不能当作不存在 |
| 权限 | 未静态确认；不能当作不存在 |
| 接口常量 | 未静态确认；不能当作不存在 |
| 仓库调用 | lib/features/auth/repositories/remote_mfa_repository.dart；接口：/auth/mfa |
| 动作处理 | addPostFrameCallback @64 [action-like-invocation] 提示 ['post']；WidgetsBinding.instance.addPostFrameCallback((_) => _load());<br>cancel @69 [action-like-invocation] 提示 ['cancel']；_expiry?.cancel();<br>cancel @114 [action-like-invocation] 提示 ['cancel']；_expiry?.cancel();<br>cancel @121 [action-like-invocation] 提示 ['cancel']；_expiry?.cancel();<br>_confirm @136 [method-declaration-candidate] 提示 ['confirm']；Future<void> _confirm() async {<br>confirm @144 [action-like-invocation] 提示 ['confirm']；.confirm(_otp.text);<br>logout @180 [action-like-invocation] 提示 ['logout']；await ref.read(sessionProvider.notifier).logout();<br>_confirm @348 [action-like-invocation] 提示 ['confirm']；_busy ? null : _confirm(), |
| 控制器候选（人工核实） | server/src/main/java/com/uten/imp/features/auth/AuthController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence<br>server/src/main/java/com/uten/imp/features/auth/RemoteMfaController.java；需人工核实；依据 declared controller-prefix vs direct page/repository endpoint evidence |
| 审计限制 | 存在委托组件/provider；页面内操作和权限引用不是完整链路清单，需沿导入继续审查。 |

直接源依赖：`lib/components/layout/uten_page_layout.dart` (sharedComponents)；`lib/components/buttons/uten_back_button.dart` (sharedComponents)；`lib/components/buttons/uten_button.dart` (sharedComponents)；`lib/components/inputs/uten_input.dart` (sharedComponents)；`lib/components/layout/uten_app_bar.dart` (sharedComponents)；`lib/components/layout/uten_content_container.dart` (sharedComponents)；`lib/core/network/api_exception.dart` (core)；`lib/core/network/server_config.dart` (core)；`lib/core/router/route_names.dart` (core)；`lib/core/theme/uten_tokens.dart` (core)；`lib/core/ui/app_notification.dart` (core)；`lib/core/utils/display_datetime.dart` (core)；`lib/shared/providers/authenticated_scope_provider.dart` (sharedComponents)；`lib/shared/providers/session_provider.dart` (sharedComponents)；`lib/components/settings/settings_section.dart` (sharedComponents)；`lib/core/l10n/remote_access_text.dart` (core)；`lib/features/auth/repositories/remote_mfa_repository.dart` (repositories)；`lib/features/auth/widgets/remote_mfa_prompt.dart` (featureWidgets)。
