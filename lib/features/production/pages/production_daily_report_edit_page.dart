// 生产日报编辑页（新建/编辑，全页路由 · production_daily_report:edit · 空结构保未来）。
//
// 与生产计划单编辑页同构。日报特点：
//   - 无车间文本字段（workshopName 仍留，但日报主线是仓库 + 工序/完工量）
//   - 仓库下拉（MasterNameService 解析 warehouseId）
//   - 明细行核心：goods（必填）+ qty 完工量（必填）+ price 单价 + 关联计划 planNo
//   - 行金额 = qty × price（日报有金额，区别于计划单的数量驱动）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../purchase/providers/master_name_provider.dart';
import '../../purchase/widgets/goods_picker_dialog.dart';
import '../repositories/production_repository.dart';

class ProductionDailyReportEditPage extends ConsumerStatefulWidget {
  const ProductionDailyReportEditPage({super.key, this.id});
  final String? id;

  @override
  ConsumerState<ProductionDailyReportEditPage> createState() =>
      _ProductionDailyReportEditPageState();
}

class _ItemRow {
  _ItemRow();
  final qty = TextEditingController();
  final price = TextEditingController();
  final planNo = TextEditingController();
  final remark = TextEditingController();
  GoodsOption? goods;
  String? colorId;
  String? unitId;

  void dispose() {
    qty.dispose();
    price.dispose();
    planNo.dispose();
    remark.dispose();
  }
}

class _ProductionDailyReportEditPageState
    extends ConsumerState<ProductionDailyReportEditPage> {
  final _billNo = TextEditingController();
  final _workshop = TextEditingController();
  final _remark = TextEditingController();
  DateTime _billDate = DateTime.now();
  String? _warehouseId;

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
            .read(productionDailyReportRepositoryProvider)
            .detail(widget.id!);
        final goodsIds =
            d.items.map((e) => e.goodsId).whereType<String>().toSet();
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _workshop.text = d.workshopName ?? '';
        _remark.text = d.remark ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _warehouseId = d.warehouseId;
        for (final it in d.items) {
          final row = _ItemRow()
            ..qty.text = it.qty?.toString() ?? ''
            ..price.text = it.price?.toString() ?? ''
            ..planNo.text = it.planNo ?? ''
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

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  double get _total => _items.fold<double>(
      0,
      (s, r) =>
          s +
          (double.tryParse(r.qty.text) ?? 0) *
              (double.tryParse(r.price.text) ?? 0));

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
    for (var i = 0; i < _items.length; i++) {
      final r = _items[i];
      if (r.goods == null) continue;
      if (double.tryParse(r.qty.text) == null) {
        context.appError('第 ${i + 1} 行完工量无效');
        return;
      }
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
        if (price != null) 'total': qty * price,
        if (r.colorId != null) 'colorId': r.colorId,
        if (r.unitId != null) 'unitId': r.unitId,
        if (r.planNo.text.trim().isNotEmpty) 'planNo': r.planNo.text.trim(),
        if (r.remark.text.trim().isNotEmpty) 'remark': r.remark.text.trim(),
      });
    }
    final body = <String, dynamic>{
      'billNo': _billNo.text.trim(),
      'billDate': _fmt(_billDate),
      if (_warehouseId != null) 'warehouseId': _warehouseId,
      if (_workshop.text.trim().isNotEmpty)
        'workshopName': _workshop.text.trim(),
      if (_remark.text.trim().isNotEmpty) 'remark': _remark.text.trim(),
      'items': itemsBody,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(productionDailyReportRepositoryProvider);
      final d = widget.id == null
          ? await repo.create(body)
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      context.replace('/production/daily-reports/${d.id}');
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

  Widget _itemEditor(ThemeData theme, _ItemRow row) {
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
              onPressed: () => setState(() {
                _items.remove(row);
                row.dispose();
              }),
            ),
          ]),
          const SizedBox(height: UtenSpacing.s8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: row.qty,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: '完工量 *', isDense: true),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: TextField(
                controller: row.price,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: '单价', isDense: true),
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
            controller: row.planNo,
            decoration: const InputDecoration(
                labelText: '关联生产计划号', isDense: true),
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
          title: widget.id == null ? '新建生产日报' : '编辑生产日报'),
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
                            decoration:
                                const InputDecoration(labelText: '单据号 *'),
                          ),
                          const SizedBox(height: UtenSpacing.s8),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('单据日期'),
                            subtitle: Text(_fmt(_billDate)),
                            trailing: const Icon(Icons.calendar_today_outlined,
                                size: 18),
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
                          _dropdown(
                              '仓库',
                              _warehouseId,
                              ref.read(masterNameServiceProvider).warehouseEntries,
                              (v) => setState(() => _warehouseId = v)),
                          TextField(
                            controller: _workshop,
                            decoration: const InputDecoration(
                                labelText: '车间（编号/名称）'),
                          ),
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
                          onPressed: () =>
                              setState(() => _items.add(_ItemRow())),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('添加行'),
                        ),
                      ],
                    ),
                    for (final row in _items) _itemEditor(theme, row),
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
