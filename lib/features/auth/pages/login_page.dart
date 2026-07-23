// LoginPage - 登录页
// 文档：docs/03-页面/登录页.md（待写）
//
// 设计：
// - 深色 slate-900 → slate-800 渐变背景
// - 玻璃拟态登录卡
// - 中等进场动画
// - 顶部品牌字标 UtenWordmarkLogo

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/brand/uten_wordmark_logo.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../shared/providers/session_provider.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

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
  bool _rememberDevice = false;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await ref
          .read(sessionProvider.notifier)
          .login(
            account: _accountController.text.trim(),
            password: _passwordController.text,
            rememberDevice: _rememberDevice,
          );

      if (mounted) {
        // 路由守卫会自动重定向到 dashboard（首登强制改密则重定向到改密页）
        context.go(RouteName.dashboard);
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.message);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = '登录失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: DecoratedBox(
        decoration: BoxDecoration(color: theme.scaffoldBackgroundColor),
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
                        child: _buildLoginCard(l10n, theme),
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

  Widget _buildLoginCard(AppLocalizations l10n, ThemeData theme) {
    final isCompact = MediaQuery.sizeOf(context).width < 480;
    final pagePadding = isCompact ? 20.0 : 24.0;
    final cardPadding = isCompact ? 24.0 : 32.0;
    final logoWidth = isCompact ? 200.0 : 220.0;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Padding(
        padding: EdgeInsets.all(pagePadding),
        child: UtenCard(
          padding: EdgeInsets.all(cardPadding),
          borderRadius: 16,
          elevation: UtenCardElevation.high,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: UtenWordmarkLogo(
                    width: logoWidth,
                    height: logoWidth / (405 / 74),
                  ),
                ),
                const SizedBox(height: 32),
                UtenInput(
                  controller: _accountController,
                  hint: l10n.loginAccountHint,
                  prefixIcon: Icons.person_outline_rounded,
                  textInputAction: TextInputAction.next,
                  validator: (value) => (value == null || value.isEmpty)
                      ? l10n.loginAccountRequired
                      : null,
                  autofillHints: const ['username'],
                ),
                const SizedBox(height: 16),
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
                const SizedBox(height: 16),
                Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: Checkbox(
                        value: _rememberDevice,
                        onChanged: (value) =>
                            setState(() => _rememberDevice = value ?? false),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n.loginRememberMe,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: UtenColors.error.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: UtenColors.error,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
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
                const SizedBox(height: 24),
                UtenButton(
                  onPressed: _isLoading ? null : _handleLogin,
                  isLoading: _isLoading,
                  isExpanded: true,
                  size: UtenButtonSize.large,
                  child: Text(
                    _isLoading ? l10n.loginLoggingIn : l10n.loginButton,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.loginFooter,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
