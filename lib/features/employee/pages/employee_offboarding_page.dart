// 离职流程页（Phase 2）
// 文档：docs/03-页面/离职流程页.md

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../components/layout/uten_app_bar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/ui/app_notification.dart';

enum ResignType { voluntary, dismissed, contractEnd, retire }

class EmployeeOffboardingPage extends StatefulWidget {
  const EmployeeOffboardingPage({super.key, required this.employeeId});
  final String employeeId;

  @override
  State<EmployeeOffboardingPage> createState() =>
      _EmployeeOffboardingPageState();
}

class _EmployeeOffboardingPageState extends State<EmployeeOffboardingPage> {
  int _step = 0;
  bool _submitting = false;
  ResignType _type = ResignType.voluntary;
  DateTime? _date;
  final _reason = TextEditingController();
  final _handover = TextEditingController();
  final _checks = [false, false, false, false]; // 门禁/资产/账号/社保

  @override
  void dispose() {
    _reason.dispose();
    _handover.dispose();
    super.dispose();
  }

  String _typeLabel(AppLocalizations l10n, ResignType t) => switch (t) {
    ResignType.voluntary => l10n.resignTypeVoluntary,
    ResignType.dismissed => l10n.resignTypeDismissed,
    ResignType.contractEnd => l10n.resignTypeContractEnd,
    ResignType.retire => l10n.resignTypeRetire,
  };

  String _checkLabel(AppLocalizations l10n, int i) => switch (i) {
    0 => l10n.resignCheckAccess,
    1 => l10n.resignCheckAssets,
    2 => l10n.resignCheckAccount,
    3 => l10n.resignCheckSocial,
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.employeeOffboardTitle,
        showBackButton: true,
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if (_step > 0)
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _step--),
                    child: Text(l10n.employeeOffboardBack),
                  ),
                ),
              if (_step > 0) const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                  ),
                  onPressed: _submitting ? null : _next,
                  child: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _step == 2
                              ? l10n.employeeOffboardConfirmAction
                              : l10n.employeeOffboardNext,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Stepper(
        currentStep: _step,
        onStepContinue: _next,
        onStepCancel: () => setState(() => _step > 0 ? _step-- : null),
        controlsBuilder: (context, details) => const SizedBox.shrink(),
        steps: [
          Step(
            title: Text(l10n.employeeOffboardStepStart),
            isActive: _step >= 0,
            state: _step > 0 ? StepState.complete : StepState.indexed,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<ResignType>(
                  initialValue: _type,
                  decoration: _Deco(l10n.employeeOffboardFieldType),
                  items: [
                    for (final t in ResignType.values)
                      DropdownMenuItem(
                        value: t,
                        child: Text(_typeLabel(l10n, t)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _type = v!),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _date ?? DateTime.now(),
                      firstDate: DateTime.now(),
                      lastDate: DateTime(2100),
                    );
                    if (d != null) setState(() => _date = d);
                  },
                  child: InputDecorator(
                    decoration: _Deco(l10n.employeeOffboardFieldDate),
                    child: Text(
                      _date == null
                          ? l10n.employeeOffboardPickDate
                          : DateFormat.yMd().format(_date!),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _reason,
                  maxLines: 2,
                  decoration: _Deco(l10n.employeeOffboardFieldReason),
                ),
              ],
            ),
          ),
          Step(
            title: Text(l10n.employeeOffboardStepHandover),
            isActive: _step >= 1,
            state: _step > 1
                ? StepState.complete
                : (_step == 1 ? StepState.indexed : StepState.disabled),
            content: TextField(
              controller: _handover,
              maxLines: 3,
              decoration: _Deco(l10n.employeeOffboardFieldHandover),
            ),
          ),
          Step(
            title: Text(l10n.employeeOffboardStepCheck),
            isActive: _step >= 2,
            state: _step == 2 ? StepState.indexed : StepState.disabled,
            content: Column(
              children: [
                for (var i = 0; i < _checks.length; i++)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _checks[i],
                    title: Text(_checkLabel(l10n, i)),
                    onChanged: (v) => setState(() => _checks[i] = v ?? false),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _next() async {
    final l10n = AppLocalizations.of(context);
    if (_step < 2) {
      if (_step == 0 && _date == null) {
        _toastError(l10n.employeeOffboardPickDateRequired);
        return;
      }
      setState(() => _step++);
      return;
    }
    if (!_checks.every((c) => c)) {
      _toastError(l10n.employeeOffboardChecksRequired);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.employeeOffboardConfirmTitle),
        content: Text(l10n.employeeOffboardConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _submitting = true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      setState(() => _submitting = false);
      context.appSuccess(l10n.employeeOffboardCompleted);
      context.go('/employee/${widget.employeeId}');
    }
  }

  void _toastError(String msg) {
    if (!mounted) return;
    context.appError(msg);
  }
}

class _Deco extends InputDecoration {
  const _Deco(String label)
    : super(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
      );
}
