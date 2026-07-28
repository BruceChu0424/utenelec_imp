// 仓库单据编辑页（新建/编辑）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 差异按 widget.docType 内联判断（仓库无独立 config 文件，与采购不同）：
// - 调拨 TRANSFER 显隐"调入仓"；领料 DRAW 显隐"装配班组"；盘点 CHECK 切换列定义（账面/实盘/盘盈亏）。
// - 单据号系统自动生成（后端 DocNumberService），本页只读显示（新增态占位"保存后自动生成"）。
// - 日期统一 UtenDateField（outlined，与其它字段同款）。
// 明细改 Excel 表：货品/数量（+账面/实盘/盘盈亏 当 CHECK）+ 添加行/添加多行 + 行尾删除 + sticky 表头。
// 保存组装 body 调 create/update，成功后跳详情。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../purchase/providers/master_name_provider.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';
import '../widgets/stock_grid_columns.dart';

class StockDocEditPage extends ConsumerStatefulWidget {
  const StockDocEditPage({super.key, required this.docType, this.id});
  final StockDocType docType;
  final String? id; // null=新建

  @override
  ConsumerState<StockDocEditPage> createState() => _StockDocEditPageState();
}

class _StockDocEditPageState extends ConsumerState<StockDocEditPage> {
  bool get _isCheck => widget.docType == StockDocType.check;

  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  final _assTeam = TextEditingController();
  DateTime _billDate = DateTime.now();
  String? _warehouseId;
  String? _toWarehouseId;

  final _grid = UtenEditableGridController<StockGridRow>();
  final _scrollCtl = ScrollController();
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
    _remark.dispose();
    _assTeam.dispose();
    _grid.dispose(); // 自动 dispose 各行控制器
    _scrollCtl.dispose();
    super.dispose();
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
        _assTeam.text = d.assTeam ?? '';
        if (d.billDate != null) _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        _warehouseId = d.warehouseId;
        _toWarehouseId = d.toWarehouseId;
        final rows = <StockGridRow>[];
        for (final it in d.items) {
          final row = StockGridRow(isCheck: _isCheck)
            ..goods = it.goodsId == null
                ? null
                : GoodsOption(
                    id: it.goodsId!,
                    name: ref.read(masterNameServiceProvider).goods(it.goodsId));
          if (_isCheck) {
            // 盘点：账面 = items.qty，实盘 = items.countQty
            row.bookQty.text = it.qty?.toString() ?? '';
            row.checkQty.text = it.countQty?.toString() ?? '';
          } else {
            row.qty.text = it.qty?.toString() ?? '';
          }
          rows.add(row);
        }
        _grid.replaceAll(rows);
      } catch (_) {
        // 静默降级
      }
    }
    if (_grid.isEmpty) _grid.addRow(StockGridRow(isCheck: _isCheck));
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pickGoods(StockGridRow row) async {
    final g = await showUtenGoodsPicker(context, ref);
    if (g == null) return;
    row.goods = GoodsOption(id: g.id, code: g.code, name: g.name);
  }

  Future<void> _save() async {
    final rows = _grid.rows;
    if (rows.isEmpty || rows.every((r) => r.goods == null)) {
      return context.appError('请至少添加一条明细');
    }
    final items = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      final m = <String, dynamic>{'goodsId': r.goods!.id};
      if (_isCheck) {
        final bookQty = double.tryParse(r.bookQty.text) ?? 0;
        final countQty = double.tryParse(r.checkQty.text);
        m['qty'] = bookQty; // 账面写入 items.qty
        if (countQty != null) m['countQty'] = countQty;
        // 盈亏 = 实盘 - 账面；后端按 surplus 联动库存
        m['surplusQty'] = (countQty ?? 0) - bookQty;
      } else {
        m['qty'] = double.tryParse(r.qty.text) ?? 0;
      }
      items.add(m);
    }
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'docType': widget.docType.code,
      'billDate': _fmt(_billDate),
      'warehouseId': _warehouseId,
      if (widget.docType == StockDocType.transfer) 'toWarehouseId': _toWarehouseId,
      if (widget.docType == StockDocType.draw)
        'assTeam': _assTeam.text.trim().isEmpty ? null : _assTeam.text.trim(),
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
      appBar: UtenAppBar(
          title: widget.id == null ? '新建${widget.docType.label}' : '编辑${widget.docType.label}',
          showBackButton: true),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : UtenContentContainer(
                child: Scrollbar(
                  controller: _scrollCtl,
                  thumbVisibility: true,
                  child: ListView(
                  controller: _scrollCtl,
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            UtenFormGrid(children: [
                              // 单据号：系统自动生成，只读显示。
                              TextFormField(
                                readOnly: true,
                                controller: _billNo,
                                decoration: InputDecoration(
                                  labelText: '单据号',
                                  hintText:
                                      _billNo.text.isEmpty ? '保存后自动生成' : null,
                                  filled: _billNo.text.isEmpty,
                                  suffixIcon: _billNo.text.isEmpty
                                      ? const Icon(Icons.autorenew_outlined, size: 18)
                                      : const Icon(Icons.lock_outline, size: 16),
                                ),
                              ),
                              UtenDateField(
                                label: '单据日期',
                                required: true,
                                value: _billDate,
                                onChanged: (d) => setState(() => _billDate = d),
                              ),
                              _dd('仓库', _warehouseId, names.warehouseEntries,
                                  (v) => setState(() => _warehouseId = v)),
                              if (widget.docType == StockDocType.transfer)
                                _dd('调入仓', _toWarehouseId, names.warehouseEntries,
                                    (v) => setState(() => _toWarehouseId = v)),
                              if (widget.docType == StockDocType.draw)
                                TextField(
                                  controller: _assTeam,
                                  decoration: const InputDecoration(labelText: '装配班组'),
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
                        Text('明细 (${_grid.length})',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const Spacer(),
                      ],
                    ),
                    UtenEditableGrid<StockGridRow>(
                      controller: _grid,
                      columns: stockGridColumns(_pickGoods, isCheck: _isCheck),
                      createBlankRow: () => StockGridRow(isCheck: _isCheck),
                    ),
                  ],
                ),
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
              // 盘点模式显示盘盈亏合计（非盘点无金额概念，不显示）。
              if (_isCheck)
                ValueListenableBuilder<double>(
                  valueListenable: _grid.totalListenable,
                  builder: (_, total, _) => Text(
                    '盘盈亏合计 ${total.toStringAsFixed(2)}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              if (_isCheck) const SizedBox(width: UtenSpacing.s16),
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
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dd(String label, String? value, Map<String, String> entries, ValueChanged<String?> onChanged) {
    return UtenDropdownField(
      label: label,
      value: value,
      items: [
        for (final e in entries.entries) UtenDropdownItem(value: e.key, label: e.value),
        if (value != null && value.isNotEmpty && !entries.containsKey(value))
          UtenDropdownItem(value: value, label: value),
      ],
      onChanged: onChanged,
    );
  }
}
