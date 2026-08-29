// 批量发货面板（SOP §一9，订单列表「批量发货」用）。
//
// 右滑入大面板（840，与 showSalesDocLinkPicker 统一；手机降级底部弹层）：
// 拉取该销售全部可发行（reserved>0，归属隔离后端同订单列表口径）→ 勾选 + 改本次数量
// → POST /sales/shipments/batch 同客户合并一张出货草稿。
// 返回生成的出货单张数（null=取消）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';

/// 弹出批量发货面板；返回生成的出货单张数（null 表示取消）。
Future<int?> showSalesBatchShipPanel(BuildContext context, WidgetRef ref) {
  const sheet = _BatchShipSheet();
  return showUtenAdaptivePanel<int>(
    context: context,
    compactHeightFactor: 0.9,
    drawerWidth: 840,
    builder: (_) => sheet,
  );
}

class _BatchShipSheet extends ConsumerStatefulWidget {
  const _BatchShipSheet();

  @override
  ConsumerState<_BatchShipSheet> createState() => _BatchShipSheetState();
}

class _BatchShipSheetState extends ConsumerState<_BatchShipSheet> {
  List<ShippableLine>? _lines;
  String? _error;
  final Set<String> _selected = {};
  final Map<String, TextEditingController> _qtyCtl = {};
  String? _warehouseId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _qtyCtl.values) {
      c.dispose();
    }
    super.dispose();
  }

  static String _num(double? v) {
    if (v == null) return '—';
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  }

  Future<void> _load() async {
    try {
      final names = ref.read(salesMasterNameServiceProvider);
      await names.ensureLoaded();
      final lines = await ref
          .read(salesRepositoryProvider(SalesDocType.order))
          .shippableLines();
      await names.loadGoodsNames(
        lines.map((e) => e.goodsId).whereType<String>().toSet(),
      );
      if (!mounted) return;
      setState(() {
        _lines = lines;
        for (final l in lines) {
          _qtyCtl[l.orderItemId] = TextEditingController(
            text: _num(l.reservedQty),
          );
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '可发行加载失败');
      context.appApiError(e, fallback: '可发行加载失败');
    }
  }

  int get _selectedCount => _selected.length;
  int get _writableCount => _lines?.where((line) => line.writable).length ?? 0;

  void _toggleAll(bool check) {
    setState(() {
      _selected.clear();
      if (check && _lines != null) {
        _selected.addAll(
          _lines!
              .where((line) => line.writable)
              .map((line) => line.orderItemId),
        );
      }
    });
  }

  Future<void> _confirm() async {
    if (_busy || _selected.isEmpty) return;
    final lines = <Map<String, dynamic>>[];
    for (final l in _lines!) {
      if (!_selected.contains(l.orderItemId)) continue;
      if (!l.writable) {
        _toast('订单 ${l.billNo} 不在你的可写数据范围内');
        return;
      }
      final raw = _qtyCtl[l.orderItemId]?.text.trim() ?? '';
      final qty = double.tryParse(raw);
      final reserved = l.reservedQty ?? 0;
      if (qty == null || qty <= 0) {
        _toast('订单 ${l.billNo} 本次数量须大于 0');
        return;
      }
      if (qty > reserved) {
        _toast('订单 ${l.billNo} 本次数量超过可发 ${_num(reserved)}');
        return;
      }
      lines.add({'orderItemId': l.orderItemId, 'qty': qty});
    }
    setState(() => _busy = true);
    final today = ChinaDateTime.formatDate(ChinaDateTime.today());
    final created = await context.guardAction(
      () => ref
          .read(salesRepositoryProvider(SalesDocType.shipment))
          .batchShip(billDate: today, warehouseId: _warehouseId, lines: lines),
      errorFallback: '批量开单失败，请稍后重试',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (created != null) Navigator.pop(context, created.length);
  }

  void _toast(String msg) => context.appWarning(msg);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    final lines = _lines;
    return Column(
      children: [
        // 头部
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              Icon(
                Icons.local_shipping_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '批量发货',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              if (lines != null)
                Text(
                  '可操作 $_writableCount / 共 ${lines.length} 行',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // 明细
        Expanded(
          child: _error != null
              ? Center(child: Text(_error!))
              : lines == null
              ? const Center(child: CircularProgressIndicator())
              : lines.isEmpty
              ? const Center(child: Text('暂无可发货的订单行(reserved > 0)'))
              : ListView.separated(
                  padding: const EdgeInsets.all(UtenSpacing.s8),
                  itemCount: lines.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _row(theme, names, lines[i]),
                ),
        ),
        const Divider(height: 1),
        // 底部：仓库 + 全选 + 提交
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              SizedBox(
                width: 220,
                child: UtenDropdownField(
                  label: '出货仓',
                  hintText: '审核前可补',
                  value: _warehouseId,
                  items: [
                    for (final e in names.warehouseEntries.entries)
                      UtenDropdownItem(value: e.key, label: e.value),
                  ],
                  onChanged: (v) => setState(() => _warehouseId = v),
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              InkWell(
                onTap: _writableCount == 0
                    ? null
                    : () => _toggleAll(_selectedCount < _writableCount),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value:
                          _writableCount > 0 &&
                          _selectedCount == _writableCount,
                      tristate: true,
                      onChanged: _writableCount == 0
                          ? null
                          : (v) => _toggleAll(v ?? false),
                    ),
                    Text('全选', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const Spacer(),
              UtenButton(
                icon: Icons.check_circle_outline,
                onPressed: _selectedCount == 0 || _busy ? null : _confirm,
                child: Text(_busy ? '开单中…' : '生成出货单($_selectedCount 行)'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, SalesMasterNameService names, ShippableLine l) {
    final checked = _selected.contains(l.orderItemId);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          Checkbox(
            value: checked,
            onChanged: l.writable
                ? (v) => setState(() {
                    if (v ?? false) {
                      _selected.add(l.orderItemId);
                    } else {
                      _selected.remove(l.orderItemId);
                    }
                  })
                : null,
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  names.client(l.clientId),
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  '${l.billNo ?? ''} · 交货 ${l.deliverDate ?? '—'}'
                  '${l.writable ? '' : ' · 只读'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: l.writable
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(names.goods(l.goodsId), style: theme.textTheme.bodySmall),
                Text(
                  [
                    names.color(l.colorId),
                    names.unit(l.unitId),
                  ].where((e) => e.isNotEmpty).join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Text(
              '可发 ${_num(l.reservedQty)}',
              textAlign: TextAlign.right,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          SizedBox(
            width: 90,
            child: TextField(
              controller: _qtyCtl[l.orderItemId],
              enabled: checked && l.writable,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '本次数量',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
