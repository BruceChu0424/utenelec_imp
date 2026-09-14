import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../warehouse/models/stock_doc.dart';
import '../../warehouse/providers/warehouse_count_refresh.dart';
import '../models/production_material_return.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_material_repository.dart';

Future<bool?> showProductionMaterialReturnRequestSheet(
  BuildContext context, {
  required String planId,
  String? executionSegmentId,
}) => showUtenAdaptivePanel<bool>(
  context: context,
  drawerWidth: 1100,
  barrierDismissible: false,
  enableDrag: false,
  compactHeightFactor: .94,
  builder: (_) => _ReturnRequestSheet(
    planId: planId,
    executionSegmentId: executionSegmentId,
  ),
);

class _ReturnRow extends EditableGridRow {
  _ReturnRow(this.source);
  final ProductionMaterialReturnSource source;
  final qty = TextEditingController();
  @override
  void dispose() {
    qty.dispose();
    super.dispose();
  }
}

class _ReturnRequestSheet extends ConsumerStatefulWidget {
  const _ReturnRequestSheet({required this.planId, this.executionSegmentId});
  final String planId;
  final String? executionSegmentId;
  @override
  ConsumerState<_ReturnRequestSheet> createState() =>
      _ReturnRequestSheetState();
}

class _ReturnRequestSheetState extends ConsumerState<_ReturnRequestSheet> {
  final _grid = UtenEditableGridController<_ReturnRow>();
  final _reason = TextEditingController(text: '生产余料退仓');
  bool _loading = true, _saving = false, _uncertain = false;
  String? _error, _submitError, _requestKey, _frozenReason;
  List<Map<String, dynamic>>? _frozenItems;
  bool get _locked => _saving || _uncertain;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _grid.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_locked) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sources = await ref
          .read(productionMaterialRepositoryProvider)
          .returnSources(
            widget.planId,
            executionSegmentId: widget.executionSegmentId,
          );
      if (!mounted) return;
      _grid.replaceAll([
        for (final source in sources)
          if (source.availableQty > 0 ||
              source.pendingReturnQty > 0 ||
              source.returnBlockedReason != null)
            _ReturnRow(source),
      ]);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '可退料明细加载失败，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (_saving || _loading) return;
    if (!_uncertain) {
      if (_reason.text.trim().length < 2) {
        context.appWarning('请填写至少 2 个字的退料说明');
        return;
      }
      final items = <Map<String, dynamic>>[];
      // 一批可退明细常有十几行：问题行先收集、循环走完再一次说清，逐行 return
      // 只暴露第一处。数量写得不成数与超过可退量是两类毛病（一类改写法、一类
      // 改大小），分开汇总；判定口径与逐行拦截时完全一致，只是换了暴露方式。
      final malformed = <String>[];
      final overAvailable = <String>[];
      for (final row in _grid.rows) {
        if (row.qty.text.trim().isEmpty) continue;
        final qty = double.tryParse(row.qty.text.trim());
        if (qty == null ||
            !qty.isFinite ||
            qty < 0 ||
            (qty * 10000 - (qty * 10000).roundToDouble()).abs() > .0000001) {
          malformed.add(_rowLabel(row));
          continue;
        }
        if (qty > row.source.availableQty + .0000001) {
          overAvailable.add(
            '${_rowLabel(row)}填 ${_number(qty)}，可退 ${_number(row.source.availableQty)} ${row.source.unitName}',
          );
          continue;
        }
        if (qty > 0) {
          items.add({'issuePostingId': row.source.issuePostingId, 'qty': qty});
        }
      }
      if (malformed.isNotEmpty || overAvailable.isNotEmpty) {
        context.appError(
          [
            if (malformed.isNotEmpty)
              '以下 ${malformed.length} 行退料数量填写不合法（不能为负，最多 4 位小数），'
                  '请改正后再提交：${_joinRowIssues(malformed)}',
            if (overAvailable.isNotEmpty)
              '以下 ${overAvailable.length} 行本次退料超过可退数量，'
                  '请改小后再提交：${_joinRowIssues(overAvailable)}',
          ].join('\n'),
        );
        return;
      }
      if (items.isEmpty) {
        context.appWarning('请填写本次实际退仓数量');
        return;
      }
      _requestKey = const Uuid().v4();
      _frozenItems = List.unmodifiable(items);
      _frozenReason = _reason.text.trim().isEmpty ? null : _reason.text.trim();
    }
    setState(() {
      _saving = true;
      _submitError = null;
    });
    try {
      final documents = await ref
          .read(productionMaterialRepositoryProvider)
          .requestReturn(
            widget.planId,
            executionSegmentId: widget.executionSegmentId,
            idempotencyKey: _requestKey!,
            items: _frozenItems!,
            reason: _frozenReason,
          );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _uncertain = false;
      });
      refreshAfterProductionPlanGenerated(ref);
      invalidateWarehouseTaskCounts(ref);
      bumpListRefresh(ref, StockDocType.wdraw.refreshKey);
      context.appSuccess('已提交 ${documents.length} 张退料单，等待仓库核对收料');
      Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (!mounted) return;
      final uncertain = _responseUncertain(error);
      setState(() {
        _uncertain = uncertain;
        _submitError = uncertain
            ? '暂未确认退料申请结果，请重试本次申请。原数量与提交信息已保留。'
            : '${error.fieldErrors?.firstOrNull?.message ?? error.message}。请刷新可退明细后重新核对。';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _uncertain = true;
          _submitError = '暂未确认退料申请结果，请重试本次申请。原数量与提交信息已保留。';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_locked,
    child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('核对余料退仓'),
        actions: [
          IconButton(
            tooltip: '刷新可退明细',
            onPressed: _locked || _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: _locked ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? UtenEmpty.error(message: _error, actionLabel: '重试', onAction: _load)
          : _grid.rows.isEmpty
          ? const UtenEmpty(
              message: '当前没有可退仓余料',
              description: '已申请退仓的数量正在等待仓库收料。',
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${_grid.rows.where((row) => row.source.availableQty > 0).length} 项可退物料 · ${_grid.rows.map((row) => row.source.warehouseId).toSet().length} 个实际仓库',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  const Text(
                    '填写本次准备退回的数量，其余材料可留待后续生产。提交后由各原领料仓库核对收料，仓库确认后才增加库存。',
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _locked
                          ? null
                          : () => setState(() {
                              for (final row in _grid.rows) {
                                row.qty.text = _number(row.source.availableQty);
                              }
                            }),
                      icon: const Icon(Icons.done_all),
                      label: const Text('将可退量填入本次退料'),
                    ),
                  ),
                  UtenEditableGrid<_ReturnRow>(
                    controller: _grid,
                    columns: _columns(),
                    createBlankRow: () => throw UnsupportedError('退料来源不可手工新增'),
                    showAddRow: false,
                    showRowDelete: false,
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  TextField(
                    controller: _reason,
                    enabled: !_locked,
                    maxLength: 500,
                    decoration: const UtenInputDecoration(
                      InputDecoration(labelText: '退料说明', counterText: ''),
                      info: '说明本次退回原因或交接情况。',
                    ),
                  ),
                  if (_submitError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: UtenSpacing.s8,
                      ),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _submitError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: UtenSpacing.s12),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s8,
                    children: [
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: _locked
                            ? null
                            : () => Navigator.pop(context),
                        child: const Text('返回修改'),
                      ),
                      UtenButton(
                        key: const Key('material-return-submit'),
                        type: UtenButtonType.danger,
                        icon: Icons.assignment_return_outlined,
                        isLoading: _saving,
                        onPressed:
                            _saving ||
                                (!_uncertain &&
                                    !_grid.rows.any(
                                      (row) => row.source.availableQty > 0,
                                    ))
                            ? null
                            : _submit,
                        child: Text(_uncertain ? '重试本次申请' : '提交退仓申请'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    ),
  );

  List<EditableGridColumn<_ReturnRow>> _columns() => [
    EditableGridColumn(
      key: 'warehouse',
      label: '退入仓库',
      width: 145,
      cellBuilder: (_, row) => Text(row.source.warehouseName),
    ),
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。退错
    // 同名不同色的料会把库存加到别的货上，三属性必须同屏且能各自筛。后端对
    // 缺失颜色回落成 '—'，占位词不进单元（_omitPlaceholder 转 null）；原领料
    // 单号不是货品属性，跟在名称下面单独一行。
    EditableGridColumn(
      key: 'material',
      label: '物料名称 / 原领料单',
      width: 200,
      cellBuilder: (context, row) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          UtenGoodsIdentityCell(
            name: _omitPlaceholder(row.source.goodsName),
          ),
          Text(
            '领料单 ${row.source.drawNo}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
    EditableGridColumn(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      filterValueOf: (row) => _omitPlaceholder(row.source.goodsCode),
      cellBuilder: (context, row) =>
          UtenGoodsAttributeCell(_omitPlaceholder(row.source.goodsCode)),
    ),
    EditableGridColumn(
      key: 'colorName',
      label: '颜色',
      width: 96,
      filterValueOf: (row) => _omitPlaceholder(row.source.colorName),
      cellBuilder: (context, row) =>
          UtenGoodsAttributeCell(_omitPlaceholder(row.source.colorName)),
    ),
    EditableGridColumn(
      key: 'unit',
      label: '单位',
      width: 75,
      cellBuilder: (_, row) => Text(row.source.unitName),
    ),
    EditableGridColumn(
      key: 'available',
      label: '可退数量',
      width: 100,
      numeric: true,
      cellBuilder: (_, row) => Tooltip(
        message: row.source.returnBlockedReason ?? '可退数量已扣除待仓库收料数量',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_number(row.source.availableQty)),
            if (row.source.returnBlockedReason != null)
              const Padding(
                padding: EdgeInsets.only(left: UtenSpacing.s4),
                child: Icon(Icons.info_outline, size: 16),
              ),
          ],
        ),
      ),
    ),
    EditableGridColumn(
      key: 'pending',
      label: '待仓库收料',
      width: 110,
      numeric: true,
      cellBuilder: (_, row) => Text(_number(row.source.pendingReturnQty)),
    ),
    EditableGridColumn(
      key: 'qty',
      label: '本次退料',
      width: 138,
      numeric: true,
      headerInfo: '仅填写本次交回仓库的实际数量；留待后续生产的部分保持不退。',
      cellBuilder: (_, row) => TextField(
        key: ValueKey('material-return-qty-${row.source.issuePostingId}'),
        controller: row.qty,
        enabled: !_locked && row.source.availableQty > 0,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: const UtenInputDecoration(
          InputDecoration(isDense: true, hintText: '0'),
        ),
      ),
    ),
  ];
}

/// 汇总文案里的行标识：同一物料可能来自多张领料单（表里就是两行），只报货品名
/// 找不到是哪一行，故与「物料 / 原领料单」列同口径带上领料单号。
String _rowLabel(_ReturnRow row) =>
    '${row.source.goodsName}（领料单 ${row.source.drawNo}）';

/// 批量校验的行问题清单：最多列前 8 条，其余折成「等 N 行」——顶部通知里十几条
/// 会刷屏，前几条足够定位，改完再提交剩下的还会继续提示。
String _joinRowIssues(List<String> issues) {
  const limit = 8;
  final shown = issues.take(limit).join('；');
  return issues.length <= limit ? shown : '$shown 等 ${issues.length} 行';
}

bool _responseUncertain(ApiException error) =>
    error is NetworkException ||
    error is NetworkTimeoutException ||
    error.code == 'INTERNAL' ||
    (error.httpStatus != null && error.httpStatus! >= 500);

/// 后端把缺失的编号/颜色回落成 '—'；身份格不显示占位词，统一转回 null。
String? _omitPlaceholder(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty || text == '—' ? null : text;
}

String _number(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');
