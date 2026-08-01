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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/brand/uten_brand_mascot.dart';
import '../../../components/brand/uten_wordmark_logo.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/repositories/account_history_store.dart';
import '../widgets/account_field.dart';

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
      final account = _accountController.text.trim();
      await ref
          .read(sessionProvider.notifier)
          .login(account: account, password: _passwordController.text);
      // 登录成功：记住账号（只记账号不记密码）
      await ref.read(accountHistoryProvider).add(account);

      if (mounted) {
        // 恢复经校验的员工目标；首登状态会先由路由守卫转入强制改密。
        context.go(widget.returnTo ?? RouteName.dashboard);
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
    final isCompact = context.breakpoint.isCompact;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      // medium+ 铺一层极淡 teal 调底，让白色登录卡自然浮起；compact 保持页面底色
      backgroundColor: isCompact
          ? theme.scaffoldBackgroundColor
          : (isDark ? UtenColors.darkBackground : UtenColors.teal50),
      body: SafeArea(
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
                                  borderRadius: UtenRadius.xl,
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
    );
  }

  /// 品牌区 + 表单字段（两种布局共用同一份内容）
  Widget _buildLoginForm(AppLocalizations l10n, ThemeData theme) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 品牌区：吉祥物 + 横向字标
          const Center(child: UtenBrandMascot.size(88)),
          const SizedBox(height: UtenSpacing.s16),
          const Center(
            child: UtenWordmarkLogo(width: 220, height: 220 / (405 / 74)),
          ),
          const SizedBox(height: UtenSpacing.s32),
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
          const SizedBox(height: UtenSpacing.s16),
          // 「记住此设备」开关已移除：安全考虑，每次登录必须输密码（不长期记住设备/免密）。
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
          Text(
            l10n.loginFooter,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
