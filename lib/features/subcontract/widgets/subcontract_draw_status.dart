// ADR-143 委外「待处理·领料」的状态词表与整格底色。
//
// 档位按 ADR-169 锚定（色值用共享 UtenColors.status* 十档，不再自留一份）：
// 绿 = 可领(剩余全部)·去领料（就绪可动手）/ 紫 = 部分可领（部分就绪）/
// 青 = 已提交领料·待仓库发料（等仓库，与等财务的黄档拉开）/
// 红 = 等计划安排（还缺的物料没有在途供应，锁死要计划先安排）、
// 等待物料（料没到不能领）——「不能执行」不是等待（2026-10-08 用户口径），
// 两档同红靠文案区分（缺 N 种 / 已备 X/Y 种）。
import 'package:flutter/material.dart';

import '../../../core/theme/uten_colors.dart';
import '../models/subcontract_draw.dart';

enum SubcontractDrawTone {
  toDraw,
  toDrawPartial,
  pending,
  waitPlanning,
  waiting,
}

SubcontractDrawTone subcontractDrawToneOf(SubcontractDrawStatus status) =>
    switch (status) {
      SubcontractDrawStatus.drawable => SubcontractDrawTone.toDraw,
      SubcontractDrawStatus.drawablePartial =>
        SubcontractDrawTone.toDrawPartial,
      SubcontractDrawStatus.drawSubmitted => SubcontractDrawTone.pending,
      SubcontractDrawStatus.waitingPlanning => SubcontractDrawTone.waitPlanning,
      SubcontractDrawStatus.waitingMaterial ||
      SubcontractDrawStatus.unknown => SubcontractDrawTone.waiting,
    };

/// 状态列整格底色（共享十档实底，深浅两主题同色，文字黑白由表格 cellColor
/// 约定自适应）。
Color subcontractDrawCellColor(SubcontractDrawTone tone) => switch (tone) {
  SubcontractDrawTone.toDraw => UtenColors.statusSuccess,
  SubcontractDrawTone.toDrawPartial => UtenColors.statusViolet,
  SubcontractDrawTone.pending => UtenColors.statusSky,
  SubcontractDrawTone.waitPlanning => UtenColors.statusDanger,
  SubcontractDrawTone.waiting => UtenColors.statusDanger,
};

IconData subcontractDrawToneIcon(SubcontractDrawTone tone) => switch (tone) {
  SubcontractDrawTone.toDraw ||
  SubcontractDrawTone.toDrawPartial => Icons.move_to_inbox_rounded,
  SubcontractDrawTone.pending => Icons.local_shipping_outlined,
  SubcontractDrawTone.waitPlanning => Icons.event_note_outlined,
  SubcontractDrawTone.waiting => Icons.hourglass_empty_rounded,
};

/// 状态列文案。[actionable] = 本账号可提交本行领料(可领行才追加「·去领料」)。
String subcontractDrawStatusLabel(
  SubcontractDrawTaskRow row, {
  required bool actionable,
}) {
  final unit = row.unitName.trim();
  switch (row.status) {
    case SubcontractDrawStatus.drawable:
    case SubcontractDrawStatus.drawablePartial:
      final qty =
          '可领 ${subcontractDrawQty(row.drawableQty)}'
          '${unit.isEmpty ? '' : ' $unit'}';
      return actionable ? '$qty·去领料' : qty;
    case SubcontractDrawStatus.drawSubmitted:
      return '已提交领料·待仓库发料';
    case SubcontractDrawStatus.waitingPlanning:
      return '等计划安排·缺 ${row.unplannedShortKindCount} 种';
    case SubcontractDrawStatus.waitingMaterial:
    case SubcontractDrawStatus.unknown:
      return '等待物料·已备 ${row.readyKindCount}/${row.materialKindCount} 种';
  }
}

/// 可领与待仓库发同时存在时悬浮提示两者；其余状态说明下一步由谁动手。
String? subcontractDrawStatusTooltip(SubcontractDrawTaskRow row) {
  final unit = row.unitName.trim();
  String qty(double value) =>
      '${subcontractDrawQty(value)}${unit.isEmpty ? '' : ' $unit'}';
  switch (row.status) {
    case SubcontractDrawStatus.drawable:
    case SubcontractDrawStatus.drawablePartial:
      final partial = row.status == SubcontractDrawStatus.drawablePartial
          ? '；其余还缺物料，到货后可继续领'
          : '';
      return row.pendingQty > 0
          ? '可领 ${qty(row.drawableQty)}；另有 ${qty(row.pendingQty)}已提交领料，等仓库发料$partial'
          : '现有库存可配齐 ${qty(row.drawableQty)}$partial';
    case SubcontractDrawStatus.drawSubmitted:
      return '已提交 ${qty(row.pendingQty)} 的领料，等仓库发出';
    case SubcontractDrawStatus.waitingPlanning:
      return '还缺的物料没有采购、生产或委外在途，请联系计划安排';
    case SubcontractDrawStatus.waitingMaterial:
    case SubcontractDrawStatus.unknown:
      return '还缺的物料已在途，到货入库后自动提醒可领';
  }
}

/// 物料行状态(领料任务详情与订货单进度共用)。物料本身已齐(DRAWABLE)但本批可领为 0
/// (被同一任务的其它物料卡住)时计为「已备」(ADR-143 §三.4)。
String subcontractDrawMaterialStateLabel(SubcontractDrawMaterial material) =>
    switch (material.state.toUpperCase()) {
      'SENT_FULL' => '已发齐',
      'PENDING' => '待仓库发料',
      'DRAWABLE' => material.drawableQty > 0 ? '可领' : '已备',
      'SHORT' => '缺料',
      'CLOSED' => '已结束领料',
      _ => '—',
    };

/// 物料行「状态」列整格底色（任务详情与订货单进度共用，档位对齐
/// [subcontractDrawCellColor] 的任务行口径）：可领=绿（就绪可动手）/
/// 已备=紫（本物料已齐、被同批其它物料卡住——部分齐套，同任务行「部分可领
/// =紫」）/ 待仓库发料=青（等仓库发料，与等财务的黄档拉开）/ 缺料=红
/// （料没到或在途未到都不能领——「不能执行」不是等待，不区分有无在途，
/// 文案与供应来源列区分）/ 已发齐·已结束领料=灰（办结终态）；未知无色。
Color? subcontractDrawMaterialCellColor(SubcontractDrawMaterial material) =>
    switch (material.state.toUpperCase()) {
      'SENT_FULL' || 'CLOSED' => UtenColors.statusNeutral,
      'PENDING' => UtenColors.statusSky,
      'DRAWABLE' =>
        material.drawableQty > 0
            ? UtenColors.statusSuccess
            : UtenColors.statusViolet,
      'SHORT' => UtenColors.statusDanger,
      _ => null,
    };

/// 物料行「供应来源」列(领料任务详情与订货单进度共用)：服务端只给还缺的开放行带在途来源；
/// 还缺却没有任何在途 = 「未安排」(要计划去下单)，不缺 = 「—」。
String subcontractDrawSupplyText(SubcontractDrawMaterial material) {
  if (material.supplySources.isEmpty) {
    return material.shortQty > 0 ? '未安排' : '—';
  }
  return material.supplySources
      .map(
        (source) =>
            '${subcontractDrawSupplyKindLabel(source.kind)} '
            '${subcontractDrawQty(source.openQty)}'
            '${source.docNo.isEmpty ? '' : '(${source.docNo})'}',
      )
      .join('；');
}

/// 供应来源类别。
String subcontractDrawSupplyKindLabel(String kind) =>
    switch (kind.toUpperCase()) {
      'PURCHASE' => '采购在途',
      'PRODUCTION' => '车间生产',
      'SUBCONTRACT' => '委外在途',
      _ => '在途',
    };

/// 数量显示：最多 4 位小数，去掉末尾 0。
String subcontractDrawQty(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');
