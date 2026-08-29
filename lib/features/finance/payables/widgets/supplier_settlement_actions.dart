import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../basic_data/models/reference_method_option.dart';
import '../../../basic_data/repositories/reference_method_repository.dart';
import '../../providers/finance_name_provider.dart';

class SupplierSettlementCreateDraft {
  const SupplierSettlementCreateDraft({
    required this.supplierId,
    required this.currencyId,
    required this.settlementMethodId,
    required this.periodStart,
  });

  final String supplierId;
  final String currencyId;
  final String settlementMethodId;
  final String periodStart;
}

class SupplierSettlementConfirmDraft {
  const SupplierSettlementConfirmDraft({this.reference, this.note});

  final String? reference;
  final String? note;
}

Future<SupplierSettlementCreateDraft?> showSupplierSettlementCreatePanel({
  required BuildContext context,
}) => showUtenAdaptivePanel<SupplierSettlementCreateDraft>(
  context: context,
  drawerWidth: 560,
  compactHeightFactor: 0.92,
  barrierDismissible: false,
  panelElevation: 16,
  builder: (_) => const _SupplierSettlementCreatePanel(),
);

Future<SupplierSettlementConfirmDraft?> showSupplierSettlementConfirmDialog({
  required BuildContext context,
  required bool supplier,
}) async {
  final reference = TextEditingController();
  final note = TextEditingController();
  try {
    return await showDialog<SupplierSettlementConfirmDraft>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(supplier ? '登记供应商确认' : '执行公司内部确认'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (supplier)
                TextField(
                  controller: reference,
                  maxLength: 500,
                  decoration: const InputDecoration(labelText: '供应商确认凭据(必填)'),
                ),
              TextField(
                controller: note,
                maxLength: 2000,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '备注'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final refValue = reference.text.trim();
              if (supplier && refValue.isEmpty) return;
              Navigator.of(dialogContext).pop(
                SupplierSettlementConfirmDraft(
                  reference: supplier ? refValue : null,
                  note: note.text.trim(),
                ),
              );
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  } finally {
    reference.dispose();
    note.dispose();
  }
}

Future<String?> showSupplierSettlementReasonDialog({
  required BuildContext context,
  required String title,
  required String label,
}) async {
  final controller = TextEditingController();
  try {
    return await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 2000,
          maxLines: 4,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isEmpty) return;
              Navigator.of(dialogContext).pop(value);
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

class _SupplierSettlementCreatePanel extends ConsumerStatefulWidget {
  const _SupplierSettlementCreatePanel();

  @override
  ConsumerState<_SupplierSettlementCreatePanel> createState() =>
      _SupplierSettlementCreatePanelState();
}

class _SupplierSettlementCreatePanelState
    extends ConsumerState<_SupplierSettlementCreatePanel> {
  String? _supplierId;
  String? _currencyId;
  String? _settlementMethodId;
  late DateTime _periodStart;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _periodStart = DateTime(today.year, today.month - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(financeNameServiceProvider).ensureLoaded();
      if (mounted) setState(() {});
    });
  }

  String _fmt(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-01';

  bool get _periodEnded {
    final today = DateTime.now();
    final periodEnd = DateTime(_periodStart.year, _periodStart.month + 1, 0);
    return !periodEnd.isAfter(DateTime(today.year, today.month, today.day));
  }

  Future<void> _pickPeriod() async {
    final today = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _periodStart,
      firstDate: DateTime(2000),
      lastDate: today,
      helpText: '选择已结束月份(提交固定为该月第一天)',
    );
    if (picked != null && mounted) {
      setState(() => _periodStart = DateTime(picked.year, picked.month));
    }
  }

  void _submit() {
    if (_supplierId == null ||
        _currencyId == null ||
        _settlementMethodId == null) {
      context.appError('请选择供应商、币种和结算方式');
      return;
    }
    if (!_periodEnded) {
      context.appError('只能为已经结束的月份生成月结批次');
      return;
    }
    Navigator.of(context).pop(
      SupplierSettlementCreateDraft(
        supplierId: _supplierId!,
        currencyId: _currencyId!,
        settlementMethodId: _settlementMethodId!,
        periodStart: _fmt(_periodStart),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final names = ref.watch(financeNameServiceProvider);
    final methods =
        ref.watch(settlementMethodOptionsProvider).valueOrNull ??
        const <ReferenceMethodOption>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('生成供应商月结批次'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          children: [
            DropdownButtonFormField<String>(
              initialValue: _supplierId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '供应商(必选)'),
              items: [
                for (final entry in names.supplierEntries.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) => setState(() => _supplierId = value),
            ),
            const SizedBox(height: UtenSpacing.s8),
            DropdownButtonFormField<String>(
              initialValue: _currencyId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '币种(必选)'),
              items: [
                for (final entry in names.currencyEntries.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) => setState(() => _currencyId = value),
            ),
            const SizedBox(height: UtenSpacing.s8),
            DropdownButtonFormField<String>(
              initialValue: _settlementMethodId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '结算方式(必选)'),
              items: [
                for (final method in methods)
                  DropdownMenuItem(
                    value: method.id,
                    child: Text('${method.code} · ${method.name}'),
                  ),
              ],
              onChanged: (value) => setState(() => _settlementMethodId = value),
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextButton.icon(
              onPressed: _pickPeriod,
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text('月结月份 ${_fmt(_periodStart).substring(0, 7)}'),
            ),
            Text(
              _periodEnded
                  ? '期间固定提交为 ${_fmt(_periodStart)}；到期日由服务端结算规则计算。'
                  : '当前月份尚未结束，不能提前冻结；到期日不可手工编辑。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _periodEnded
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: UtenButton(
            icon: Icons.ac_unit_outlined,
            onPressed: _submit,
            child: const Text('冻结月结快照'),
          ),
        ),
      ),
    );
  }
}
