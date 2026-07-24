// 工资条生成页（Phase 2）
// 文档：docs/03-页面/工资条生成页.md · 审批流见 docs/05-架构/全局机制.md §3.4
//
// 响应式：全断点套 UtenContentContainer.narrow（maxWidth 1120）——
// 外壳只收敛到 1600，表单页需自行钳窄居中

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../employee/models/employee.dart';
import '../../employee/providers/employee_providers.dart';

class PayrollGeneratePage extends ConsumerStatefulWidget {
  const PayrollGeneratePage({super.key});

  @override
  ConsumerState<PayrollGeneratePage> createState() =>
      _PayrollGeneratePageState();
}

class _PayrollGeneratePageState extends ConsumerState<PayrollGeneratePage> {
  int _step = 0;
  bool _submitting = false;

  final String _month =
      '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}';
  // Backend option codes are unchanged; labels come from l10n at build time.
  static const _departmentCodes = ['全员', '生产部', '质量部', '人事部', '财务部'];
  String _department = '全员';

  // 薪酬项开关
  bool _overtime = true; // 加班
  bool _bonus = false; // 绩效
  bool _social = true; // 社保
  bool _tax = true; // 个税

  String _departmentLabel(AppLocalizations l10n, String code) => switch (code) {
    '全员' => l10n.payrollDeptAll,
    '生产部' => l10n.payrollDeptProduction,
    '质量部' => l10n.payrollDeptQuality,
    '人事部' => l10n.payrollDeptHr,
    '财务部' => l10n.payrollDeptFinance,
    _ => code,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.payrollGenerateTitle,
        showBackButton: true,
      ),
      bottomNavigationBar: UtenBottomActionBar(
        child: Row(
          children: [
            if (_step > 0)
              Expanded(
                child: UtenButton(
                  type: UtenButtonType.ghost,
                  isExpanded: true,
                  onPressed: () => setState(() => _step--),
                  child: Text(l10n.payrollBack),
                ),
              ),
            if (_step > 0) const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: UtenButton(
                isExpanded: true,
                isLoading: _submitting,
                onPressed: _submitting ? null : _next,
                child: Text(
                  _step == 3 ? l10n.payrollSubmitButton : l10n.payrollNext,
                ),
              ),
            ),
          ],
        ),
      ),
      // narrow 容器：compact 提供 gutter，medium+ 把表单钳到 1120 居中
      body: UtenContentContainer.narrow(
        child: Stepper(
        currentStep: _step,
        onStepContinue: _next,
        onStepCancel: () => setState(() => _step > 0 ? _step-- : null),
        controlsBuilder: (context, details) => const SizedBox.shrink(),
        steps: [
          Step(
            title: Text(l10n.payrollStepScope),
            isActive: _step >= 0,
            state: _step > 0 ? StepState.complete : StepState.indexed,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: l10n.payrollFieldMonth,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  child: Text(_month),
                ),
                const SizedBox(height: UtenSpacing.s12),
                DropdownButtonFormField<String>(
                  initialValue: _department,
                  decoration: InputDecoration(
                    labelText: l10n.payrollFieldScope,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final d in _departmentCodes)
                      DropdownMenuItem(
                        value: d,
                        child: Text(_departmentLabel(l10n, d)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _department = v!),
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
                  onChanged: (v) => setState(() => _overtime = v),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.payrollItemBonus),
                  value: _bonus,
                  onChanged: (v) => setState(() => _bonus = v),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.payrollItemSocial),
                  value: _social,
                  onChanged: (v) => setState(() => _social = v),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.payrollItemTax),
                  value: _tax,
                  onChanged: (v) => setState(() => _tax = v),
                ),
              ],
            ),
          ),
          Step(
            title: Text(l10n.payrollStepPreview),
            isActive: _step >= 2,
            state: _step > 2
                ? StepState.complete
                : (_step == 2 ? StepState.indexed : StepState.disabled),
            content: _Preview(
              ref: ref,
              department: _department,
              overtime: _overtime,
              bonus: _bonus,
              social: _social,
              tax: _tax,
            ),
          ),
          Step(
            title: Text(l10n.payrollStepSubmit),
            isActive: _step >= 3,
            state: _step == 3 ? StepState.indexed : StepState.disabled,
            content: Padding(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
              child: Text(l10n.payrollSubmitNote),
            ),
          ),
        ],
        ),
      ),
    );
  }

  Future<void> _next() async {
    final l10n = AppLocalizations.of(context);
    if (_step < 3) {
      setState(() => _step++);
      return;
    }
    setState(() => _submitting = true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      setState(() => _submitting = false);
      context.appSuccess(l10n.payrollSubmitted);
      context.go('/employee');
    }
  }
}

class _Preview extends ConsumerWidget {
  const _Preview({
    required this.ref,
    required this.department,
    required this.overtime,
    required this.bonus,
    required this.social,
    required this.tax,
  });

  final WidgetRef ref;
  final String department;
  final bool overtime;
  final bool bonus;
  final bool social;
  final bool tax;

  @override
  Widget build(BuildContext context, WidgetRef r) {
    final l10n = AppLocalizations.of(context);
    final empsAsync = ref.watch(employeeListProvider);
    return empsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (e, _) => Text(l10n.payrollLoadFailed(e.toString())),
      data: (all) {
        final emps = department == '全员'
            ? all.where((e) => e.status != EmployeeStatus.resigned).toList()
            : all
                  .where(
                    (e) =>
                        e.department == department &&
                        e.status != EmployeeStatus.resigned,
                  )
                  .toList();
        if (emps.isEmpty) return Text(l10n.payrollEmptyPreview);

        final rows = <(Employee, num)>[];
        num total = 0;
        for (final e in emps) {
          final base = e.baseSalary ?? 6000;
          var net = base;
          if (overtime) net += base * 0.15;
          if (bonus) net += base * 0.10;
          if (social) net -= base * 0.105;
          if (tax) net -= base * 0.05;
          rows.add((e, net));
          total += net;
        }
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  _HeaderRow(),
                  for (final (e, net) in rows)
                    _Row(code: e.code, name: e.fullName, net: net),
                  Container(
                    color: theme.colorScheme.surfaceContainerHigh,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.payrollTableTotalLabel,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text(
                          l10n.payrollTableTotalValue(
                            total.toStringAsFixed(0),
                            rows.length,
                          ),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final t = theme.textTheme.bodySmall!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              l10n.payrollTableHeaderName,
              style: t.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              l10n.payrollTableHeaderNet,
              style: t.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.code, required this.name, required this.net});
  final String code;
  final String name;
  final num net;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              l10n.payrollTableRowName(name, code),
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Text(
              l10n.payrollTableRowNet(net.toStringAsFixed(0)),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
