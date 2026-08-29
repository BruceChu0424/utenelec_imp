import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/payroll_batch.dart';
import '../models/payroll_slip.dart';
import '../providers/payroll_providers.dart';

class PayrollGeneratePage extends ConsumerStatefulWidget {
  const PayrollGeneratePage({super.key});

  @override
  ConsumerState<PayrollGeneratePage> createState() =>
      _PayrollGeneratePageState();
}

class _PayrollGeneratePageState extends ConsumerState<PayrollGeneratePage> {
  int _step = 0;
  bool _submitting = false;
  String? _operationError;
  PayrollBatch? _draftBatch;

  int _year = ChinaDateTime.today().year;
  int _month = ChinaDateTime.today().month;
  String _departmentId = '';

  bool _overtime = true;
  bool _bonus = false;
  bool _social = true;
  bool _tax = true;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final departments = ref.watch(payrollDepartmentOptionsProvider);

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.payrollGenerateTitle,
        showBackButton: true,
      ),
      bottomNavigationBar: UtenBottomActionBar(
        child: Row(
          children: [
            if (_step > 0 && _draftBatch == null)
              Expanded(
                child: UtenButton(
                  type: UtenButtonType.ghost,
                  isExpanded: true,
                  onPressed: _submitting ? null : () => setState(() => _step--),
                  child: Text(l10n.payrollBack),
                ),
              ),
            if (_step > 0 && _draftBatch == null)
              const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: UtenButton(
                isExpanded: true,
                isLoading: _submitting,
                onPressed: _submitting ? null : _next,
                child: Text(
                  _step == 3
                      ? l10n.payrollSubmitButton
                      : (_step == 1
                            ? l10n.payrollStepPreview
                            : l10n.payrollNext),
                ),
              ),
            ),
          ],
        ),
      ),
      body: UtenContentContainer.narrow(
        child: Stepper(
          currentStep: _step,
          onStepContinue: _submitting ? null : _next,
          onStepCancel: _step > 0 && _draftBatch == null && !_submitting
              ? () => setState(() => _step--)
              : null,
          controlsBuilder: (context, details) => const SizedBox.shrink(),
          steps: [
            Step(
              title: Text(l10n.payrollStepScope),
              isActive: _step >= 0,
              state: _step > 0 ? StepState.complete : StepState.indexed,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _year,
                          decoration: const InputDecoration(
                            labelText: '工资年份',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            for (
                              var year = ChinaDateTime.today().year + 1;
                              year >= ChinaDateTime.today().year - 20;
                              year--
                            )
                              DropdownMenuItem(
                                value: year,
                                child: Text('$year 年'),
                              ),
                          ],
                          onChanged: _draftBatch == null
                              ? (value) {
                                  if (value != null) {
                                    setState(() => _year = value);
                                  }
                                }
                              : null,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: _month,
                          decoration: InputDecoration(
                            labelText: l10n.payrollFieldMonth,
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            for (var month = 1; month <= 12; month++)
                              DropdownMenuItem(
                                value: month,
                                child: Text('$month 月'),
                              ),
                          ],
                          onChanged: _draftBatch == null
                              ? (value) {
                                  if (value != null) {
                                    setState(() => _month = value);
                                  }
                                }
                              : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  DropdownButtonFormField<String>(
                    initialValue: _departmentId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.payrollFieldScope,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(l10n.payrollDeptAll),
                      ),
                      for (final department
                          in departments.valueOrNull ??
                              const <PayrollDepartmentOption>[])
                        DropdownMenuItem(
                          value: department.id,
                          child: Text(department.path),
                        ),
                    ],
                    onChanged: _draftBatch == null
                        ? (value) => setState(() => _departmentId = value ?? '')
                        : null,
                  ),
                  if (departments.isLoading)
                    const Padding(
                      padding: EdgeInsets.only(top: UtenSpacing.s8),
                      child: LinearProgressIndicator(),
                    ),
                  if (departments.hasError)
                    Padding(
                      padding: const EdgeInsets.only(top: UtenSpacing.s8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '部门加载失败，仍可选择全员范围。',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => ref.invalidate(
                              payrollDepartmentOptionsProvider,
                            ),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Step(
              title: Text(l10n.payrollStepItems),
              isActive: _step >= 1,
              state: _step > 1
                  ? StepState.complete
                  : (_step == 1 ? StepState.indexed : StepState.disabled),
              content: Column(
                children: [
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.payrollItemOvertime),
                    value: _overtime,
                    onChanged: _draftBatch == null
                        ? (value) => setState(() => _overtime = value)
                        : null,
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.payrollItemBonus),
                    value: _bonus,
                    onChanged: _draftBatch == null
                        ? (value) => setState(() => _bonus = value)
                        : null,
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.payrollItemSocial),
                    value: _social,
                    onChanged: _draftBatch == null
                        ? (value) => setState(() => _social = value)
                        : null,
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.payrollItemTax),
                    value: _tax,
                    onChanged: _draftBatch == null
                        ? (value) => setState(() => _tax = value)
                        : null,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    '工资、社保与个税全部由服务器规则计算，前端不会预估或修正金额。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (_operationError != null) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      _operationError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Step(
              title: Text(l10n.payrollStepPreview),
              isActive: _step >= 2,
              state: _step > 2
                  ? StepState.complete
                  : (_step == 2 ? StepState.indexed : StepState.disabled),
              content: _draftBatch == null
                  ? const Text('点击下一步后，由服务器生成工资批次。')
                  : _ServerBatchPreview(batch: _draftBatch!),
            ),
            Step(
              title: Text(l10n.payrollStepSubmit),
              isActive: _step >= 3,
              state: _step == 3 ? StepState.indexed : StepState.disabled,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.payrollSubmitNote),
                  if (_draftBatch != null) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      '服务器草稿批次：${_draftBatch!.id}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (_operationError != null) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      _operationError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _next() async {
    if (_step == 0) {
      setState(() => _step = 1);
      return;
    }
    if (_step == 1) {
      await _generateDraft();
      return;
    }
    if (_step == 2) {
      if (_draftBatch?.slips.isEmpty ?? true) {
        context.appError('服务器未返回工资明细，不能提交空批次');
        return;
      }
      setState(() => _step = 3);
      return;
    }
    await _submitDraft();
  }

  Future<void> _generateDraft() async {
    setState(() {
      _submitting = true;
      _operationError = null;
    });
    try {
      final batch = await createPayrollBatch(
        ref,
        PayrollBatchCreateInput(
          year: _year,
          month: _month,
          departmentId: _departmentId.isEmpty ? null : _departmentId,
          includeOvertime: _overtime,
          includeBonus: _bonus,
          includeSocialInsurance: _social,
          includeTax: _tax,
        ),
      );
      if (batch.status != PayrollBatchStatus.draft ||
          batch.year != _year ||
          batch.month != _month) {
        throw const FormatException('服务器返回的工资草稿与所选期间或状态不一致');
      }
      if (!mounted) return;
      setState(() {
        _draftBatch = batch;
        _step = 2;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _operationError = '生成失败：$error');
      context.appError(_operationError!);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitDraft() async {
    final batch = _draftBatch;
    if (batch == null) return;
    setState(() {
      _submitting = true;
      _operationError = null;
    });
    try {
      await submitPayrollBatch(ref, batch.id);
      if (!mounted) return;
      context.appSuccess('工资批次已提交审核');
      context.go('/employee');
    } catch (error) {
      if (!mounted) return;
      setState(() => _operationError = '提交失败：$error');
      context.appError(_operationError!);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _ServerBatchPreview extends StatelessWidget {
  const _ServerBatchPreview({required this.batch});

  final PayrollBatch batch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visibleSlips = batch.slips.take(20).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenCard(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
          child: Column(
            children: [
              UtenInfoRow(label: '工资月份', value: batch.periodLabel),
              UtenInfoRow(label: '生成范围', value: batch.scopeLabel),
              UtenInfoRow(
                label: '批次状态',
                value: null,
                valueWidget: UtenStatusBadge(
                  label: batch.status.label,
                  type: UtenStatusBadgeType.neutral,
                ),
              ),
              UtenInfoRow(label: '员工人数', value: '${batch.headcount} 人'),
              UtenInfoRow(
                label: '应发合计',
                value: '¥ ${batch.grossIncome.toStringAsFixed(2)}',
              ),
              UtenInfoRow(
                label: '扣除合计',
                value: '¥ ${batch.totalDeduction.toStringAsFixed(2)}',
              ),
              UtenInfoRow(
                label: '实发合计',
                value: '¥ ${batch.netIncome.toStringAsFixed(2)}',
                isImportant: true,
                showDivider: false,
              ),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        if (visibleSlips.isEmpty)
          Text(
            '服务器未返回员工工资明细，请不要提交空批次。',
            style: TextStyle(color: theme.colorScheme.error),
          )
        else
          UtenCard(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
            child: Column(
              children: [
                for (var index = 0; index < visibleSlips.length; index++) ...[
                  _SlipPreviewRow(slip: visibleSlips[index]),
                  if (index != visibleSlips.length - 1)
                    Divider(height: 1, color: theme.colorScheme.outlineVariant),
                ],
                if (batch.slips.length > visibleSlips.length)
                  Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    child: Text(
                      '仅预览前 ${visibleSlips.length} 人，完整明细请在审核页查看。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '以上金额均来自服务器计算。草稿已经保存，提交后进入审核流程。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SlipPreviewRow extends StatelessWidget {
  const _SlipPreviewRow({required this.slip});

  final PayrollSlip slip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      title: Text(
        '${slip.employeeName}(${slip.employeeCode})',
        style: theme.textTheme.bodyMedium,
      ),
      trailing: Text(
        '¥ ${slip.netIncome.toStringAsFixed(2)}',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: UtenColors.primary,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
