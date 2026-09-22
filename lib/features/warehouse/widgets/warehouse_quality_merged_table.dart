import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/warehouse_quality_result.dart';
import 'warehouse_inbound_allocation_view.dart';
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
    this.receiptNo,
    this.receiptTypeLabel,
    this.supplierId,
    this.supplierName,
  });

  final WarehouseQualityInspectionLine line;
  final WarehouseQualitySliceDraft? draft;
  final String? receiptNo;
  final String? receiptTypeLabel;
  final String? supplierId;
  final String? supplierName;

  /// 该明细行的第几个放行切片（1 起；无切片 = 0）。切片总数 [sliceTotal] > 1 时
  /// 货品列显示「切片 i/n」，避免同货品多行被误读为重复数据。
  final int sliceOrdinal;
  final int sliceTotal;

  String get rowKey =>
      draft?.slice.passEventId ?? 'line-${line.inspectionItemId}';

  String? get unitName => draft?.slice.unitName ?? line.unitName;

  /// 无切片行：先入库后检(V596)已上架的行显示实际上架仓，否则显示收货参考仓。
  String? get warehouseName => draft != null
      ? draft!.warehouseName ?? draft!.warehouseId
      : line.preStocked?.warehouseName ??
            line.preStocked?.warehouseId ??
            line.warehouseName ??
            line.warehouseId;
}

/// 两种办理入口共用同一个按检查行和放行 UUID 关联的行集。
List<WarehouseQualityMergedRow> warehouseQualityRowsForDetail(
  WarehouseQualityResultDetail detail,
  List<WarehouseQualitySliceDraft> drafts,
) {
  final byLine = <String, List<WarehouseQualitySliceDraft>>{};
  for (final draft in drafts) {
    byLine.putIfAbsent(draft.slice.inspectionItemId, () => []).add(draft);
  }
  final rows = <WarehouseQualityMergedRow>[];
  WarehouseQualityMergedRow row(
    WarehouseQualityInspectionLine line,
    WarehouseQualitySliceDraft? draft,
    int ordinal,
    int count,
  ) => WarehouseQualityMergedRow(
    line: line,
    draft: draft,
    sliceOrdinal: ordinal,
    sliceTotal: count,
    receiptNo: detail.billNo ?? detail.receiptId,
    receiptTypeLabel: detail.receiptType.label,
    supplierId: detail.supplierId,
    supplierName: detail.supplierName,
  );
  for (final line in detail.lines) {
    final slices = byLine.remove(line.inspectionItemId) ?? const [];
    if (slices.isEmpty) {
      rows.add(row(line, null, 0, 0));
    } else {
      for (var i = 0; i < slices.length; i++) {
        if (slices[i].slice.goodsId != line.goodsId) {
          throw const FormatException('放行记录与检查明细货品不一致，请重新加载');
        }
        rows.add(row(line, slices[i], i + 1, slices.length));
      }
    }
  }
  if (byLine.isNotEmpty) {
    throw const FormatException('放行记录缺少对应检查明细，请重新加载');
  }
  return rows;
}

/// 单张详情与批量入库共用的检查结果、来源和实际点收表。
///
/// 来源商、目标叶仓、实际库位、单位和合格待入量均逐行保留，本次实收单独输入。
/// 批量入口加来源收货单列；相同货品的不同放行切片始终是不同来源行。
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
    this.onPickWarehouse,
    this.showReceipt = false,
    this.stickyHeaderPinned,
  });

  final UtenEditableGridController<WarehouseQualityMergedRow> controller;
  final bool editable;
  final bool saving;
  final VoidCallback onChanged;
  final void Function(WarehouseQualitySliceDraft draft)? onPickWarehouse;
  final bool showReceipt;

  /// 表头吸顶信号（全站表格滚动口径 2026-09-22）；null = 表头随页滚动。
  final ValueNotifier<bool>? stickyHeaderPinned;

  @override
  Widget build(BuildContext context) {
    return UtenEditableGrid<WarehouseQualityMergedRow>(
      key: const Key('warehouse-quality-merged-table'),
      controller: controller,
      stickyHeaderPinned: stickyHeaderPinned,
      columns: _columns(context),
      showAddRow: false,
      showRowDelete: false,
      selectable: editable,
      canSelectRow: (row) => row.draft?.canConfirm == true && !saving,
      selectedOf: (row) => row.draft?.selected ?? false,
      onRowSelect: (row, next) {
        final draft = row.draft;
        if (draft == null || !draft.canConfirm || saving) return;
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
      if (showReceipt)
        EditableGridColumn(
          key: 'receipt',
          label: '来源收货单',
          width: 150,
          filterValueOf: (row) => row.receiptNo,
          // 单行「单号 · 类型」（2026-09-16 全站口径）：不再两行拼格，textOf
          // 与格内同源，列宽随整段文本自动加宽。
          textOf: (row) => [
            row.receiptNo ?? '—',
            row.receiptTypeLabel ?? '',
          ].where((s) => s.isNotEmpty).join(' · '),
          cellBuilder: (context, row) => Text(
            [
              row.receiptNo ?? '—',
              row.receiptTypeLabel ?? '',
            ].where((s) => s.isNotEmpty).join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      EditableGridColumn(
        key: 'supplier',
        label: '供应商 / 委外商',
        width: 140,
        filterValueOf: (row) => row.supplierName,
        textOf: (row) => row.supplierName ?? '—',
        cellBuilder: (context, row) => Text(row.supplierName ?? '—'),
      ),
      EditableGridColumn(
        key: 'verdict',
        label: '判定结果',
        width: 108,
        // 2026-09-11 全站表头快速筛选补齐：合格/不合格混排的长明细里，判定结果
        // 与货品名是最常用的收敛口径（视图级过滤，不动数据与勾选）。
        filterValueOf: (row) => row.line.verdict.label,
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
      // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
      // 同名不同色的检查行经常上下挨着排（自制白色与委外香槟金是两条不同的
      // 放行行），只看名称会点错行放行。切片序号仍挂在名称右侧；筛选桶按各列
      // 自己的值分（编号/颜色列因此也能单独筛）。
      EditableGridColumn(
        key: 'goods',
        label: '货品名称',
        width: 200,
        filterValueOf: (row) => row.line.goodsName,
        cellBuilder: (context, row) => Tooltip(
          message: _goodsIdentityText(row) ?? '未命名货品',
          child: UtenGoodsIdentityCell(
            name: row.line.goodsName,
            emptyPlaceholder: '未命名货品',
            trailing: row.sliceTotal > 1 ? _sliceChip(context, row) : null,
          ),
        ),
      ),
      EditableGridColumn(
        key: 'goodsCode',
        label: '编号',
        width: 130,
        filterValueOf: (row) => row.line.goodsCode,
        cellBuilder: (context, row) =>
            UtenGoodsAttributeCell(row.line.goodsCode),
      ),
      EditableGridColumn(
        key: 'colorName',
        label: '颜色',
        width: 96,
        filterValueOf: (row) => row.line.colorName,
        cellBuilder: (context, row) =>
            UtenGoodsAttributeCell(row.line.colorName),
      ),
      EditableGridColumn(
        key: 'unit',
        label: '单位',
        width: 64,
        filterValueOf: (row) => row.unitName,
        cellBuilder: (context, row) => Text(row.unitName ?? '—'),
      ),
      EditableGridColumn(
        key: 'remaining',
        label: '合格待入量',
        width: 110,
        numeric: true,
        cellBuilder: (context, row) => Text(
          warehouseQualityQuantity(
            row.draft?.slice.remainingBaseQty ?? row.line.pendingStockBaseQty,
          ),
        ),
      ),
      if (editable)
        EditableGridColumn(
          key: 'quantity',
          label: '本次实收',
          width: 140,
          numeric: true,
          required: true,
          cellBuilder: (context, row) => _remainingCell(context, row),
        ),
      EditableGridColumn(
        key: 'warehouse',
        label: '目标叶仓',
        width: 160,
        required: editable,
        headerInfo: '本次实际入库仓库。来源建议仓可调整；每条放行明细独立保留所选叶仓。',
        filterValueOf: (row) => row.warehouseName,
        textOf: (row) => row.warehouseName ?? '未选择',
        cellBuilder: _warehouseCell,
      ),
      EditableGridColumn(
        key: 'place',
        label: '实际库位',
        width: 112,
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
        key: 'expectedAllocation',
        label: '预计去向',
        width: 220,
        cellBuilder: (context, row) => _expectedAllocationCell(context, row),
      ),
      EditableGridColumn(
        key: 'release',
        label: '放行信息',
        width: 250,
        // 单行省略号（2026-09-16 全站口径）+ 随文本自动加宽。
        textOf: (row) {
          final slice = row.draft?.slice;
          if (slice == null) return '—';
          final text = [
            if (slice.releasedBy?.isNotEmpty == true) '放行人 ${slice.releasedBy}',
            if (slice.releasedAt?.isNotEmpty == true)
              warehouseQualityDateTime(slice.releasedAt),
            if (slice.releaseNote?.isNotEmpty == true) slice.releaseNote!,
          ].join(' · ');
          return text.isEmpty ? '—' : text;
        },
        cellBuilder: (context, row) {
          final slice = row.draft?.slice;
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
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        },
      ),
    ];
  }

  /// 货品身份文本（名称 + 编号 · 颜色）：筛选桶名与 Tooltip 共用同一个来源。
  static String? _goodsIdentityText(WarehouseQualityMergedRow row) =>
      UtenGoodsIdentityCell.text(
        name: row.line.goodsName,
        code: row.line.goodsCode,
        color: row.line.colorName,
      );

  /// 同一明细行拆成多个放行切片时标注序号，避免误读为重复货品。
  Widget _sliceChip(BuildContext context, WarehouseQualityMergedRow row) =>
      Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s6,
          vertical: 1,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
          borderRadius: UtenRadius.smAll,
        ),
        child: Text(
          '切片 ${row.sliceOrdinal}/${row.sliceTotal}',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _warehouseCell(BuildContext context, WarehouseQualityMergedRow row) {
    final draft = row.draft;
    if (!editable || draft == null || !draft.canConfirm) {
      return Text(row.warehouseName ?? '未登记');
    }
    final enabled = draft.selected && !saving && onPickWarehouse != null;
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '${draft.goodsLabel} 目标叶仓：${row.warehouseName ?? '未选择'}',
      child: InkWell(
        key: ValueKey('quality-slice-warehouse-${draft.slice.passEventId}'),
        onTap: enabled ? () => onPickWarehouse!(draft) : null,
        borderRadius: UtenRadius.controlAll,
        child: InputDecorator(
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              enabled: enabled,
              error: utenFieldError(
                draft.selected ? draft.warehouseError : null,
              ),
            ),
            info:
                !draft.usesSuggestedWarehouse &&
                    draft.slice.warehouseName != null
                ? '来源建议仓：${draft.slice.warehouseName}。以本行选择的实际仓入库。'
                : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  row.warehouseName ?? '请选择',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 货品库位：可办理行 = 实际库位输入（选中后必填，描红框）；
  /// 只读切片行 = 建议库位提示；无切片行 = —。
  Widget _placeCell(BuildContext context, WarehouseQualityMergedRow row) {
    final draft = row.draft;
    final slice = draft?.slice;
    if (editable && draft != null && draft.canConfirm && slice != null) {
      return RequiredCellFrame(
        listenable: draft.place,
        isEmpty: () => draft.selected && draft.placeError != null,
        child: TextFormField(
          key: ValueKey('quality-slice-place-${slice.passEventId}'),
          controller: draft.place,
          enabled: draft.selected && !saving,
          maxLength: 100,
          errorBuilder: utenTextFieldErrorBuilder,
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              counterText: '',
              hintText: draft.placeInputHint,
              error: utenFieldError(draft.selected ? draft.placeError : null),
            ),
          ),
          onChanged: (_) => onChanged(),
        ),
      );
    }
    final place = draft?.place.text.trim();
    if (place?.isNotEmpty == true) {
      return Text(
        place!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    // 先入库后检(V596)：等结论的行实物已经在库位上，合格时按此位置自动转正。
    final preStocked = row.draft == null ? row.line.preStocked : null;
    if (preStocked?.place?.isNotEmpty == true) {
      return Tooltip(
        message: '已先入库上架：${preStocked!.label}，合格后自动转正入库',
        child: Text(
          '已上架 · ${preStocked.place}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: UtenColors.info,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return const Text('—');
  }

  /// 可办理行填写本次实收，单位随输入框显示；未放行或不可办理行只读。
  Widget _remainingCell(BuildContext context, WarehouseQualityMergedRow row) {
    final draft = row.draft;
    final slice = draft?.slice;
    if (editable && draft != null && draft.canConfirm && slice != null) {
      return RequiredCellFrame(
        listenable: draft.quantity,
        isEmpty: () => draft.selected && draft.quantityError != null,
        child: TextFormField(
          key: ValueKey('quality-slice-qty-${slice.passEventId}'),
          controller: draft.quantity,
          enabled: draft.selected && !saving,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [LengthLimitingTextInputFormatter(24)],
          errorBuilder: utenTextFieldErrorBuilder,
          decoration: UtenInputDecoration(
            InputDecoration(
              isDense: true,
              counterText: '',
              error: utenFieldError(
                draft.selected ? draft.quantityError : null,
              ),
              suffixText: draft.slice.unitName,
              suffixStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          onChanged: (_) => onChanged(),
        ),
      );
    }
    return const Text('—');
  }

  Widget _expectedAllocationCell(
    BuildContext context,
    WarehouseQualityMergedRow row,
  ) {
    final draft = row.draft;
    if (draft == null) return const Text('—');
    if (!draft.usesSuggestedWarehouse) {
      return Text(
        draft.warehouseId == null ? '选定目标叶仓后，提交时核定去向' : '目标叶仓已调整，提交时重新核定去向',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: draft.quantity,
      builder: (context, _, _) {
        final requested = draft.previewQuantity;
        final section = WarehouseInboundAllocationSection(
          id: draft.slice.passEventId,
          goodsLabel: draft.slice.goodsLabel,
          quantity: requested,
          unitName: draft.slice.unitName,
          sourceOrderNo: draft.slice.sourceOrderNo,
          allocations: draft.slice.expectedAllocations,
        );
        return WarehouseInboundAllocationSummary(
          allocations: draft.slice.expectedAllocations,
          previewQty: requested,
          qtyText: warehouseQualityQuantity,
          onTap: () => showWarehouseInboundAllocationDetails(
            context,
            title: '预计去向 · ${draft.slice.goodsLabel}',
            sections: [section],
          ),
        );
      },
    );
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
