import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/warehouse_quality_result.dart';
import 'warehouse_quality_slice_table.dart'
    show
        WarehouseQualitySliceDraft,
        warehouseQualityDateTime,
        warehouseQualityQuantity;

/// 合并明细表的一行：一条检查明细行 × 它的品质放行切片。
///
/// - 有待入库切片的明细行：每个切片一行（一行多次放行时显示「切片 i/n」），该行
///   可勾选、可就地输入本次实收与实际库位（[draft] 非空）；
/// - 无待入库切片的明细行（待检 / 全不合格 / 已全部入库）：单行只读展示（[draft] 空），
///   不可勾选。
class WarehouseQualityMergedRow extends EditableGridRow {
  WarehouseQualityMergedRow({
    required this.line,
    this.draft,
    this.sliceOrdinal = 0,
    this.sliceTotal = 0,
  });

  final WarehouseQualityInspectionLine line;
  final WarehouseQualitySliceDraft? draft;

  /// 该明细行的第几个放行切片（1 起；无切片 = 0）。切片总数 [sliceTotal] > 1 时
  /// 货品列显示「切片 i/n」，避免同货品多行被误读为重复数据。
  final int sliceOrdinal;
  final int sliceTotal;

  String get rowKey =>
      draft?.slice.passEventId ?? 'line-${line.inspectionItemId}';

  String? get unitName => draft?.slice.unitName ?? line.unitName;
}

/// 品质检查结果详情的合并明细表（原「检查结果明细」+「品质放行待入库明细」两表合一）。
///
/// 列序：勾选 | 判定结果 | 货品名称 | 货品库位 | 收货总量 | 合格总量 | 不合格总量 |
/// 待入库余量（可办理行内嵌本次实收输入）| 放行信息。
/// 三个总量列是明细行级口径（多放行切片行各自重复展示同一行总量，切片 i/n 已标注）；
/// 判定结果已覆盖原「检验状态」列的待检/部分/结案语义（红冲行显示已撤销），2026-09-03
/// 表头清理后不再单列。行底色随判定：合格绿 / 部分合格黄 / 不合格红 / 待检蓝 /
/// 已撤销灰；不合格数量 > 0 时该列数字标红加粗。选中真值源在
/// [WarehouseQualitySliceDraft.selected]（外部受控）。
class WarehouseQualityMergedTable extends StatelessWidget {
  const WarehouseQualityMergedTable({
    super.key,
    required this.controller,
    required this.editable,
    required this.saving,
    required this.onChanged,
  });

  final UtenEditableGridController<WarehouseQualityMergedRow> controller;
  final bool editable;
  final bool saving;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return UtenEditableGrid<WarehouseQualityMergedRow>(
      key: const Key('warehouse-quality-merged-table'),
      controller: controller,
      columns: _columns(context),
      showAddRow: false,
      showRowDelete: false,
      selectable: editable,
      canSelectRow: (row) => row.draft != null && !saving,
      selectedOf: (row) => row.draft?.selected ?? false,
      onRowSelect: (row, next) {
        final draft = row.draft;
        if (draft == null || saving) return;
        draft.selected = next;
        onChanged();
      },
      rowColor: (row) => _verdictRowColor(context, row.line.verdict),
      emptyMessage: '暂无检查明细',
    );
  }

  List<EditableGridColumn<WarehouseQualityMergedRow>> _columns(
    BuildContext context,
  ) {
    return [
      EditableGridColumn(
        key: 'verdict',
        label: '判定结果',
        width: 108,
        cellBuilder: (context, row) {
          final verdict = row.line.verdict;
          final color = _verdictColor(context, verdict);
          return Semantics(
            label: '${row.line.goodsLabel} 判定 ${verdict.label}',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_verdictIcon(verdict), size: 18, color: color),
                const SizedBox(width: UtenSpacing.s4),
                Text(
                  verdict.label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        },
      ),
      EditableGridColumn(
        key: 'goods',
        label: '货品名称',
        width: 250,
        textOf: (row) => row.line.goodsLabel,
        cellBuilder: (context, row) {
          final label = row.line.goodsLabel;
          final chip = row.sliceTotal > 1;
          if (!chip) {
            return Text(
              label.isEmpty ? '未命名货品' : label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            );
          }
          // 同一明细行拆成多个放行切片时标注序号，避免误读为重复货品。
          return Wrap(
            spacing: UtenSpacing.s6,
            runSpacing: UtenSpacing.s2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                label.isEmpty ? '未命名货品' : label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s6,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.10),
                  borderRadius: UtenRadius.smAll,
                ),
                child: Text(
                  '切片 ${row.sliceOrdinal}/${row.sliceTotal}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          );
        },
      ),
      EditableGridColumn(
        key: 'place',
        label: '货品库位',
        width: editable ? 170 : 140,
        required: editable,
        cellBuilder: (context, row) => _placeCell(context, row),
      ),
      EditableGridColumn(
        key: 'received',
        label: '收货总量',
        width: 112,
        numeric: true,
        cellBuilder: (context, row) =>
            Text(_qty(row.line.receivedBaseQty, row.unitName)),
      ),
      EditableGridColumn(
        key: 'passed',
        label: '合格总量',
        width: 112,
        numeric: true,
        cellBuilder: (context, row) =>
            Text(_qty(row.line.passedBaseQty, row.unitName)),
      ),
      EditableGridColumn(
        key: 'failed',
        label: '不合格总量',
        width: 116,
        numeric: true,
        cellBuilder: (context, row) {
          final failed = row.line.failedBaseQty;
          if (failed <= 0) return Text(_qty(failed, row.unitName));
          // 不合格数量 > 0：数字标红加粗（整行另有浅红底色，颜色不是唯一表达）。
          return Text(
            _qty(failed, row.unitName),
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(
              color: UtenColors.error,
              fontWeight: FontWeight.w700,
            ),
          );
        },
      ),
      EditableGridColumn(
        key: 'remaining',
        label: editable ? '待入库余量 / 本次实收' : '待入库余量',
        width: editable ? 208 : 130,
        numeric: true,
        required: editable,
        cellBuilder: (context, row) => _remainingCell(context, row),
      ),
      EditableGridColumn(
        key: 'release',
        label: '放行信息',
        width: 250,
        cellBuilder: (context, row) {
          final draft = row.draft;
          final slice = draft?.slice;
          if (slice == null) return const Text('—');
          final text = [
            if (slice.releasedBy?.isNotEmpty == true) '放行人 ${slice.releasedBy}',
            if (slice.releasedAt?.isNotEmpty == true)
              warehouseQualityDateTime(slice.releasedAt),
            if (slice.releaseNote?.isNotEmpty == true) slice.releaseNote!,
          ].join(' · ');
          return Text(
            text.isEmpty ? '—' : text,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          );
        },
      ),
    ];
  }

  /// 货品库位：可办理行 = 实际库位输入（选中后必填，描红框）；
  /// 只读切片行 = 建议库位提示；无切片行 = —。
  Widget _placeCell(BuildContext context, WarehouseQualityMergedRow row) {
    final draft = row.draft;
    final slice = draft?.slice;
    if (editable && draft != null && slice != null) {
      return RequiredCellFrame(
        listenable: draft.place,
        isEmpty: () => draft.selected && draft.place.text.trim().isEmpty,
        child: TextFormField(
          key: ValueKey('quality-slice-place-${slice.passEventId}'),
          controller: draft.place,
          enabled: draft.selected && !saving,
          maxLength: 100,
          errorBuilder: utenTextFieldErrorBuilder,
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            hintText: slice.placeHint ?? '实际库位',
          ),
          onChanged: (_) => onChanged(),
        ),
      );
    }
    if (slice?.placeHint?.isNotEmpty == true) {
      return Text(
        slice!.placeHint!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    return const Text('—');
  }

  /// 待入库余量：可办理行 = 本次实收输入（默认全额，suffix 提示剩余量、可改小做
  /// 部分入库）；其余行只读展示余量（无切片行显示明细行级余量，0 显示 —）。
  Widget _remainingCell(BuildContext context, WarehouseQualityMergedRow row) {
    final draft = row.draft;
    final slice = draft?.slice;
    if (editable && draft != null && slice != null) {
      return RequiredCellFrame(
        listenable: draft.quantity,
        isEmpty: () =>
            draft.selected &&
            (double.tryParse(draft.quantity.text.trim()) ?? 0) <= 0,
        child: TextFormField(
          key: ValueKey('quality-slice-qty-${slice.passEventId}'),
          controller: draft.quantity,
          enabled: draft.selected && !saving,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [LengthLimitingTextInputFormatter(24)],
          errorBuilder: utenTextFieldErrorBuilder,
          decoration: InputDecoration(
            isDense: true,
            counterText: '',
            suffixText: '余 ${warehouseQualityQuantity(slice.remainingBaseQty)}',
            suffixStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          onChanged: (_) => onChanged(),
        ),
      );
    }
    final remaining = slice?.remainingBaseQty ?? row.line.pendingStockBaseQty;
    if (remaining <= 0) return const Text('—');
    return Text(_qty(remaining, row.unitName));
  }
}

// ———————————————————— 判定口径（图标 / 颜色 / 行底色） ————————————————————

/// 判定 → 前导图标：合格绿对勾、不合格红禁止、部分合格黄警告、待检蓝沙漏、
/// 已撤销灰 undo。
IconData _verdictIcon(WarehouseQualityLineVerdict verdict) => switch (verdict) {
  WarehouseQualityLineVerdict.passed => Icons.check_circle,
  WarehouseQualityLineVerdict.partial => Icons.warning_amber_rounded,
  WarehouseQualityLineVerdict.rejected => Icons.block,
  WarehouseQualityLineVerdict.waiting => Icons.hourglass_top_outlined,
  WarehouseQualityLineVerdict.revoked => Icons.undo,
};

Color _verdictColor(
  BuildContext context,
  WarehouseQualityLineVerdict verdict,
) => switch (verdict) {
  WarehouseQualityLineVerdict.passed => UtenColors.success,
  WarehouseQualityLineVerdict.partial => UtenColors.warning,
  WarehouseQualityLineVerdict.rejected => UtenColors.error,
  WarehouseQualityLineVerdict.waiting => UtenColors.info,
  // 已撤销用中性轮廓色（浅深色主题各自适配，不用语义红绿）。
  WarehouseQualityLineVerdict.revoked => Theme.of(context).colorScheme.outline,
};

/// 判定 → 整行浅底色（与列表页作业状态行色同语义、更轻；选中行由表格统一高亮覆盖）。
Color? _verdictRowColor(
  BuildContext context,
  WarehouseQualityLineVerdict verdict,
) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (verdict) {
    WarehouseQualityLineVerdict.passed =>
      dark
          ? UtenColors.success.withValues(alpha: 0.12)
          : const Color(0xFFEDFAF4),
    WarehouseQualityLineVerdict.partial =>
      dark
          ? UtenColors.warning.withValues(alpha: 0.12)
          : const Color(0xFFFEF7E8),
    WarehouseQualityLineVerdict.rejected =>
      dark ? UtenColors.error.withValues(alpha: 0.10) : const Color(0xFFFDEEEC),
    WarehouseQualityLineVerdict.waiting =>
      dark ? UtenColors.info.withValues(alpha: 0.10) : const Color(0xFFEDF4FE),
    WarehouseQualityLineVerdict.revoked =>
      dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFF2F3F5),
  };
}

String _qty(double value, String? unit) =>
    '${warehouseQualityQuantity(value)}${unit == null ? '' : ' $unit'}';
