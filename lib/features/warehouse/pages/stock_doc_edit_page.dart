// 仓库单据编辑页（新建/编辑）：主表头表单 + 明细行（货品选择/数量；盘点含实盘/盈亏）+ 保存。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../purchase/providers/master_name_provider.dart';
import '../../purchase/widgets/goods_picker_dialog.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';

class _Row {
  GoodsOption? goods;
  final qty = TextEditingController();
  final price = TextEditingController();
  final count = TextEditingController(); // 盘点实盘
}

class StockDocEditPage extends ConsumerStatefulWidget {
  const StockDocEditPage({super.key, required this.docType, this.id});
  final StockDocType docType;
  final String? id;

  @override
  ConsumerState<StockDocEditPage> createState() => _StockDocEditPageState();
}

class _StockDocEditPageState extends ConsumerState<StockDocEditPage> {
  final _billNo = TextEditingController();
  final _remark = TextEditingController();
  DateTime _billDate = DateTime.now();
  String? _warehouseId;
  String? _toWarehouseId;
  final _rows = <_Row>[];
  bool _saving = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(masterNameServiceProvider).ensureLoaded();
    if (widget.id != null) {
      try {
        final d = await ref.read(stockDocRepositoryProvider(widget.docType)).detail(widget.id!);
        final goodsIds = d.items.map((e) => e.goodsId).whereType<String>().toSet();
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        if (d.billDate != null) _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        _warehouseId = d.warehouseId;
        _toWarehouseId = d.toWarehouseId;
        for (final it in d.items) {
          _rows.add(_Row()
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(id: it.goodsId!, name: ref.read(masterNameServiceProvider).goods(it.goodsId))
            ..qty.text = it.qty?.toString() ?? ''
            ..count.text = it.countQty?.toString() ?? '');
        }
      } catch (_) {}
    }
    if (_rows.isEmpty) _rows.add(_Row());
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_billNo.text.trim().isEmpty) return context.appError('请填写单据号');
    if (_rows.every((r) => r.goods == null)) return context.appError('请至少一条明细');
    final items = <Map<String, dynamic>>[];
    for (final r in _rows) {
      if (r.goods == null) continue;
      final qty = double.tryParse(r.qty.text) ?? 0;
      final m = <String, dynamic>{'goodsId': r.goods!.id, 'qty': qty};
      final price = double.tryParse(r.price.text);
      if (price != null) {
        m['price'] = price;
        m['amountOriginal'] = qty * price;
        m['amountLocal'] = qty * price;
      }
      if (widget.docType == StockDocType.check) {
        final count = double.tryParse(r.count.text);
        if (count != null) m['countQty'] = count;
        // 盈亏 = 实盘 - 单据数量（qty 为账面）；后端按 surplus 联动库存
        m['surplusQty'] = (count ?? 0) - qty;
      }
      items.add(m);
    }
    final body = <String, dynamic>{
      'docType': widget.docType.code,
      'billNo': _billNo.text.trim(),
      'billDate': _fmt(_billDate),
      'warehouseId': _warehouseId,
      if (widget.docType == StockDocType.transfer) 'toWarehouseId': _toWarehouseId,
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      'items': items,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(stockDocRepositoryProvider(widget.docType));
      final d = widget.id == null ? await repo.create(body) : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      context.replace(RoutePath.stockDocDetail(widget.docType.code, d.id));
    } catch (_) {
      if (mounted) context.appError('保存失败');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(title: widget.id == null ? '新建${widget.docType.label}' : '编辑${widget.docType.label}'),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : UtenContentContainer(
                child: ListView(padding: const EdgeInsets.all(UtenSpacing.s12), children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      child: Column(children: [
                        TextField(controller: _billNo, decoration: const InputDecoration(labelText: '单据号 *')),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('日期'),
                          subtitle: Text(_fmt(_billDate)),
                          trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                          onTap: () async {
                            final p = await showDatePicker(
                              context: context, initialDate: _billDate,
                              firstDate: DateTime(2010), lastDate: DateTime(2100),
                            );
                            if (p != null) setState(() => _billDate = p);
                          },
                        ),
                        _dd('仓库', _warehouseId, names.warehouseEntries, (v) => setState(() => _warehouseId = v)),
                        if (widget.docType == StockDocType.transfer)
                          _dd('调入仓', _toWarehouseId, names.warehouseEntries, (v) => setState(() => _toWarehouseId = v)),
                        TextField(controller: _remark, decoration: const InputDecoration(labelText: '备注'), maxLines: 2),
                      ]),
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Row(children: [
                    Text('明细 (${_rows.length})',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    TextButton.icon(
                        onPressed: () => setState(() => _rows.add(_Row())),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('添加行')),
                  ]),
                  for (final r in _rows) _rowEditor(theme, r),
                ]),
              ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            UtenButton(type: UtenButtonType.secondary, onPressed: () => context.pop(), child: const Text('取消')),
            const SizedBox(width: 12),
            UtenButton(isLoading: _saving, icon: Icons.save_outlined, onPressed: _saving ? null : _save, child: const Text('保存')),
          ]),
        ),
      ),
    );
  }

  Widget _dd(String label, String? value, Map<String, String> entries, ValueChanged<String?> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DropdownButtonFormField<String?>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: [
          const DropdownMenuItem<String?>(child: Text('— 不选 —')),
          for (final e in entries.entries)
            DropdownMenuItem<String?>(value: e.key, child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _rowEditor(ThemeData theme, _Row r) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          Expanded(
            child: InkWell(
              onTap: () async {
                final g = await showGoodsPickerDialog(context, ref);
                if (g != null) setState(() => r.goods = g);
              },
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: '货品',
                  isDense: true,
                  suffixIcon: const Icon(Icons.search_rounded, size: 18),
                ),
                child: Text(r.goods?.name ?? '点击选择',
                    style: TextStyle(
                        color: r.goods == null ? theme.colorScheme.onSurfaceVariant : null)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: TextField(
              controller: r.qty,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: widget.docType == StockDocType.check ? '账面' : '数量', isDense: true),
            ),
          ),
          if (widget.docType == StockDocType.check)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 80,
                child: TextField(
                  controller: r.count,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: '实盘', isDense: true),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => setState(() => _rows.remove(r)),
          ),
        ]),
      ),
    );
  }
}
