// 工资条生成页（Phase 2）
// 文档：docs/03-页面/工资条生成页.md · 审批流见 docs/05-架构/全局机制.md §3.4

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_app_bar.dart';
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
  final _departments = ['全员', '生产部', '质量部', '人事部', '财务部'];
  String _department = '全员';

  // 薪酬项开关
  bool _overtime = true; // 加班
  bool _bonus = false; // 绩效
  bool _social = true; // 社保
  bool _tax = true; // 个税

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const UtenAppBar(title: '工资条生成', showBackButton: true),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if (_step > 0)
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _step--),
                    child: const Text('上一步'),
                  ),
                ),
              if (_step > 0) const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submitting ? null : _next,
                  child: _submitting
                      ? const SizedBox(
                          width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_step == 3 ? '提交审核' : '下一步'),
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
            title: const Text('选择范围'),
            isActive: _step >= 0,
            state: _step > 0 ? StepState.complete : StepState.indexed,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InputDecorator(
                  decoration: const InputDecoration(
                      labelText: '工资月份', border: OutlineInputBorder(), isDense: true),
                  child: Text(_month),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _department,
                  decoration: const InputDecoration(
                      labelText: '生成范围', border: OutlineInputBorder(), isDense: true),
                  items: [for (final d in _departments) DropdownMenuItem(value: d, child: Text(d))],
                  onChanged: (v) => setState(() => _department = v!),
                ),
              ],
            ),
          ),
          Step(
            title: const Text('配置薪酬项'),
            isActive: _step >= 1,
            state: _step > 1
                ? StepState.complete
                : (_step == 1 ? StepState.indexed : StepState.disabled),
            content: Column(
              children: [
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  title: const Text('加班费 (+15%)'), value: _overtime,
                  onChanged: (v) => setState(() => _overtime = v),
                ),
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  title: const Text('绩效奖金 (+10%)'), value: _bonus,
                  onChanged: (v) => setState(() => _bonus = v),
                ),
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  title: const Text('社保公积金 (-10.5%)'), value: _social,
                  onChanged: (v) => setState(() => _social = v),
                ),
                SwitchListTile(
                  dense: true, contentPadding: EdgeInsets.zero,
                  title: const Text('个人所得税 (-5%)'), value: _tax,
                  onChanged: (v) => setState(() => _tax = v),
                ),
              ],
            ),
          ),
          Step(
            title: const Text('预览计算'),
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
            title: const Text('提交审核'),
            isActive: _step >= 3,
            state: _step == 3 ? StepState.indexed : StepState.disabled,
            content: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('提交后将进入财务审核流程，审核通过后由人事发布给员工。'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _next() async {
    if (_step < 3) {
      setState(() => _step++);
      return;
    }
    setState(() => _submitting = true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已提交审核，等待财务审核（Mock）')),
      );
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
    final empsAsync = ref.watch(employeeListProvider);
    return empsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (e, _) => Text('加载失败：$e'),
      data: (all) {
        final emps = department == '全员'
            ? all.where((e) => e.status != EmployeeStatus.resigned).toList()
            : all
                .where((e) => e.department == department && e.status != EmployeeStatus.resigned)
                .toList();
        if (emps.isEmpty) return const Text('该范围无可计算员工');

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
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('合计',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        Text('¥ ${total.toStringAsFixed(0)}  ·  ${rows.length} 人',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.primary)),
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
    final t = Theme.of(context).textTheme.bodySmall!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text('工号/姓名', style: t.copyWith(color: Colors.grey))),
          Expanded(child: Text('实发', style: t.copyWith(color: Colors.grey), textAlign: TextAlign.right)),
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text('$name（$code）', style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              '¥ ${net.toStringAsFixed(0)}',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
  }
}
