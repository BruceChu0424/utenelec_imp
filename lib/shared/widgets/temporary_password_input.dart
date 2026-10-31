import 'package:flutter/material.dart';

import '../../components/inputs/uten_input.dart';
import '../../components/layout/uten_segment_row.dart';
import '../../core/security/input_validators.dart';
import '../../core/theme/uten_tokens.dart';

/// One transient choice. Never persist this object or include it in diagnostics.
class TemporaryPasswordChoice {
  const TemporaryPasswordChoice.random() : temporaryPassword = null;
  const TemporaryPasswordChoice.custom(String password)
    : temporaryPassword = password;

  final String? temporaryPassword;
}

/// Shared by account management and employee detail. Random passwords remain
/// server-generated; custom text is transmitted verbatim only on confirmation.
class TemporaryPasswordInputController extends ChangeNotifier {
  final password = TextEditingController();
  final confirmation = TextEditingController();
  final formKey = GlobalKey<FormState>();
  bool _manual = false;

  bool get manual => _manual;

  void selectManual(bool value) {
    if (_manual == value) return;
    clearSensitive();
    _manual = value;
    notifyListeners();
  }

  /// Capability must also be checked when committing a choice; a disabled
  /// segment alone cannot retire an already retained manual mode.
  bool validate({required bool allowManual}) =>
      !manual || (allowManual && (formKey.currentState?.validate() ?? false));

  TemporaryPasswordChoice get choice => manual
      ? TemporaryPasswordChoice.custom(password.text)
      : const TemporaryPasswordChoice.random();

  void clearSensitive() {
    password.clear();
    confirmation.clear();
  }

  @override
  void dispose() {
    clearSensitive();
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }
}

class TemporaryPasswordInput extends StatelessWidget {
  const TemporaryPasswordInput({
    super.key,
    required this.controller,
    this.enabled = true,
    this.allowManual = false,
  });

  final TemporaryPasswordInputController controller;
  final bool enabled;
  final bool allowManual;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Form(
      key: controller.formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenSegmentRow<bool>(
            segments: [
              const ButtonSegment(value: false, label: Text('随机生成')),
              ButtonSegment(
                value: true,
                label: const Text('手动输入'),
                enabled: allowManual,
              ),
            ],
            selected: {controller.manual},
            showSelectedIcon: false,
            onSelectionChanged: enabled
                ? (values) {
                    if (values.single && !allowManual) return;
                    controller.selectManual(values.single);
                  }
                : null,
          ),
          const SizedBox(height: UtenSpacing.s12),
          if (controller.manual) ...[
            UtenInput(
              key: const ValueKey('temporary-password-input'),
              controller: controller.password,
              label: '临时密码',
              isPassword: true,
              required: true,
              enabled: enabled,
              textInputAction: TextInputAction.next,
              validator: InputValidators.password,
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenInput(
              key: const ValueKey('temporary-password-confirmation'),
              controller: controller.confirmation,
              label: '确认临时密码',
              isPassword: true,
              required: true,
              enabled: enabled,
              validator: (value) {
                final required = InputValidators.password(value);
                if (required != null) return required;
                return value == controller.password.text ? null : '两次输入的密码不一致';
              },
            ),
          ] else
            Text(
              '确认后由系统生成 20 位随机临时密码。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    ),
  );
}
