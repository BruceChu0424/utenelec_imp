// 采购单据编辑页（新建/编辑，全页路由）：主表头表单 + 明细行编辑器（货品选择/数量/单价→金额自动）+ 保存。
//
// 差异由 config 驱动（供应商/币种/仓库下拉按 has* 显隐）。人员/日期类字段首版留空（迁移数据多空）。
// 保存组装 body 调 create/update，成功后跳详情。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/purchase_repository.dart';
import '../widgets/goods_picker_dialog.dart';

class PurchaseDocEditPage extends ConsumerStatefulWidget {
  const PurchaseDocEditPage({super.key, required this.docType, this.id});
  final PurchaseDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<PurchaseDocEditPage> createState() => _PurchaseDocEditPageState();
}

class _ItemRow {
  GoodsOption? goods;
  final qty = TextEditingController();
  final price = TextEditingController();
}

class _PurchaseDocEditPageState extends ConsumerState<PurchaseDocEditPage> {
  PurchaseDocConfig get _cfg => PurchaseDocConfig.by(widget.docType);
  final _billNo = TextEditingController();
  final _remark = TextEditingController();
  final _rate = TextEditingController(text: '1');
  DateTime _billDate = DateTime.now();
  String? _supplierId;
  String? _warehouseId;
  String? _currencyId;
  final _items = <_ItemRow>[];
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
        final d = await ref
            .read(purchaseRepositoryProvider(widget.docType))
            .detail(widget.id!);
        final goodsIds = d.items.map((e) => e.goodsId).whereType<String>().toSet();
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        if (d.billDate != null) _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        _supplierId = d.supplierId;
        _warehouseId = d.warehouseId;
        _currencyId = d.currencyId;
        _rate.text = d.exchangeRate?.toString() ?? '1';
        for (final it in d.items) {
          final row = _ItemRow()
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(id: it.goodsId!, name: ref.read(masterNameServiceProvider).goods(it.goodsId))
            ..qty.text = it.qty?.toString() ?? ''
            ..price.text = it.price?.toString() ?? '';
          _items.add(row);
        }
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {}
    }
    if (_items.isEmpty) _items.add(_ItemRow());
    if (mounted) setState(() => _loading = false);
  }

  double get _total => _items.fold<double>(
      0, (s, r) => s + (double.tryParse(r.qty.text) ?? 0) * (double.tryParse(r.price.text) ?? 0));

  Future<void> _pickGoods(_ItemRow row) async {
    final g = await showGoodsPickerDialog(context, ref);
    if (g != null) setState(() => row.goods = g);
  }

  Future<void> _save() async {
    if (_billNo.text.trim().isEmpty) {
      context.appError('请填写单据号');
      return;
    }
    if (_items.isEmpty || _items.every((r) => r.goods == null)) {
      context.appError('请至少添加一条明细');
      return;
    }
    if (_cfg.supplierRequired && _supplierId == null) {
      context.appError('请选择供应商');
      return;
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in _items) {
      if (r.goods == null) continue;
      final qty = double.tryParse(r.qty.text) ?? 0;
      final price = double.tryParse(r.price.text);
      itemsBody.add({
        'goodsId': r.goods!.id,
        'qty': qty,
        if (price != null) 'price': price,
        if (price != null) 'amountOriginal': qty * price,
        if (price != null) 'amountLocal': qty * price,
      });
    }
    final body = <String, dynamic>{
      'billNo': _billNo.text.trim(),
      'billDate': _fmt(_billDate),
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      if (_cfg.hasSupplier && _supplierId != null) 'supplierId': _supplierId,
      if (_warehouseId != null) 'warehouseId': _warehouseId,
      if (_cfg.hasCurrency && _currencyId != null) 'currencyId': _currencyId,
      if (_cfg.hasCurrency) 'exchangeRate': double.tryParse(_rate.text) ?? 1,
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(purchaseRepositoryProvider(widget.docType));
      final d = widget.id == null
          ? await repo.create(body)
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      context.replace(RoutePath.purchaseDocDetail(_cfg.type.pathSegment, d.id));
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
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
      appBar: UtenAppBar(title: widget.id == null ? '新建${_cfg.label}' : '编辑${_cfg.label}'),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : UtenContentContainer(
                child: ListView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        child: Column(children: [
                          TextField(
                            controller: _billNo,
                            decoration: const InputDecoration(labelText: '单据号 *'),
                          ),
                          const SizedBox(height: UtenSpacing.s8),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('单据日期'),
                            subtitle: Text(_fmt(_billDate)),
                            trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                            onTap: () async {
                              final p = await showDatePicker(
                                context: context,
                                initialDate: _billDate,
                                firstDate: DateTime(2010),
                                lastDate: DateTime(2100),
                              );
                              if (p != null) setState(() => _billDate = p);
                            },
                          ),
                          if (_cfg.hasSupplier)
                            _dropdown('供应商', _supplierId, names.supplierEntries,
                                (v) => setState(() => _supplierId = v),
                                required: _cfg.supplierRequired),
                          _dropdown('仓库', _warehouseId, names.warehouseEntries,
                              (v) => setState(() => _warehouseId = v)),
                          if (_cfg.hasCurrency) ...[
                            _dropdown('币种', _currencyId, names.currencyEntries,
                                (v) => setState(() => _currencyId = v)),
                            TextField(
                              controller: _rate,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(labelText: '汇率'),
                            ),
                          ],
                          TextField(
                            controller: _remark,
                            decoration: const InputDecoration(labelText: '备注'),
                            maxLines: 2,
                          ),
                        ]),
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    Row(
                      children: [
                        Text('明细 (${_items.length})',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => setState(() => _items.add(_ItemRow())),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('添加行'),
                        ),
                      ],
                    ),
                    for (var i = 0; i < _items.length; i++) _itemEditor(theme, _items[i], i),
                  ],
                ),
              ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('合计 ¥${_total.toStringAsFixed(2)}',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: UtenSpacing.s16),
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: () => context.pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: UtenSpacing.s12),
              UtenButton(
                isLoading: _saving,
                icon: Icons.save_outlined,
                onPressed: _saving ? null : _save,
                child: Text(widget.id == null ? '存草稿' : '保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dropdown(String label, String? value, Map<String, String> entries,
      ValueChanged<String?> onChanged,
      {bool required = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: DropdownButtonFormField<String?>(
        initialValue: value,
        decoration: InputDecoration(labelText: required ? '$label *' : label),
        items: [
          const DropdownMenuItem<String?>(child: Text('— 不选 —')),
          for (final e in entries.entries)
            DropdownMenuItem<String?>(
              value: e.key,
              child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _itemEditor(ThemeData theme, _ItemRow row, int i) {
    final amount =
        (double.tryParse(row.qty.text) ?? 0) * (double.tryParse(row.price.text) ?? 0);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: InkWell(
                onTap: () => _pickGoods(row),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '货品',
                    isDense: true,
                    suffixIcon: Icon(Icons.search_rounded, size: 18),
                  ),
                  child: Text(row.goods?.name ?? '点击选择',
                      style: TextStyle(
                          color: row.goods == null
                              ? theme.colorScheme.onSurfaceVariant
                              : null)),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => setState(() => _items.remove(row)),
            ),
          ]),
          const SizedBox(height: UtenSpacing.s8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: row.qty,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '数量', isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: TextField(
                controller: row.price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: '单价', isDense: true),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            SizedBox(
              width: 90,
              child: Text('¥${amount.toStringAsFixed(2)}',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
          ]),
        ]),
      ),
    );
  }
}
