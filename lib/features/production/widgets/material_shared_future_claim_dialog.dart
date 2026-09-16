import 'package:flutter/material.dart';

import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production_material_analysis.dart';

class MaterialSharedFutureClaimRow {
  const MaterialSharedFutureClaimRow({
    required this.actionGroupKey,
    required this.poolKey,
    required this.label,
    required this.unit,
    required this.needQty,
    required this.timelyQty,
    required this.lateQty,
    this.sources = const [],
  });
  final String actionGroupKey;
  final String poolKey;
  final String label;
  final String unit;
  final double needQty;
  final double timelyQty;
  final double lateQty;
  final List<SharedFutureSupplyRef> sources;
}

class MaterialSharedFutureClaimDraft {
  const MaterialSharedFutureClaimDraft({
    required this.quantities,
    required this.allowLateSupply,
  });
  final List<MaterialSharedFutureClaimQuantity> quantities;

  /// 2026-09-13 起晚到/交期未明确的公共供给默认接受，不再弹显式勾选。
  final bool allowLateSupply;
}

/// Edits only a future-supply claim. No physical receipt is implied or written.
class MaterialSharedFutureClaimDialog extends StatefulWidget {
  const MaterialSharedFutureClaimDialog({super.key, required this.rows});
  final List<MaterialSharedFutureClaimRow> rows;
  @override
  State<MaterialSharedFutureClaimDialog> createState() =>
      _MaterialSharedFutureClaimDialogState();
}

class _MaterialSharedFutureClaimDialogState
    extends State<MaterialSharedFutureClaimDialog> {
  final _controllers = <String, TextEditingController>{};
  final _selected = <String>{};
  final _sources = <String, String?>{};
  final _errors = <String, String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    final remaining = _poolLimits();
    for (final row in widget.rows) {
      final available = remaining[row.poolKey] ?? 0;
      final take = available < row.needQty ? available : row.needQty;
      remaining[row.poolKey] = available - take;
      _controllers[row.actionGroupKey] = TextEditingController(
        text: _qty(take),
      );
      _selected.add(row.actionGroupKey);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 公共池可认领量：按期 + 晚到/交期未明确（后者默认接受）。
  Map<String, double> _poolLimits() {
    final limits = <String, double>{};
    for (final row in widget.rows) {
      final total = row.timelyQty + row.lateQty;
      limits.update(
        row.poolKey,
        (old) => total > old ? total : old,
        ifAbsent: () => total,
      );
    }
    return limits;
  }

  void _confirm() {
    final errors = <String, String>{};
    final remaining = _poolLimits();
    final sourceRemaining = <String, double>{};
    final result = <MaterialSharedFutureClaimQuantity>[];
    for (final row in widget.rows) {
      if (!_selected.contains(row.actionGroupKey)) continue;
      final raw = _controllers[row.actionGroupKey]!.text.trim();
      final quantity = double.tryParse(raw);
      if (quantity == null ||
          !quantity.isFinite ||
          quantity <= 0 ||
          !RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(raw)) {
        errors[row.actionGroupKey] = '请填写大于 0、最多 4 位小数的认领数量';
        continue;
      }
      if (quantity > row.needQty + .000001) {
        errors[row.actionGroupKey] = '不能超过尚未安排供给的需求 ${_qty(row.needQty)}';
        continue;
      }
      if (quantity > (remaining[row.poolKey] ?? 0) + .000001) {
        errors[row.actionGroupKey] = '同一公共来源池的合计认领量不足，请减少数量';
        continue;
      }
      final sourceId = _sources[row.actionGroupKey];
      if (sourceId != null) {
        final source = row.sources
            .where((item) => item.sourceActionId == sourceId)
            .firstOrNull;
        final available =
            sourceRemaining[sourceId] ?? source?.availableToClaimQty ?? 0;
        if (quantity > available + .000001) {
          errors[row.actionGroupKey] = '所选来源最多可认领 ${_qty(available)}';
          continue;
        }
        sourceRemaining[sourceId] = available - quantity;
      }
      remaining[row.poolKey] = (remaining[row.poolKey] ?? 0) - quantity;
      result.add(
        MaterialSharedFutureClaimQuantity(
          actionGroupKey: row.actionGroupKey,
          qty: quantity,
          sourceActionId: sourceId,
        ),
      );
    }
    setState(() {
      _errors
        ..clear()
        ..addAll(errors);
      _error = result.isEmpty && errors.isEmpty ? '请至少选择一项公共供给' : null;
    });
    if (errors.isNotEmpty || result.isEmpty) return;
    Navigator.of(context).pop(
      MaterialSharedFutureClaimDraft(quantities: result, allowLateSupply: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('从公共在途中调入'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '认领后剩余缺口仍可继续下单；实际合格入库后才计入现货。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              for (final row in widget.rows)
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          row.label,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        subtitle: Text.rich(
                          TextSpan(
                            style: theme.textTheme.bodyMedium,
                            children: [
                              const TextSpan(text: '尚需供给 '),
                              TextSpan(
                                text: _qty(row.needQty),
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              TextSpan(text: ' ${row.unit} · 可采用 '),
                              TextSpan(
                                text: _qty(row.timelyQty + row.lateQty),
                                style: TextStyle(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                        value: _selected.contains(row.actionGroupKey),
                        onChanged: (selected) => setState(() {
                          if (selected == true) {
                            _selected.add(row.actionGroupKey);
                          } else {
                            _selected.remove(row.actionGroupKey);
                          }
                        }),
                      ),
                      TextField(
                        key: ValueKey(
                          'shared-future-claim-qty-${row.actionGroupKey}',
                        ),
                        controller: _controllers[row.actionGroupKey],
                        enabled: _selected.contains(row.actionGroupKey),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: UtenInputDecoration(
                          InputDecoration(
                            labelText: '本次认领数量',
                            suffixText: row.unit,
                            // 全站口径：错误提示走 UtenFieldMessage，留在字段内，
                            // 不用裸 errorText（见字段消息来源契约测试）。
                            error: _errors[row.actionGroupKey] == null
                                ? null
                                : UtenFieldMessage.error(
                                    _errors[row.actionGroupKey]!,
                                  ),
                          ),
                          info: '可只认领部分数量；同物料路径共享来源余量，不能重复认领。',
                        ),
                      ),
                      if (row.sources.any(
                        (source) => source.sourceActionId != null,
                      )) ...[
                        const SizedBox(height: UtenSpacing.s8),
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _sources[row.actionGroupKey] ?? '',
                          decoration: const UtenInputDecoration(
                            InputDecoration(labelText: '指定来源（可选）'),
                          ),
                          items: [
                            const DropdownMenuItem<String>(
                              value: '',
                              child: Text('按供给到期顺序采用'),
                            ),
                            for (final source in {
                              for (final source in row.sources)
                                if (source.sourceActionId != null)
                                  source.sourceActionId!: source,
                            }.values)
                              DropdownMenuItem(
                                value: source.sourceActionId,
                                child: Text(
                                  '${source.documentNo ?? '来源单号受权限保护'} · ${source.expectedDate ?? '交期待确认'}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: !_selected.contains(row.actionGroupKey)
                              ? null
                              : (value) => setState(
                                  () => _sources[row.actionGroupKey] =
                                      value?.isEmpty == true ? null : value,
                                ),
                        ),
                      ],
                    ],
                  ),
                ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('返回'),
        ),
        FilledButton.icon(
          key: const Key('material-table-confirm-claim-shared'),
          onPressed: _confirm,
          icon: const Icon(Icons.call_received_rounded),
          label: const Text('确认采用'),
        ),
      ],
    );
  }
}

String _qty(double quantity) =>
    quantity.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
