// 设置临时密码确认框（权限设置页 · 账号安全）。
//
// 员工忘记密码时，管理员为其重置一次性临时密码。临时密码只由系统随机生成
// (管理员不能自己指定，避免弱口令和「口述一个好记的」)，明文只在结果弹窗显示一次。
// 设置成功后：该账号全部已登录会话立即失效、临时密码在有效期内可用
// (默认 72 小时，可在系统设置调整)、员工用临时密码登录后被强制设置新密码。
// 服务端要求再认证：确认后网络层会弹统一的「重新输入登录密码」框 (ADR-110)。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';

/// 弹出「设置临时密码」确认框；确认返回 true，取消返回 false/null。
Future<bool?> showSetTemporaryPasswordDialog(
  BuildContext context, {
  required String displayName,
  required String loginAccount,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => _SetTemporaryPasswordDialog(
      displayName: displayName,
      loginAccount: loginAccount,
    ),
  );
}

class _SetTemporaryPasswordDialog extends StatelessWidget {
  const _SetTemporaryPasswordDialog({
    required this.displayName,
    required this.loginAccount,
  });

  final String displayName;
  final String loginAccount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('set-temporary-password-dialog'),
      title: const Row(
        children: [
          Icon(Icons.key_rounded),
          SizedBox(width: UtenSpacing.s8),
          Text('设置临时密码'),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '员工忘记密码时，为「$displayName($loginAccount)」生成一次性临时密码。'
                '系统随机生成 20 位安全密码(含大小写字母、数字与符号)，'
                '员工用临时密码登录后，系统会强制其设置新密码。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: UtenColors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
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
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('set-temporary-password-confirm'),
          size: UtenButtonSize.small,
          icon: Icons.key_rounded,
          onPressed: () => Navigator.pop(context, true),
          child: const Text('生成临时密码'),
        ),
      ],
    );
  }
}
