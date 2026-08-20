// 设置临时密码对话框（权限设置页 · 账号安全）。
//
// 员工忘记密码时，管理员为其设置一次性临时密码：
//  - 系统生成（推荐）：后端生成 20 位高熵随机密码（大小写字母/数字/符号）；
//  - 自定义：管理员口述/转告更方便，前端做基础校验，后端按同口径强度复核。
// 设置成功后：该账号全部已登录会话立即失效、临时密码 72 小时内有效、
// 员工用临时密码登录后被强制设置新密码。明文只在结果弹窗显示一次。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';

/// 对话框返回的选择：null = 系统生成；非空 = 管理员自定义临时密码。
class SetTemporaryPasswordChoice {
  const SetTemporaryPasswordChoice.generated() : customPassword = null;
  const SetTemporaryPasswordChoice.custom(this.customPassword);

  final String? customPassword;
}

/// 弹出「设置临时密码」对话框；取消返回 null。
Future<SetTemporaryPasswordChoice?> showSetTemporaryPasswordDialog(
  BuildContext context, {
  required String displayName,
  required String loginAccount,
}) {
  return showDialog<SetTemporaryPasswordChoice>(
    context: context,
    builder: (dialogContext) => _SetTemporaryPasswordDialog(
      displayName: displayName,
      loginAccount: loginAccount,
    ),
  );
}

class _SetTemporaryPasswordDialog extends StatefulWidget {
  const _SetTemporaryPasswordDialog({
    required this.displayName,
    required this.loginAccount,
  });

  final String displayName;
  final String loginAccount;

  @override
  State<_SetTemporaryPasswordDialog> createState() =>
      _SetTemporaryPasswordDialogState();
}

class _SetTemporaryPasswordDialogState
    extends State<_SetTemporaryPasswordDialog> {
  final _customController = TextEditingController();
  bool _customMode = false;
  bool _obscure = true;

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  /// 与后端 validateCustomTemporaryPassword 同口径的前端预校验（后端仍终审）。
  String? get _customError {
    if (!_customMode) return null;
    final value = _customController.text.trim();
    if (value.isEmpty) return null; // 空值不报错，仅禁用提交
    if (value.length < 8) return '至少 8 位';
    if (value.length > 64) return '最长 64 位';
    if (value.contains(RegExp(r'\s'))) return '不能包含空格等空白字符';
    final hasLetter = value.contains(RegExp(r'[A-Za-z]'));
    final hasDigit = value.contains(RegExp(r'\d'));
    if (!hasLetter || !hasDigit) return '需同时包含字母和数字';
    if (value.toLowerCase() == widget.loginAccount.toLowerCase()) {
      return '不能与登录账号相同';
    }
    return null;
  }

  bool get _canSubmit =>
      !_customMode ||
      (_customController.text.trim().isNotEmpty && _customError == null);

  void _submit() {
    if (!_canSubmit) return;
    Navigator.pop(
      context,
      _customMode
          ? SetTemporaryPasswordChoice.custom(_customController.text.trim())
          : const SetTemporaryPasswordChoice.generated(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
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
                '员工忘记密码时，为「${widget.displayName}（${widget.loginAccount}）」'
                '设置一次性临时密码。员工用临时密码登录后，系统会强制其设置新密码。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              _modeTile(
                icon: Icons.auto_awesome_rounded,
                title: '系统生成安全密码',
                subtitle: '20 位随机密码，含大小写字母、数字与符号（推荐）',
                selected: !_customMode,
                onTap: () => setState(() => _customMode = false),
              ),
              const SizedBox(height: UtenSpacing.s8),
              _modeTile(
                icon: Icons.edit_outlined,
                title: '自定义临时密码',
                subtitle: '至少 8 位，需同时包含字母和数字',
                selected: _customMode,
                onTap: () => setState(() => _customMode = true),
              ),
              if (_customMode) ...[
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: _customController,
                  obscureText: _obscure,
                  autofocus: true,
                  maxLength: 64,
                  decoration: InputDecoration(
                    labelText: '临时密码',
                    hintText: '8–64 位，含字母和数字',
                    isDense: true,
                    counterText: '',
                    border: const OutlineInputBorder(),
                    errorText: _customError,
                    suffixIcon: IconButton(
                      tooltip: _obscure ? '显示密码' : '隐藏密码',
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                ),
              ],
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
                        '设置后该账号所有已登录会话立即失效；临时密码仅显示一次，'
                        '72 小时内有效。请通过安全渠道告知员工，切勿明文留存。',
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
      actionsAlignment: MainAxisAlignment.end,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        UtenButton(
          size: UtenButtonSize.small,
          icon: Icons.key_rounded,
          onPressed: _canSubmit ? _submit : null,
          child: const Text('设置临时密码'),
        ),
      ],
    );
  }

  /// 模式选择卡片：选中态描边 + 图标着色，比裸 Radio 更醒目。
  Widget _modeTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s12,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                size: 20,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
