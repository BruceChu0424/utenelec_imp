// 仓库单据编辑页（新建/编辑）：主表头表单 + 明细可编辑 Excel 表（UtenEditableGrid）+ 保存。
//
// 差异按 widget.docType 内联判断（仓库无独立 config 文件，与采购不同）：
// - 调拨 TRANSFER 显隐"调入仓"；领料 DRAW 显隐"装配班组"；盘点 CHECK 切换列定义（账面/实盘/盘盈亏）。
// - 单据号系统自动生成（后端 DocNumberService），本页只读显示（新增态占位"保存后自动生成"）。
// - 日期统一 UtenDateField（outlined，与其它字段同款）。
// 明细改 Excel 表：货品/数量（+账面/实盘/盘盈亏 当 CHECK）+ 添加行/添加多行 + 行尾删除 + sticky 表头。
// 保存组装 body 调 create/update，成功后跳详情。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/widgets/task_claim_badge.dart';
import '../../../shared/widgets/task_claim_handle.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../stock/repositories/stock_query_repository.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';
import '../widgets/stock_grid_columns.dart';

class StockDocEditPage extends ConsumerStatefulWidget {
  const StockDocEditPage({
    super.key,
    required this.docType,
    this.id,
    this.sourceDrawId,
  });
  final StockDocType docType;
  final String? id; // null=新建
  final String? sourceDrawId;

  @override
  ConsumerState<StockDocEditPage> createState() => _StockDocEditPageState();
}

class _StockDocEditPageState extends ConsumerState<StockDocEditPage> {
  bool get _isCheck => widget.docType == StockDocType.check;
  bool get _isWdraw => widget.docType == StockDocType.wdraw;

  final _billNo = TextEditingController(); // 只读显示（后端自动生成）
  final _remark = TextEditingController();
  final _assTeam = TextEditingController();
  DateTime _billDate = ChinaDateTime.today();
  String? _warehouseId;
  String? _toWarehouseId;
  String? _departmentId; // 领料车间（仅 DRAW，V97）

  final _grid = UtenEditableGridController<StockGridRow>();
  final _scrollCtl = ScrollController();
  bool _saving = false;
  bool _loadingCheckBooks = false;
  bool _loading = false;
  bool _loadedCanEdit = false;
  String? _editRestrictionReason;
  // 制单信息（服务端权威，只读展示）
  String? _makerName;
  String? _createdAt;

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
    if (widget.id == null && _isWdraw && widget.sourceDrawId != null) {
      await _loadReturnableSources(widget.sourceDrawId!);
    }
    if (widget.id == null && _warehouseId == null) {
      // 仓库预填「本类型最近一张单的仓库」（与销售 D1 同款），减少手选。
      try {
        final last = await ref
            .read(stockDocRepositoryProvider(widget.docType))
            .list(size: 1);
        if (last.items.isNotEmpty && last.items.first.warehouseId != null) {
          _warehouseId = last.items.first.warehouseId;
        }
      } catch (_) {
        /* 预填失败静默，用户手选 */
      }
    }
    if (widget.id != null) {
      try {
        final d = await ref
            .read(stockDocRepositoryProvider(widget.docType))
            .detail(widget.id!);
        final goodsIds = d.items
            .map((e) => e.goodsId)
            .whereType<String>()
            .toSet();
        await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
        if (!mounted) return;
        _billNo.text = d.billNo ?? '';
        _remark.text = d.remark ?? '';
        _assTeam.text = d.assTeam ?? '';
        if (d.billDate != null) {
          _billDate = DateTime.tryParse(d.billDate!) ?? _billDate;
        }
        _warehouseId = d.warehouseId;
        _toWarehouseId = d.toWarehouseId;
        _departmentId = d.departmentId;
        _makerName = d.makerName;
        _createdAt = d.createdAt;
        _loadedCanEdit = d.canEdit;
        _editRestrictionReason = d.restrictionReason;
        final rows = <StockGridRow>[];
        for (final it in d.items) {
          final row =
              StockGridRow(
                  isCheck: _isCheck,
                  sourceLocked: _isWdraw && it.upstreamItemId != null,
                )
                ..goods = it.goodsId == null
                    ? null
                    : GoodsOption(
                        id: it.goodsId!,
                        name: ref
                            .read(masterNameServiceProvider)
                            .goods(it.goodsId),
                      );
          row
            ..upstreamItemId = it.upstreamItemId
            ..colorId = it.colorId
            ..unitId = it.unitId
            ..unitRate = it.unitRate ?? 1
            ..executionSegmentId = it.executionSegmentId
            ..executionSegmentSalesAllocationId =
                it.executionSegmentSalesAllocationId;
          if (_isWdraw) {
            row
              ..upstreamItemId = it.upstreamItemId
              ..sourceDrawNo = it.sourceDocNo;
          }
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
    if (_grid.isEmpty && !_isWdraw) {
      _grid.addRow(StockGridRow(isCheck: _isCheck));
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadReturnableSources(String drawId) async {
    try {
      final sources = await ref
          .read(stockDocRepositoryProvider(StockDocType.wdraw))
          .returnableSources(drawId: drawId);
      if (sources.isEmpty) {
        if (mounted) context.appWarning('该领料单没有尚可退回的已领良品');
        return;
      }
      _warehouseId = sources.first.warehouseId;
      final rows = sources.map((source) {
        final row = StockGridRow(sourceLocked: true)
          ..goods = GoodsOption(
            id: source.goodsId,
            code: source.goodsCode,
            name: source.goodsName,
          );
        row
          ..upstreamItemId = source.drawItemId
          ..sourceDrawId = source.drawId
          ..sourceDrawNo = source.drawNo
          ..unitId = source.unitId
          ..unitRate = source.unitRate
          ..maxQty = source.maxReturnQty;
        return row;
      }).toList();
      _grid.replaceAll(rows);
    } catch (_) {
      if (mounted) {
        context.appError('读取可退料来源失败，请刷新原领料单后重试');
      }
    }
  }

  /// 选货品范围：领料/退料=材料；产成品进/出仓=成品；调拨/其它出入库/盘点=全部。
  UtenGoodsPickerScope get _pickerScope => switch (widget.docType) {
    StockDocType.draw || StockDocType.wdraw => UtenGoodsPickerScope.material,
    StockDocType.finishedIn ||
    StockDocType.finishedOut => UtenGoodsPickerScope.sellable,
    _ => UtenGoodsPickerScope.all,
  };

  Future<void> _pickGoods(StockGridRow row) async {
    if (_isCheck && _warehouseId == null) {
      context.appWarning('请先选择盘点仓库，再添加货品');
      return;
    }
    final g = await showUtenGoodsPicker(context, ref, scope: _pickerScope);

    if (g == null) return;
    row
      ..goods = GoodsOption(id: g.id, code: g.code, name: g.name)
      ..colorId = g.colorId
      ..unitId = g.unitId
      ..unitRate = 1;
    if (_isCheck) {
      await _loadCheckBookQty(row);
    }
  }

  Future<void> _loadCheckBookQty(StockGridRow row) async {
    final warehouseId = _warehouseId;
    final goods = row.goods;
    if (!_isCheck || warehouseId == null || goods == null) {
      row.bookQty.clear();
      return;
    }
    try {
      final result = await ref
          .read(stockQueryRepositoryProvider)
          .balances(size: 100, warehouseId: warehouseId, goodsId: goods.id);
      var qty = 0.0;
      var found = false;
      for (final balance in result.items) {
        if (balance.colorId == row.colorId) {
          qty = balance.qty ?? 0;
          found = true;
          break;
        }
      }
      // 历史主档颜色缺失但该货品在目标仓只有一条余额时，沿用该余额颜色，避免误读为零。
      if (!found && row.colorId == null && result.items.length == 1) {
        final balance = result.items.single;
        row.colorId = balance.colorId;
        qty = balance.qty ?? 0;
      }
      row.bookQty.text = _qtyText(qty);
    } catch (error) {
      row.bookQty.clear();
      if (mounted) {
        context.appApiError(error, fallback: '读取账面库存失败，请重试');
      }
    }
  }

  Future<void> _refreshCheckBooks() async {
    if (!_isCheck) return;
    if (mounted) setState(() => _loadingCheckBooks = true);
    try {
      for (final row in _grid.rows.where((row) => row.goods != null)) {
        await _loadCheckBookQty(row);
      }
    } finally {
      if (mounted) setState(() => _loadingCheckBooks = false);
    }
  }

  String _qtyText(double value) {
    final fixed = value.toStringAsFixed(4);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  Future<void> _save() async {
    if (widget.id != null && !_loadedCanEdit) {
      return context.appError(_editRestrictionReason ?? '该单据不可通过仓库通用页面编辑');
    }

    final rows = _grid.rows;
    if (_warehouseId == null) {
      return context.appError('请选择仓库');
    }
    if (widget.docType == StockDocType.transfer && _toWarehouseId == null) {
      return context.appError('请选择调入仓');
    }
    if (_isCheck && _loadingCheckBooks) {
      return context.appInfo('账面库存仍在读取，请稍候');
    }
    if (rows.isEmpty || rows.every((r) => r.goods == null)) {
      return context.appError('请至少添加一条明细');
    }
    final items = <Map<String, dynamic>>[];
    for (final r in rows) {
      if (r.goods == null) continue;
      final m = <String, dynamic>{'goodsId': r.goods!.id};
      if (r.colorId != null) m['colorId'] = r.colorId;
      if (r.unitId != null) m['unitId'] = r.unitId;
      m['unitRate'] = r.unitRate;
      if (_isWdraw) {
        if (r.upstreamItemId == null) {
          return context.appError('生产退料必须逐行引用原领料明细');
        }
        final qty = double.tryParse(r.qty.text.trim()) ?? 0;
        if (qty <= 0) continue;
        if (r.maxQty != null && qty > r.maxQty! + 0.0000001) {
          return context.appError(
            '${r.goods!.name} 退料数量不能超过 ${r.maxQty!.toStringAsFixed(4)}',
          );
        }
        m
          ..['qty'] = qty
          ..['upstreamItemId'] = r.upstreamItemId
          ..['unitId'] = r.unitId
          ..['unitRate'] = r.unitRate
          ..['sourceDocNo'] = r.sourceDrawNo;
      } else if (_isCheck) {
        final bookQty = double.tryParse(r.bookQty.text);
        if (bookQty == null) {
          return context.appError('${r.goods!.name} 的账面库存尚未读取');
        }
        final countQty = double.tryParse(r.checkQty.text.trim());
        if (countQty == null || countQty < 0) {
          return context.appError('${r.goods!.name} 的实盘数量必须填写且不能小于 0');
        }
        m['qty'] = bookQty; // 账面写入 items.qty
        m['countQty'] = countQty;
        // 仅作前端预览；后端会按权威账面快照重新计算盈亏。
        m['surplusQty'] = countQty - bookQty;
      } else {
        m['qty'] = double.tryParse(r.qty.text) ?? 0;
      }
      if (r.upstreamItemId != null) m['upstreamItemId'] = r.upstreamItemId;
      if (r.executionSegmentId != null) {
        m['executionSegmentId'] = r.executionSegmentId;
      }
      if (r.executionSegmentSalesAllocationId != null) {
        m['executionSegmentSalesAllocationId'] =
            r.executionSegmentSalesAllocationId;
      }
      items.add(m);
    }
    if (items.isEmpty) {
      return context.appError(_isWdraw ? '请填写至少一行实际退料数量' : '请至少添加一条明细');
    }
    // 单据号后端自动生成（DocNumberService），不再随 body 提交。
    final body = <String, dynamic>{
      'docType': widget.docType.code,
      'billDate': _fmt(_billDate),
      'warehouseId': _warehouseId,
      if (widget.docType == StockDocType.transfer)
        'toWarehouseId': _toWarehouseId,
      if (widget.docType == StockDocType.draw) ...{
        'assTeam': _assTeam.text.trim().isEmpty ? null : _assTeam.text.trim(),
        'departmentId': _departmentId,
      },
      'remark': _remark.text.trim().isEmpty ? null : _remark.text.trim(),
      'items': items,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(stockDocRepositoryProvider(widget.docType));
      final d = widget.id == null
          ? await repo.create(body)
          : await repo.update(widget.id!, body);
      if (!mounted) return;
      context.appSuccess(widget.id == null ? '已创建' : '已保存');
      bumpListRefresh(ref, widget.docType.refreshKey);
      context.replace(RoutePath.stockDocDetail(widget.docType.code, d.id));
    } catch (error) {
      if (mounted) context.appApiError(error, fallback: '保存失败');
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
        title: widget.id == null
            ? '新建${widget.docType.label}'
            : '编辑${widget.docType.label}',
        showBackButton: true,
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: () =>
                context.push(RoutePath.stockDocList(widget.docType.code)),
            child: const Text('查看历史'),
          ),
        ],
      ),
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
                              UtenFormGrid(
                                children: [
                                  // 单据号：系统自动生成，只读显示。
                                  TextFormField(
                                    readOnly: true,
                                    controller: _billNo,
                                    decoration: InputDecoration(
                                      labelText: '单据号',
                                      hintText: _billNo.text.isEmpty
                                          ? '保存后自动生成'
                                          : null,
                                      filled: _billNo.text.isEmpty,
                                      suffixIcon: _billNo.text.isEmpty
                                          ? const Icon(
                                              Icons.autorenew_outlined,
                                              size: 18,
                                            )
                                          : const Icon(
                                              Icons.lock_outline,
                                              size: 16,
                                            ),
                                    ),
                                  ),
                                  // 制单员/制单时间：服务端权威，只读展示（责任制）。
                                  ...utenMakerAuditCells(
                                    ref,
                                    makerName: _makerName,
                                    createdAt: _createdAt,
                                  ),
                                  UtenDateField(
                                    label: '单据日期',
                                    required: true,
                                    value: _billDate,
                                    onChanged: (d) =>
                                        setState(() => _billDate = d),
                                  ),
                                  _dd(
                                    '仓库',
                                    _warehouseId,
                                    names.warehouseEntries,
                                    (v) {
                                      setState(() => _warehouseId = v);
                                      if (_isCheck) {
                                        unawaited(_refreshCheckBooks());
                                      }
                                    },
                                    required: true,
                                  ),
                                  if (widget.docType == StockDocType.transfer)
                                    _dd(
                                      '调入仓',
                                      _toWarehouseId,
                                      names.warehouseEntries,
                                      (v) => setState(() => _toWarehouseId = v),
                                      required: true,
                                    ),
                                  if (widget.docType == StockDocType.draw) ...[
                                    _dd(
                                      '领料车间',
                                      _departmentId,
                                      names.departmentEntries,
                                      (v) => setState(() => _departmentId = v),
                                    ),
                                    TextField(
                                      controller: _assTeam,
                                      decoration: const InputDecoration(
                                        labelText: '装配班组',
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: UtenSpacing.s12),
                              TextField(
                                controller: _remark,
                                decoration: const InputDecoration(
                                  labelText: '备注',
                                ),
                                maxLines: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      if (_isCheck) ...[
                        Text(
                          '账面数量由系统按所选仓库读取，保存后形成盘点快照。'
                          '审核前如发生其它出入库，系统会拒绝用旧快照修正库存，'
                          '请刷新账面并重新核对实盘数。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s8),
                      ],
                      Row(
                        children: [
                          Text(
                            '明细 (${_grid.length})',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                        ],
                      ),
                      UtenEditableGrid<StockGridRow>(
                        controller: _grid,
                        columns: stockGridColumns(
                          _pickGoods,
                          isCheck: _isCheck,
                          isWdraw: _isWdraw,
                        ),
                        createBlankRow: () => StockGridRow(
                          isCheck: _isCheck,
                          sourceLocked: _isWdraw,
                        ),
                        showAddRow: !_isWdraw,
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
            border: Border(
              top: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
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
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (_isCheck) const SizedBox(width: UtenSpacing.s16),
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: () => context.pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: UtenSpacing.s12),
              widget.id == null
                  ? UtenButton(
                      isLoading: _saving || _loadingCheckBooks,
                      icon: Icons.save_outlined,
                      onPressed: (_saving || _loadingCheckBooks) ? null : _save,
                      child: const Text('保存'),
                    )
                  : TaskClaimHandle(
                      key: ValueKey('fulfillment_claim_${widget.id}'),
                      targetType: 'FULFILLMENT_TASK',
                      targetKey: widget.id!,
                      builder: (heldByMe, claim) {
                        // 他人正编辑同一仓库单据 → 显示「XX 处理中」并禁用保存（UX 层；后端守卫兜底）。
                        final blocked = !heldByMe && claim != null;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (blocked)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TaskClaimBadge(claim: claim),
                                    const SizedBox(width: 6),
                                    const Text(
                                      '他人正在编辑，保存已禁用',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                            UtenButton(
                              isLoading: _saving || _loadingCheckBooks,
                              icon: Icons.save_outlined,
                              onPressed:
                                  (_saving ||
                                      _loadingCheckBooks ||
                                      blocked ||
                                      !_loadedCanEdit)
                                  ? null
                                  : _save,
                              child: const Text('保存'),
                            ),
                          ],
                        );
                      },
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dd(
    String label,
    String? value,
    Map<String, String> entries,
    ValueChanged<String?> onChanged, {
    bool required = false,
  }) {
    return UtenDropdownField(
      label: label,
      required: required,
      value: value,
      items: [
        for (final e in entries.entries)
          UtenDropdownItem(value: e.key, label: e.value),
        if (value != null && value.isNotEmpty && !entries.containsKey(value))
          UtenDropdownItem(value: value, label: value),
      ],
      onChanged: onChanged,
    );
  }
}
