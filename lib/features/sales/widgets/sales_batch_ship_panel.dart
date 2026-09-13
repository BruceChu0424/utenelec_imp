// 批量发货面板（SOP §一9，订单列表「批量发货」用）。
//
// 右滑入大面板（840，与 showSalesDocLinkPicker 统一；手机降级底部弹层）：
// 拉取该销售全部可发行（reserved>0，归属隔离后端同订单列表口径）→ 勾选 + 改本次数量
// → POST /sales/shipments/batch 同客户合并一张出货草稿。
// 返回生成的出货单张数（null=取消）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';
import '../providers/sales_completion_count_provider.dart';
import '../config/sales_doc_config.dart';
import '../../../shared/providers/list_refresh_provider.dart';

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
  final Map<String, TextEditingController> _weightCtl = {};
  String _idempotencyKey = const Uuid().v4();
  List<Map<String, dynamic>>? _retainedLines;
  String? _retainedDate;
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
    for (final c in _weightCtl.values) {
      c.dispose();
    }
    super.dispose();
  }

  static String _num(double? v) {
    if (v == null) return '—';
    return v.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
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
          _weightCtl[l.orderItemId] = TextEditingController();
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
      if (qty == null ||
          !qty.isFinite ||
          qty <= 0 ||
          !RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(raw)) {
        _toast('订单 ${l.billNo} 本次数量须大于 0');
        return;
      }
      if (qty > reserved) {
        _toast('订单 ${l.billNo} 本次数量超过可发 ${_num(reserved)}');
        return;
      }
      final weightText = _weightCtl[l.orderItemId]?.text.trim() ?? '';
      final weight = weightText.isEmpty ? null : double.tryParse(weightText);
      if (weightText.isNotEmpty && (weight == null || weight <= 0)) {
        _toast('订单 ${l.billNo} 的实际重量必须大于 0');
        return;
      }
      lines.add({'orderItemId': l.orderItemId, 'qty': qty, 'weight': ?weight});
    }
    setState(() => _busy = true);
    final today = ChinaDateTime.formatDate(ChinaDateTime.today());
    _retainedLines ??= lines;
    _retainedDate ??= today;
    try {
      final created = await ref
          .read(salesRepositoryProvider(SalesDocType.shipment))
          .batchShip(
            billDate: _retainedDate!,
            idempotencyKey: _idempotencyKey,
            lines: _retainedLines!,
          );
      if (!mounted) return;
      if (created.isEmpty) throw const FormatException('未收到开单结果');
      ref.invalidate(salesAttentionCountProvider);
      bumpListRefresh(ref, SalesDocConfig.shipment.refreshKey);
      bumpListRefresh(ref, SalesDocConfig.order.refreshKey);
      Navigator.pop(context, created.length);
    } on ApiException catch (error) {
      if (!mounted) return;
      final uncertain =
          error is NetworkException ||
          error is NetworkTimeoutException ||
          error.httpStatus == null ||
          error.httpStatus! >= 500;
      if (!uncertain) {
        _retainedLines = null;
        _retainedDate = null;
        _idempotencyKey = const Uuid().v4();
      }
      _toast(uncertain ? '请重试确认本次开单结果，当前产品和数量已保留。' : error.message);
    } catch (_) {
      if (mounted) _toast('请重试确认本次开单结果，当前产品和数量已保留。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) => context.appWarning(msg);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    final lines = _lines;
    return PopScope(
      canPop: !_busy && _retainedLines == null,
      child: Column(
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
                  onPressed: _busy || _retainedLines != null
                      ? null
                      : () => Navigator.pop(context),
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
          // 销售只确认本次产品和数量，正式出货仍需财务审核。
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s8,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                InkWell(
                  onTap: _writableCount == 0 || _busy || _retainedLines != null
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
                        onChanged:
                            _writableCount == 0 ||
                                _busy ||
                                _retainedLines != null
                            ? null
                            : (v) => _toggleAll(v ?? false),
                      ),
                      Text('全选', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                UtenButton(
                  icon: Icons.check_circle_outline,
                  onPressed: _selectedCount == 0 || _busy ? null : _confirm,
                  child: Text(
                    _busy
                        ? '开单中…'
                        : _retainedLines != null
                        ? '重试确认开单'
                        : '生成出货单($_selectedCount 行)',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
            onChanged: l.writable && !_busy && _retainedLines == null
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
              enabled:
                  checked && l.writable && !_busy && _retainedLines == null,
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
          const SizedBox(width: UtenSpacing.s8),
          SizedBox(
            width: 104,
            child: TextField(
              controller: _weightCtl[l.orderItemId],
              enabled:
                  checked && l.writable && !_busy && _retainedLines == null,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
              decoration: const UtenInputDecoration(
                InputDecoration(
                  isDense: true,
                  labelText: '实际重量',
                  hintText: '可选',
                  border: OutlineInputBorder(),
                ),
                info: '若同一产品将分成多张出货单，请先留空，生成后分别填写实际重量；系统不会猜测拆分比例。',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
