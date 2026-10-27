// LoginPage - 登录页（v2 - 响应式认证布局）
// 文档：docs/03-页面/登录页.md
//
// 设计：
// - compact（<600dp）：全屏洁净布局——无卡片，品牌吉祥物 + 字标 + 表单
//   直接落在页面背景上，24px 水平留白
// - medium+（≥600dp）：极淡 teal 调页面底（teal50 / 深色 darkBackground）+
//   居中登录卡（maxWidth 440，14 圆角生态 → 卡片 16，高层级阴影），
//   克制不铺渐变
// - 保留淡入 + 上滑进场动画；认证逻辑 / 校验器 / Provider 不变

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/brand/uten_brand_mascot.dart';
import '../../../components/brand/uten_wordmark_logo.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/login_server_preparation.dart';
import '../../../core/network/server_config.dart';
import '../../../core/network/server_selection.dart';
import '../../../core/platform/desktop_window.dart';
import '../../../shared/platform_branding/platform_branding_provider.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/shared_providers.dart';
import '../../../shared/repositories/account_history_store.dart';
import '../widgets/account_field.dart';
import '../widgets/desktop_login_layout.dart';
import '../remote_access_text.dart';
import '../../../core/l10n/disaster_recovery_text.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key, this.returnTo});

  final String? returnTo;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  final _formKey = GlobalKey<FormState>();
  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  final _otpController = TextEditingController();
  bool _requiresOtp = false;
  String _lastAccount = '';
  int _loginContextEpoch = 0;
  int _accountInputEpoch = 0;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _accountController.addListener(_clearOtpForAccountChange);
    ref.listenManual(apiBaseUrlProvider, (previous, next) {
      if (previous != next) _resetOtpChallenge();
    });
    _controller = AnimationController(vsync: this, duration: UtenAnim.slow);
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: UtenAnim.enter,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: UtenAnim.enter));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _accountController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    super.dispose();
  }

  void _clearOtpForAccountChange() {
    final account = _accountController.text.trim();
    if (account == _lastAccount) return;
    _lastAccount = account;
    _accountInputEpoch++;
    _resetOtpChallenge();
  }

  void _resetOtpChallenge() {
    // Challenges belong to one account and connection, including A -> B -> A.
    _loginContextEpoch++;
    _otpController.clear();
    if (!_requiresOtp && _errorMessage == null) return;
    setState(() {
      _requiresOtp = false;
      _errorMessage = null;
    });
  }

  Future<void> _handleLogin() async {
    if (_isLoading || !_formKey.currentState!.validate()) {
      return;
    }

    var loginContextEpoch = _loginContextEpoch;
    final accountInputEpoch = _accountInputEpoch;
    final account = _accountController.text.trim();
    final session = ref.read(sessionProvider.notifier);
    // A fresh probe may legitimately change the endpoint before credentials
    // are sent. Competing user intents and explicit configuration commands
    // still retire this preparation, including changes back to the same URL.
    final intentBeforePreparation = session.userIntentEpoch;
    final preferences = ref.read(sharedPreferencesProvider);
    final configurationRevision = serverSelectionRevision(preferences);
    bool isCurrentLogin() =>
        mounted &&
        accountInputEpoch == _accountInputEpoch &&
        loginContextEpoch == _loginContextEpoch &&
        identical(preferences, ref.read(sharedPreferencesProvider)) &&
        serverSelectionRevision(preferences) == configurationRevision &&
        identical(ref.read(sessionProvider.notifier), session);
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Choose a currently reachable trusted endpoint before capturing the
      // challenge context or reading OTP. This may itself switch local/cloud.
      await ref.read(loginServerPreparationProvider)();
      if (!mounted) return;
      // Flush the derived endpoint and its challenge-reset listener before
      // capturing the context for the one credential request below.
      ref.read(apiBaseUrlProvider);
      if (!mounted ||
          accountInputEpoch != _accountInputEpoch ||
          !identical(ref.read(sessionProvider.notifier), session) ||
          session.userIntentEpoch != intentBeforePreparation ||
          !identical(preferences, ref.read(sharedPreferencesProvider)) ||
          serverSelectionRevision(preferences) != configurationRevision) {
        return;
      }
      loginContextEpoch = _loginContextEpoch;
      await session.login(
        account: account,
        password: _passwordController.text,
        otpCode: _requiresOtp ? _otpController.text : null,
        isCurrent: isCurrentLogin,
      );
      if (!isCurrentLogin()) return;
      final result = ref.read(sessionProvider);
      if (!result.isLoggedIn && !result.mustChangePassword) return;
      // 登录成功：记住账号（只记账号不记密码）
      await ref.read(accountHistoryProvider).add(account);

      if (mounted && isCurrentLogin()) {
        // 恢复经校验的员工目标；首登状态会先由路由守卫转入强制改密。
        context.go(widget.returnTo ?? RouteName.dashboard);
      }
    } on LoginServerPreparationCancelled {
      // A newer connection choice owns the UI; no credentials were sent.
      return;
    } on SessionMutationSuperseded {
      return;
    } on ApiException catch (e) {
      if (isCurrentLogin()) {
        setState(() {
          _requiresOtp = e.code == 'MFA_REQUIRED' || e.code == 'MFA_INVALID';
          _errorMessage = e.code == 'MFA_REQUIRED'
              ? remoteAccessText(context, 'loginOtpRequired')
              : _loginFailureText(context, e);
          _otpController.clear();
        });
      }
    } catch (e) {
      if (isCurrentLogin()) {
        setState(() {
          _requiresOtp = false;
          _errorMessage = _loginFailureText(context, null);
          _otpController.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isCompact = supportsDesktopWindow || context.breakpoint.isCompact;
    final isDark = theme.brightness == Brightness.dark;
    final branding = ref.watch(platformBrandingSnapshotProvider);

    if (supportsDesktopWindow) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: SelectionArea(
          child: SafeArea(
            child: DesktopLoginLayout(
              branding: branding,
              formBuilder: (showBrand) =>
                  _buildLoginForm(l10n, theme, showBrand: showBrand),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      // medium+ 铺一层极淡 teal 调底，让白色登录卡自然浮起；compact 保持页面底色
      backgroundColor: isCompact
          ? theme.scaffoldBackgroundColor
          : (isDark
                ? UtenColors.darkBackground
                : branding.usesDefaultColors
                ? UtenColors.teal50
                : theme.colorScheme.primary.withValues(alpha: 0.04)),
      // 局部 SelectionArea：登录卡文字（标题/版本号/版权等）可框选复制（准则 §3.4）。
      // 登录路由在 ShellRoute 之外，选择区不含外壳轮询，无 CME 风险。
      body: SelectionArea(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: FadeTransition(
                      opacity: _fadeAnimation,
                      child: SlideTransition(
                        position: _slideAnimation,
                        child: isCompact
                            // 全屏洁净布局：表单直通背景
                            ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: UtenSpacing.s24,
                                ),
                                child: _buildLoginForm(l10n, theme),
                              )
                            // 居中登录卡（maxWidth 440）
                            : Padding(
                                padding: const EdgeInsets.all(UtenSpacing.s24),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 440,
                                  ),
                                  child: UtenCard(
                                    padding: const EdgeInsets.all(
                                      UtenSpacing.s32,
                                    ),
                                    child: _buildLoginForm(l10n, theme),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 品牌区 + 表单字段（两种布局共用同一份内容）
  Widget _buildLoginForm(
    AppLocalizations l10n,
    ThemeData theme, {
    bool showBrand = true,
  }) {
    final branding = ref.watch(platformBrandingSnapshotProvider);
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 品牌区：吉祥物 + 横向字标
          if (showBrand) ...[
            if (branding.usesDefaultArtwork) ...[
              const Center(child: UtenBrandMascot.size(88)),
              const SizedBox(height: UtenSpacing.s16),
            ],
            Center(
              child: UtenWordmarkLogo(
                width: 220,
                height: branding.usesDefaultArtwork ? 220 / (405 / 74) : 72,
              ),
            ),
            if (branding.hasLogo) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                branding.platformName,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ],
            if (branding.tagline.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                branding.tagline,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: UtenSpacing.s32),
          ],
          if (branding.loginNotice.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s16),
            Container(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: UtenRadius.mdAll,
              ),
              child: Text(
                branding.loginNotice,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: UtenSpacing.s16),
          ],
          AccountField(
            controller: _accountController,
            hint: l10n.loginAccountHint,
            validator: (value) => (value == null || value.isEmpty)
                ? l10n.loginAccountRequired
                : null,
          ),
          const SizedBox(height: UtenSpacing.s16),
          UtenInput(
            controller: _passwordController,
            hint: l10n.loginPasswordHint,
            prefixIcon: Icons.lock_outline_rounded,
            isPassword: true,
            textInputAction: TextInputAction.go,
            onFieldSubmitted: (_) => _handleLogin(),
            validator: (value) => (value == null || value.isEmpty)
                ? l10n.loginPasswordRequired
                : null,
            autofillHints: const ['password'],
          ),
          // 「记住此设备」开关已移除：安全考虑，每次登录必须输密码（不长期记住设备/免密）。
          // Only a server challenge may add OTP to the ordinary password form.
          if (_requiresOtp) ...[
            const SizedBox(height: UtenSpacing.s16),
            UtenInput(
              key: const Key('login-otp'),
              controller: _otpController,
              label: remoteAccessText(context, 'otp'),
              hint: remoteAccessText(context, 'otpHint'),
              aiSensitive: true,
              keyboardType: TextInputType.number,
              enabled: !_isLoading,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              autofillHints: const [AutofillHints.oneTimeCode],
              validator: (value) => RegExp(r'^\d{6}$').hasMatch(value ?? '')
                  ? null
                  : remoteAccessText(context, 'otpInvalid'),
              onFieldSubmitted: (_) => _handleLogin(),
            ),
            TextButton(
              key: const Key('login-cancel-otp'),
              onPressed: _isLoading ? null : _resetOtpChallenge,
              child: Text(remoteAccessText(context, 'loginCancelOtp')),
            ),
          ],
          // 账号历史单独记忆（AccountField 下拉，只记账号不记密码）。
          if (_errorMessage != null) ...[
            const SizedBox(height: UtenSpacing.s16),
            Container(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              decoration: BoxDecoration(
                color: UtenColors.error.withValues(alpha: 0.12),
                borderRadius: UtenRadius.mdAll,
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: UtenColors.error,
                    size: 18,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: UtenColors.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s24),
          UtenButton(
            onPressed: _isLoading ? null : _handleLogin,
            isLoading: _isLoading,
            isExpanded: true,
            size: UtenButtonSize.large,
            child: Text(_isLoading ? l10n.loginLoggingIn : l10n.loginButton),
          ),
          const SizedBox(height: UtenSpacing.s24),
          TextButton.icon(
            key: const Key('login-disaster-recovery'),
            onPressed: () => context.push(RouteName.disasterRecovery),
            icon: const Icon(Icons.health_and_safety_outlined),
            label: Text(recoveryText(context, '运行与灾备')),
          ),
          Text(
            branding.usesDefaultArtwork
                ? l10n.loginFooter(DateTime.now().year)
                : branding.copyright(DateTime.now().year),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          if (branding.supportPhone.isNotEmpty ||
              branding.supportEmail.isNotEmpty ||
              branding.website.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              [
                if (branding.supportPhone.isNotEmpty) branding.supportPhone,
                if (branding.supportEmail.isNotEmpty) branding.supportEmail,
                if (branding.website.isNotEmpty) branding.website,
              ].join(' · '),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _loginFailureText(BuildContext context, ApiException? error) {
  final language = Localizations.localeOf(context).languageCode;
  final messages = switch (error?.code) {
    'NETWORK' => (
      '无法连接服务器，请检查网络连接后重试',
      'Unable to connect to the server. Check your connection and try again.',
      '서버에 연결할 수 없습니다. 네트워크 연결을 확인한 후 다시 시도하세요.',
    ),
    'NETWORK_TIMEOUT' => (
      '连接服务器超时，请稍后重试',
      'The connection to the server timed out. Try again later.',
      '서버 연결 시간이 초과되었습니다. 잠시 후 다시 시도하세요.',
    ),
    'BAD_CREDENTIALS' || 'INVALID_CREDENTIALS' => (
      '账号或密码错误，请重新输入',
      'Incorrect account or password. Try again.',
      '계정 또는 비밀번호가 올바르지 않습니다. 다시 입력하세요.',
    ),
    null => (
      '登录失败，请稍后重试',
      'Sign-in failed. Try again later.',
      '로그인하지 못했습니다. 잠시 후 다시 시도하세요.',
    ),
    _ => null,
  };
  if (messages == null) return remoteAccessError(context, error!);
  return switch (language) {
    'en' => messages.$2,
    'ko' => messages.$3,
    _ => messages.$1,
  };
}
