// 应收应付核销引入对话框（收款/付款编辑页"从应收应付引入"用）。
//
// 输入：direction（AR=客户应收 / AP=供应商应付）+ partyId（客户/供应商）。
// 拉该往来方未清台账（settled=false），渲染复选清单：单据号 / 立帐金额 / 已核销 / 余额 / 本次核销额
// （默认 = 余额）。确认返回所选 [AppliedArAp] 列表，编辑页据此外推明细行（appliedLedgerId +
// amountOriginal/Local）。
//
// 仿采购 doc_link_picker 的两段式（但只一段：直接列出台账行，不需要先选上游单据）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';

/// 核销回填项：台账行 id + 本次核销额（本币）+ 原币额（默认同本币）+ 单据号（展示/审计）。
class AppliedArAp {
  const AppliedArAp({
    required this.ledgerId,
    required this.appliedBillNo,
    required this.amountLocal,
    this.amountOriginal,
  });
  final String ledgerId;
  final String? appliedBillNo;
  final double amountLocal;
  final double? amountOriginal;
}

/// 弹出核销引入对话框。[direction] = 'AR'（收款）/ 'AP'（付款）。
Future<List<AppliedArAp>?> showArApPickerDialog(
  BuildContext context,
  WidgetRef ref, {
  required String direction,
  required String? partyId,
}) {
  return showDialog<List<AppliedArAp>>(
    context: context,
    builder: (_) => _ArApPickerDialog(direction: direction, partyId: partyId),
  );
}

class _ArApPickerDialog extends ConsumerStatefulWidget {
  const _ArApPickerDialog({required this.direction, required this.partyId});
  final String direction;
  final String? partyId;

  @override
  ConsumerState<_ArApPickerDialog> createState() => _ArApPickerDialogState();
}

class _ArApPickerDialogState extends ConsumerState<_ArApPickerDialog> {
  List<ArApLedgerItem>? _items;
  bool _loading = false;
  String? _error;
  final Set<int> _selected = {};
  final Map<int, TextEditingController> _amtCtrls = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final c in _amtCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.partyId == null || widget.partyId!.isEmpty) {
      setState(() {
        _items = const [];
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref
          .read(arApLedgerRepositoryProvider)
          .openItemsForParty(
              direction: widget.direction, partyId: widget.partyId!);
      if (!mounted) return;
      for (var i = 0; i < r.items.length; i++) {
        _amtCtrls[i] =
            TextEditingController(text: (r.items[i].amountBalance ?? 0).toStringAsFixed(2));
      }
      setState(() {
        _items = r.items;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载应收应付台账失败';
        _loading = false;
      });
    }
  }

  void _confirm() {
    final items = _items ?? const <ArApLedgerItem>[];
    final out = <AppliedArAp>[];
    for (final i in _selected) {
      if (i >= items.length) continue;
      final it = items[i];
      final amt = double.tryParse(_amtCtrls[i]?.text ?? '') ?? 0;
      if (amt <= 0) continue;
      out.add(AppliedArAp(
        ledgerId: it.id,
        appliedBillNo: it.billNo,
        amountLocal: amt,
        amountOriginal: amt,
      ));
    }
    Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(financeNameServiceProvider);
    final partyName = widget.direction == 'AR'
        ? names.client(widget.partyId)
        : names.supplier(widget.partyId);
    return Dialog(
      child: SizedBox(
        width: 620,
        height: 560,
        child: Column(
          children: [
            _header(theme, partyName),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            Expanded(child: _body(theme)),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            _footer(theme),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, String partyName) {
    final title = widget.direction == 'AR' ? '核销应收 · 选择应收行' : '核销应付 · 选择应付行';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(partyName,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (widget.partyId == null || widget.partyId!.isEmpty) {
      return Center(
        child: Text('请先选择${widget.direction == 'AR' ? '客户' : '供应商'}',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center),
              const SizedBox(height: UtenSpacing.s8),
              TextButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final items = _items ?? const <ArApLedgerItem>[];
    if (items.isEmpty) {
      return Center(
        child: Text('暂无未清${widget.direction == 'AR' ? '应收' : '应付'}',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final it = items[i];
        final checked = _selected.contains(i);
        return CheckboxListTile(
          value: checked,
          onChanged: (v) => setState(() {
            if (v == true) {
              _selected.add(i);
            } else {
              _selected.remove(i);
            }
          }),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(it.billNo ?? '—',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                Text('立帐：${_fmt(it.amountOriginalLocal)}',
                    style: const TextStyle(fontSize: 12)),
                Text('余额：${_fmt(it.amountBalance)}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                if ((it.billDate ?? '').isNotEmpty)
                  Text('${it.billDate}'.substring(0, 10),
                      style: const TextStyle(fontSize: 11)),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _amtCtrls[i],
                    enabled: checked,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '本次核销',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _footer(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: UtenSpacing.s8),
          FilledButton(
            onPressed: _selected.isEmpty ? null : _confirm,
            child: Text('核销 ${_selected.isEmpty ? "" : "(${_selected.length})"}'),
          ),
        ],
      ),
    );
  }

  String _fmt(double? v) => v == null ? '—' : v.toStringAsFixed(2);
}
