// 生产计划单编辑页（新建/编辑，全页路由）：主表头表单 + 明细行编辑器。
//
// 与采购编辑页同构（MasterNameService 解析货品/颜色/单位；showGoodsPickerDialog 选货品）。
// 生产计划特点：
//   - 无币种/供应商/金额（数量驱动，非金额驱动；成本在 BOM 展开表）
//   - 车间/生产工/跟单员为文本字段（legacy 字符串，department_id/worker_id 留空，未来回填）
//   - 明细行核心字段：productNo（业务编号，必填）+ goodsId（必填）+ qty 排产量（必填）+
//     oqty 订货量 + color/unit + salesOrderNo（关联销售订单文本）+ remark
//   - 12 数量族中其余 10 个（lqty/iqty/...）本期不编辑（触发器/下游回写，归未来模块）
//
// 保存组装 PlanSaveRequest body 调 create/update，成功后跳详情。
// 仅草稿可编辑（后端校验，前端不再重复判断；已审单据走详情页红冲）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../purchase/providers/master_name_provider.dart';
import '../../purchase/widgets/goods_picker_dialog.dart';
import '../repositories/production_repository.dart';

class ProductionPlanEditPage extends ConsumerStatefulWidget {
  const ProductionPlanEditPage({super.key, this.id});
  final String? id; // null=新建

  @override
  ConsumerState<ProductionPlanEditPage> createState() =>
      _ProductionPlanEditPageState();
}

class _ItemRow {
  _ItemRow();
  final productNo = TextEditingController();
  final qty = TextEditingController();
  final oqty = TextEditingController();
  final salesOrderNo = TextEditingController();
  final remark = TextEditingController();
  GoodsOption? goods;
  String? colorId;
  String? unitId;

  void dispose() {
    productNo.dispose();
    qty.dispose();
    oqty.dispose();
    salesOrderNo.dispose();
    remark.dispose();
  }
}

class _ProductionPlanEditPageState
    extends ConsumerState<ProductionPlanEditPage> {
  final _billNo = TextEditingController();
  final _workshop = TextEditingController(); // workshopName 文本
  final _worker = TextEditingController(); // workerName 文本
  final _seller = TextEditingController(); // sellerName 文本
  final _sourceDocNo = TextEditingController();
  final _remark = TextEditingController();
  DateTime _billDate = DateTime.now();
  DateTime? _deliveryDate;

  final _items = <_ItemRow>[];
  bool _saving = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _billNo.dispose();
    _workshop.dispose();
    _worker.dispose();
    _seller.dispose();
    _sourceDocNo.dispose();
    _remark.dispose();
    for (final r in _items) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _loading = true);
    await ref.read(masterNameServiceProvider).ensureLoaded();
    if (widget.id != null) {
      try {
        final d = await ref
            .read(productionPlanRepositoryProvider)
            .detail(widget.id!);
        final goodsIds =
            d.items.map((e) => e.goodsId).whereType<String>().toSet();
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _workshop.text = d.workshopName ?? '';
        _worker.text = d.workerName ?? '';
        _seller.text = d.sellerName ?? '';
        _sourceDocNo.text = d.sourceDocNo ?? '';
        _remark.text = d.remark ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _deliveryDate = _parseDate(d.deliveryDate);
        for (final it in d.items) {
          final row = _ItemRow()
            ..productNo.text = it.productNo ?? ''
            ..qty.text = it.qty?.toString() ?? ''
            ..oqty.text = it.oqty?.toString() ?? ''
            ..salesOrderNo.text = it.salesOrderNo ?? ''
            ..remark.text = it.remark ?? ''
            ..colorId = it.colorId
            ..unitId = it.unitId
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref.read(masterNameServiceProvider).goods(it.goodsId));
          _items.add(row);
        }
      } on ApiException catch (e) {
        if (mounted) context.appError(e.message);
      } catch (_) {
        // 静默降级
      }
    }
    if (_items.isEmpty) _items.add(_ItemRow());
    if (mounted) setState(() => _loading = false);
  }

  DateTime? _parseDate(String? s) =>
      (s == null || s.isEmpty) ? null : DateTime.tryParse(s);

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  double get _qtyTotal => _items.fold<double>(
      0, (s, r) => s + (double.tryParse(r.qty.text) ?? 0));

  Future<void> _pickGoods(_ItemRow row) async {
    final g = await showGoodsPickerDialog(context, ref);
    if (g != null) setState(() => row.goods = g);
  }

  Future<void> _pickDate({
    required DateTime? current,
    required ValueChanged<DateTime> onPicked,
  }) async {
    final p = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2010),
      lastDate: DateTime(2100),
    );
    if (p != null) setState(() => onPicked(p));
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
    for (var i = 0; i < _items.length; i++) {
      final r = _items[i];
      if (r.goods == null) continue;
      if (r.productNo.text.trim().isEmpty) {
        context.appError('第 ${i + 1} 行缺少产品编号');
        return;
      }
      if (double.tryParse(r.qty.text) == null) {
        context.appError('第 ${i + 1} 行排产量无效');
        return;
      }
    }
    final itemsBody = <Map<String, dynamic>>[];
    for (final r in _items) {
      if (r.goods == null) continue;
      itemsBody.add({
        'productNo': r.productNo.text.trim(),
        'goodsId': r.goods!.id,
        'qty': double.tryParse(r.qty.text) ?? 0,
        if (double.tryParse(r.oqty.text) != null) 'oqty': double.tryParse(r.oqty.text),
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
        if (r.salesOrderNo.text.trim().isNotEmpty)
          'salesOrderNo': r.salesOrderNo.text.trim(),
        if (r.remark.text.trim().isNotEmpty) 'remark': r.remark.text.trim(),
      });
    }
    final body = <String, dynamic>{
      'billNo': _billNo.text.trim(),
      'billDate': _fmt(_billDate),
      if (_deliveryDate != null) 'deliveryDate': _fmt(_deliveryDate!),
      if (_workshop.text.trim().isNotEmpty)
        'workshopName': _workshop.text.trim(),
      if (_worker.text.trim().isNotEmpty) 'workerName': _worker.text.trim(),
      if (_seller.text.trim().isNotEmpty) 'sellerName': _seller.text.trim(),
      if (_sourceDocNo.text.trim().isNotEmpty)
        'sourceDocNo': _sourceDocNo.text.trim(),
      if (_remark.text.trim().isNotEmpty) 'remark': _remark.text.trim(),
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(productionPlanRepositoryProvider);
      final d = widget.id == null
          ? await repo.create(body)
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      context.replace('/production/plans/${d.id}');
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _dropdown(String label, String? value, Map<String, String> entries,
      ValueChanged<String?> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: DropdownButtonFormField<String?>(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: [
          const DropdownMenuItem<String?>(child: Text('— 不选 —')),
          for (final e in entries.entries)
            DropdownMenuItem<String?>(
              value: e.key,
              child: Text(e.value,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _itemEditor(ThemeData theme, _ItemRow row, int i) {
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
              onPressed: () => setState(() {
                _items.remove(row);
                row.dispose();
              }),
            ),
          ]),
          const SizedBox(height: UtenSpacing.s8),
          TextField(
            controller: row.productNo,
            decoration: const InputDecoration(
                labelText: '产品编号 *', isDense: true),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: row.qty,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: '排产量 *', isDense: true),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: TextField(
                controller: row.oqty,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: '订货量', isDense: true),
              ),
            ),
          ]),
          Row(children: [
            Expanded(
              child: _dropdown(
                  '颜色', row.colorId, ref.read(masterNameServiceProvider).colorEntries,
                  (v) => setState(() => row.colorId = v)),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: _dropdown(
                  '单位', row.unitId, ref.read(masterNameServiceProvider).unitEntries,
                  (v) => setState(() => row.unitId = v)),
            ),
          ]),
          TextField(
            controller: row.salesOrderNo,
            decoration: const InputDecoration(
                labelText: '关联销售订单号', isDense: true),
          ),
          TextField(
            controller: row.remark,
            decoration: const InputDecoration(labelText: '行备注', isDense: true),
            maxLines: 2,
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
          title: widget.id == null ? '新建生产计划单' : '编辑生产计划单'),
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            UtenFormGrid(children: [
                              TextField(
                                controller: _billNo,
                                decoration:
                                    const InputDecoration(labelText: '单据号 *'),
                              ),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('单据日期'),
                                subtitle: Text(_fmt(_billDate)),
                                trailing: const Icon(Icons.calendar_today_outlined,
                                    size: 18),
                                onTap: () => _pickDate(
                                  current: _billDate,
                                  onPicked: (d) => _billDate = d,
                                ),
                              ),
                              ListTile(
                                contentPadding: const EdgeInsets.only(top: UtenSpacing.s8),
                                title: const Text('交货日'),
                                subtitle: Text(_deliveryDate == null
                                    ? '未选择'
                                    : _fmt(_deliveryDate!)),
                                trailing:
                                    const Icon(Icons.event_outlined, size: 18),
                                onTap: () => _pickDate(
                                  current: _deliveryDate,
                                  onPicked: (d) => _deliveryDate = d,
                                ),
                              ),
                              TextField(
                                controller: _workshop,
                                decoration: const InputDecoration(
                                    labelText: '车间（编号/名称）'),
                              ),
                              TextField(
                                controller: _worker,
                                decoration:
                                    const InputDecoration(labelText: '生产工'),
                              ),
                              TextField(
                                controller: _seller,
                                decoration:
                                    const InputDecoration(labelText: '跟单员'),
                              ),
                              TextField(
                                controller: _sourceDocNo,
                                decoration: const InputDecoration(
                                    labelText: '来源单号（销售订单等）'),
                              ),
                            ]),
                            const SizedBox(height: UtenSpacing.s12),
                            TextField(
                              controller: _remark,
                              decoration: const InputDecoration(labelText: '备注'),
                              maxLines: 2,
                            ),
                          ],
                        ),
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
                          onPressed: () =>
                              setState(() => _items.add(_ItemRow())),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('添加行'),
                        ),
                      ],
                    ),
                    for (var i = 0; i < _items.length; i++)
                      _itemEditor(theme, _items[i], i),
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
              Text('明细 ${_items.length} 行 · 排产合计 ${_qtyTotal.toStringAsFixed(2)}',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
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
}
