// 离职流程页（Phase 2）
// 文档：docs/03-页面/离职流程页.md

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_app_bar.dart';

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

  static const _typeLabels = {
    ResignType.voluntary: '主动辞职',
    ResignType.dismissed: '公司辞退',
    ResignType.contractEnd: '合同到期',
    ResignType.retire: '退休',
  };
  static const _checkLabels = ['收回门禁卡', '回收公司资产', '停用系统账号', '停缴社保公积金'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const UtenAppBar(title: '离职办理', showBackButton: true),
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
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                  ),
                  onPressed: _submitting ? null : _next,
                  child: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_step == 2 ? '确认办理离职' : '下一步'),
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
            title: const Text('发起离职'),
            isActive: _step >= 0,
            state: _step > 0 ? StepState.complete : StepState.indexed,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<ResignType>(
                  initialValue: _type,
                  decoration: const _Deco('离职类型'),
                  items: [
                    for (final t in ResignType.values)
                      DropdownMenuItem(value: t, child: Text(_typeLabels[t]!)),
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
                    decoration: const _Deco('离职日期'),
                    child: Text(_date == null
                        ? '选择日期'
                        : '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _reason,
                  maxLines: 2,
                  decoration: const _Deco('离职原因'),
                ),
              ],
            ),
          ),
          Step(
            title: const Text('工作交接'),
            isActive: _step >= 1,
            state: _step > 1
                ? StepState.complete
                : (_step == 1 ? StepState.indexed : StepState.disabled),
            content: TextField(
              controller: _handover,
              maxLines: 3,
              decoration: const _Deco('交接说明（文档/项目/权限）'),
            ),
          ),
          Step(
            title: const Text('回收确认'),
            isActive: _step >= 2,
            state: _step == 2 ? StepState.indexed : StepState.disabled,
            content: Column(
              children: [
                for (var i = 0; i < _checks.length; i++)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _checks[i],
                    title: Text(_checkLabels[i]),
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
    if (_step < 2) {
      if (_step == 0 && _date == null) {
        _toast('请选择离职日期');
        return;
      }
      setState(() => _step++);
      return;
    }
    if (!_checks.every((c) => c)) {
      _toast('请确认所有回收项');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认办理离职？'),
        content: const Text('该员工账号将被停用。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _submitting = true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('离职办理完成（Mock）')),
      );
      context.go('/employee/${widget.employeeId}');
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

class _Deco extends InputDecoration {
  const _Deco(String label)
      : super(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        );
}
