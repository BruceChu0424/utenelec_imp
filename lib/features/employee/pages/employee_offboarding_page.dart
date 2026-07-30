// 离职流程页（真实后端）
// 表单页全断点套 UtenContentContainer.narrow（maxWidth 1120）。
// 提交：POST /api/org/employees/{id}/offboard；后端置状态 resigned、写任职记录、
// 自动驳回在途信息修改申请、停用登录账号并吊销 refresh token。
// 文档：docs/03-页面/离职流程页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../repositories/employee_repository.dart';

enum ResignType { voluntary, dismissed, contractEnd, retire }

class EmployeeOffboardingPage extends ConsumerStatefulWidget {
  const EmployeeOffboardingPage({super.key, required this.employeeId});
  final String employeeId;

  @override
  ConsumerState<EmployeeOffboardingPage> createState() =>
      _EmployeeOffboardingPageState();
}

class _EmployeeOffboardingPageState
    extends ConsumerState<EmployeeOffboardingPage> {
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
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Row(
            children: [
              if (_step > 0)
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _step--),
                    child: Text(l10n.employeeOffboardBack),
                  ),
                ),
              if (_step > 0) const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: UtenColors.error,
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
      // 表单页全断点窄版收敛（1120），避免宽屏 Stepper 被拉得过长
      body: UtenContentContainer.narrow(
        child: Stepper(
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
                const SizedBox(height: UtenSpacing.s12),
                InkWell(
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _date ?? DateTime.now(),
                      firstDate: DateTime(2020),
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
                const SizedBox(height: UtenSpacing.s12),
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
    try {
      // 交接说明 + 回收确认项一并存档（后端离职单无独立交接/清单字段，
      // 全部并入 reason 写入任职记录 remark，事后可追溯）
      final reason = _reason.text.trim();
      final handover = _handover.text.trim();
      final checkedItems = [
        for (var i = 0; i < _checks.length; i++)
          if (_checks[i]) _checkLabel(l10n, i),
      ];
      final combinedReason = [
        if (reason.isNotEmpty) reason,
        if (handover.isNotEmpty) '${l10n.employeeOffboardFieldHandover}：$handover',
        if (checkedItems.isNotEmpty)
          '${l10n.employeeOffboardStepCheck}：${checkedItems.join('、')}',
      ].join('\n');
      await ref.read(employeeRepositoryProvider).offboard(widget.employeeId, {
        'resignType': _typeLabel(l10n, _type),
        'effectiveDate': DateFormat('yyyy-MM-dd').format(_date!),
        if (combinedReason.isNotEmpty) 'reason': combinedReason,
      });
      if (!mounted) return;
      context.appSuccess(l10n.employeeOffboardCompleted);
      context.go('/employee/${widget.employeeId}');
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    } catch (_) {
      if (!mounted) return;
      context.appError(l10n.employeeOffboardLoadFailed);
    } finally {
      if (mounted) setState(() => _submitting = false);
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
