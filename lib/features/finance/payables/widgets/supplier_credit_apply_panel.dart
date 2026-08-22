import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../models/finance_payable.dart';
import '../repositories/finance_payables_repository.dart';

BigInt? _scaledDecimal(String? raw, {int scale = 4}) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(value);
  if (match == null) return null;
  final negative = match.group(1) == '-';
  var fraction = match.group(3) ?? '';
  if (fraction.length > scale) {
    if (fraction.substring(scale).contains(RegExp('[1-9]'))) return null;
    fraction = fraction.substring(0, scale);
  }
  fraction = fraction.padRight(scale, '0');
  final factor = BigInt.from(10).pow(scale);
  final units =
      BigInt.parse(match.group(2)!) * factor +
      (fraction.isEmpty ? BigInt.zero : BigInt.parse(fraction));
  return negative ? -units : units;
}

bool supplierOffsetTargetCompatible(
  FinancePayableItem source,
  FinancePayableItem target,
) {
  if (source.openItemKind != 'CREDIT' &&
      source.openItemKind != 'CLAIM_CREDIT') {
    return false;
  }
  if (target.openItemKind != 'PAYABLE' || target.status == 'SETTLED') {
    return false;
  }
  if (source.supplierId == null || source.supplierId != target.supplierId) {
    return false;
  }
  if (source.currencyId == null || source.currencyId != target.currencyId) {
    return false;
  }
  final sourceRate = _scaledDecimal(source.bookingRate, scale: 6);
  final targetRate = _scaledDecimal(target.bookingRate, scale: 6);
  if (sourceRate == null || targetRate == null || sourceRate != targetRate) {
    return false;
  }
  final outstanding = _scaledDecimal(target.outstandingOriginal);
  return outstanding != null && outstanding > BigInt.zero;
}

class SupplierCreditApplyDraft {
  const SupplierCreditApplyDraft({
    required this.effectiveDate,
    required this.reason,
    required this.targets,
  });

  final String effectiveDate;
  final String reason;
  final List<FinancePayableOffsetTarget> targets;
}

Future<SupplierCreditApplyDraft?> showSupplierCreditApplyPanel({
  required BuildContext context,
  required FinancePayableItem source,
}) => showUtenAdaptivePanel<SupplierCreditApplyDraft>(
  context: context,
  drawerWidth: 760,
  compactHeightFactor: 0.94,
  barrierDismissible: false,
  panelElevation: 16,
  builder: (_) => _SupplierCreditApplyPanel(source: source),
);

class _SupplierCreditApplyPanel extends ConsumerStatefulWidget {
  const _SupplierCreditApplyPanel({required this.source});

  final FinancePayableItem source;

  @override
  ConsumerState<_SupplierCreditApplyPanel> createState() =>
      _SupplierCreditApplyPanelState();
}

class _SupplierCreditApplyPanelState
    extends ConsumerState<_SupplierCreditApplyPanel> {
  final _reason = TextEditingController();
  final Map<String, TextEditingController> _amounts = {};
  final Set<String> _selected = {};
  List<FinancePayableItem> _targets = const [];
  DateTime _effectiveDate = DateTime.now();
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _reason.dispose();
    for (final controller in _amounts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _fmt(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    final supplierId = widget.source.supplierId;
    if (supplierId == null) {
      setState(() {
        _loading = false;
        _error = '贷项缺少供应商身份，不能应用';
      });
      return;
    }
    try {
      final result = await ref
          .read(financePayablesRepositoryProvider)
          .list(
            size: 200,
            filter: FinancePayablesFilter(supplierId: supplierId),
          );
      if (!mounted) return;
      setState(() {
        _targets = result.items
            .where(
              (target) => supplierOffsetTargetCompatible(widget.source, target),
            )
            .toList(growable: false);
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载可抵销正应付失败';
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _effectiveDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _effectiveDate = picked);
  }

  void _confirm() {
    final reason = _reason.text.trim();
    if (reason.isEmpty) {
      context.appError('请填写贷项应用原因');
      return;
    }
    final sourceCapacity = _scaledDecimal(
      widget.source.outstandingOriginal,
    )?.abs();
    if (sourceCapacity == null || sourceCapacity == BigInt.zero) {
      context.appError('贷项可用原币余额无效，请刷新后重试');
      return;
    }
    var total = BigInt.zero;
    final targets = <FinancePayableOffsetTarget>[];
    for (final target in _targets.where(
      (item) => _selected.contains(item.id),
    )) {
      final raw = _amounts[target.id]?.text.trim() ?? '';
      final units = _scaledDecimal(raw);
      final capacity = _scaledDecimal(target.outstandingOriginal);
      if (units == null || units <= BigInt.zero) {
        context.appError('每笔目标原币金额必须大于 0');
        return;
      }
      if (capacity == null || units > capacity) {
        context.appError('${target.sourceDocNo ?? '目标应付'} 的应用金额超过未付余额');
        return;
      }
      total += units;
      targets.add(
        FinancePayableOffsetTarget(payableId: target.id, amountOriginal: raw),
      );
    }
    if (targets.isEmpty) {
      context.appError('请至少选择一笔同供应商、同币种、同汇率的正应付');
      return;
    }
    if (total > sourceCapacity) {
      context.appError('应用总额超过贷项可用原币余额');
      return;
    }
    Navigator.of(context).pop(
      SupplierCreditApplyDraft(
        effectiveDate: _fmt(_effectiveDate),
        reason: reason,
        targets: targets,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    return Scaffold(
      appBar: AppBar(
        title: Text('应用${source.openItemKindLabel}'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${source.sourceDocNo ?? '—'} · ${source.supplierName ?? '—'}',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '可用余额 ${source.currencyCode ?? ''} ${source.outstandingOriginal ?? '—'}'
                    ' · 汇率 ${source.bookingRate ?? '—'}',
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  TextButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.event_outlined),
                    label: Text('发生日 ${_fmt(_effectiveDate)}'),
                  ),
                  TextField(
                    controller: _reason,
                    maxLength: 2000,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: '应用原因（必填）'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildTargets()),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: UtenButton(
            icon: Icons.link_rounded,
            onPressed: _loading ? null : _confirm,
            child: Text('确认应用 (${_selected.length})'),
          ),
        ),
      ),
    );
  }

  Widget _buildTargets() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) return Center(child: Text(_error!));
    if (_targets.isEmpty) {
      return const Center(child: Text('暂无同供应商、同币种、同立账汇率的正应付'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      itemCount: _targets.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final target = _targets[index];
        final selected = _selected.contains(target.id);
        final controller = _amounts.putIfAbsent(
          target.id,
          () => TextEditingController(),
        );
        return CheckboxListTile(
          value: selected,
          onChanged: (value) => setState(() {
            if (value == true) {
              _selected.add(target.id);
              if (controller.text.isEmpty) {
                controller.text = target.outstandingOriginal ?? '';
              }
            } else {
              _selected.remove(target.id);
            }
          }),
          title: Text(
            '${target.sourceDocNo ?? '—'} · ${target.sourceTypeLabel}',
          ),
          subtitle: Text(
            '未付 ${target.currencyCode ?? ''} ${target.outstandingOriginal ?? '—'}'
            ' · 汇率 ${target.bookingRate ?? '—'}',
          ),
          secondary: SizedBox(
            width: 150,
            child: TextField(
              controller: controller,
              enabled: selected,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                isDense: true,
                labelText: '应用原币金额',
              ),
            ),
          ),
        );
      },
    );
  }
}
