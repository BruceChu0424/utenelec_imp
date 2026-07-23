// ChangePasswordPage - 改密页（首登强制改密 + 设置中修改密码）
// 文档：docs/03-页面/设置页.md（修改密码入口）· 全局机制首登强制改密
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/security/input_validators.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../shared/providers/session_provider.dart';

class ChangePasswordPage extends ConsumerStatefulWidget {
  const ChangePasswordPage({super.key, this.forced = false});

  /// true = 首登强制改密（不可返回，无 AppBar 返回按钮）。
  final bool forced;

  @override
  ConsumerState<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends ConsumerState<ChangePasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_new.text != _confirm.text) {
      setState(() => _error = '两次输入的新密码不一致');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).changePassword(
            oldPassword: _old.text,
            newPassword: _new.text,
          );
      if (!mounted) return;
      // 状态已变 authenticated；强制模式路由守卫会重定向到工作台
      if (widget.forced) {
        context.go(RouteName.dashboard);
      } else {
        context.pop();
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return PopScope(
      canPop: !widget.forced,
      child: Scaffold(
        appBar: widget.forced
            ? AppBar(automaticallyImplyLeading: false, title: Text('修改密码'))
            : AppBar(title: Text('修改密码')),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: UtenCard(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        widget.forced ? Icons.lock_reset_rounded : Icons.password_rounded,
                        size: 40,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.forced ? '首次登录，请修改默认密码' : '修改密码',
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '密码至少 8 位，需同时包含字母和数字',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      UtenInput(
                        controller: _old,
                        label: '原密码',
                        isPassword: true,
                        textInputAction: TextInputAction.next,
                        validator: (v) => InputValidators.required(v, label: '原密码'),
                      ),
                      const SizedBox(height: 14),
                      UtenInput(
                        controller: _new,
                        label: '新密码',
                        isPassword: true,
                        textInputAction: TextInputAction.next,
                        validator: InputValidators.password,
                      ),
                      const SizedBox(height: 14),
                      UtenInput(
                        controller: _confirm,
                        label: '确认新密码',
                        isPassword: true,
                        textInputAction: TextInputAction.go,
                        onFieldSubmitted: (_) => _submit(),
                        validator: (v) => InputValidators.required(v, label: '确认密码'),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: UtenColors.error)),
                      ],
                      const SizedBox(height: 20),
                      UtenButton(
                        onPressed: _loading ? null : _submit,
                        isLoading: _loading,
                        isExpanded: true,
                        size: UtenButtonSize.large,
                        child: Text(l10n.commonConfirm),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
