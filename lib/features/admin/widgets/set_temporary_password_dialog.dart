// 设置临时密码确认框（权限设置页 · 账号安全）。
//
// 管理员可选择服务端随机生成或手动输入；明文仅在本次交付流程中展示。
// 设置成功后：该账号全部已登录会话立即失效、临时密码在有效期内可用
// (默认 72 小时，可在系统设置调整)、员工用临时密码登录后被强制设置新密码。
// 服务端要求再认证：确认后网络层会弹统一的「重新输入登录密码」框 (ADR-110)。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/widgets/temporary_password_input.dart';
import '../../../shared/auth/account_action_owner.dart';

/// 确认返回本次密码选择，取消返回 null；选择不能持久化。
Future<TemporaryPasswordChoice?> showSetTemporaryPasswordDialog(
  BuildContext context, {
  required String displayName,
  required String loginAccount,
  String? permissionDiscardWarning,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
  bool allowManual = false,
}) {
  return showDialog<TemporaryPasswordChoice>(
    context: context,
    builder: (dialogContext) => _SetTemporaryPasswordDialog(
      displayName: displayName,
      loginAccount: loginAccount,
      permissionDiscardWarning: permissionDiscardWarning,
      isCurrent: isCurrent,
      ownerChanges: ownerChanges,
      allowManual: allowManual,
    ),
  );
}

class _SetTemporaryPasswordDialog extends ConsumerStatefulWidget {
  const _SetTemporaryPasswordDialog({
    required this.displayName,
    required this.loginAccount,
    this.permissionDiscardWarning,
    this.isCurrent,
    this.ownerChanges,
    required this.allowManual,
  });

  final String displayName;
  final String loginAccount;
  final String? permissionDiscardWarning;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;
  final bool allowManual;

  @override
  ConsumerState<_SetTemporaryPasswordDialog> createState() =>
      _SetTemporaryPasswordDialogState();
}

class _SetTemporaryPasswordDialogState
    extends ConsumerState<_SetTemporaryPasswordDialog> {
  final _passwordInput = TemporaryPasswordInputController();
  late final AccountActionOwner _owner;
  ModalRoute<TemporaryPasswordChoice>? _route;
  bool _invalidated = false;

  @override
  void initState() {
    super.initState();
    _owner = AccountActionOwner(
      ref,
      isCurrent: widget.isCurrent,
      targetChanges: widget.ownerChanges,
      onInvalidated: _invalidate,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of<TemporaryPasswordChoice>(context);
  }

  void _invalidate() {
    if (!mounted || _invalidated) return;
    _passwordInput.clearSensitive();
    setState(() => _invalidated = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = _route;
      if (mounted && route != null && route.isActive) {
        route.navigator?.removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    _owner.dispose();
    _passwordInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_invalidated) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return UtenAlertDialog(
      scrollable: false,
      key: const Key('set-temporary-password-dialog'),
      title: const UtenDialogHeading(
        title: Text('设置临时密码'),
        icon: Icons.key_rounded,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.permissionDiscardWarning != null) ...[
                Text(
                  widget.permissionDiscardWarning!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
              ],
              Text(
                '为「${widget.displayName}(${widget.loginAccount})」设置一次性临时密码。'
                '员工用临时密码登录后，系统会强制其设置新密码。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              TemporaryPasswordInput(
                controller: _passwordInput,
                allowManual: widget.allowManual,
              ),
              const SizedBox(height: UtenSpacing.s16),
              Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: UtenColors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(UtenRadius.control),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.shield_outlined,
                      size: 18,
                      color: UtenColors.warning,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        '设置后该账号所有已登录会话立即失效，本人会收到一条账号安全提醒；'
                        '临时密码只显示一次，有效期默认 72 小时(系统设置可调)。'
                        '请通过安全渠道告知员工，切勿明文留存。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('set-temporary-password-confirm'),
          size: UtenButtonSize.small,
          icon: Icons.key_rounded,
          onPressed: () {
            if (_owner.isCurrent && _passwordInput.validate()) {
              Navigator.pop(context, _passwordInput.choice);
            }
          },
          child: const Text('设置临时密码'),
        ),
      ],
    );
  }
}
