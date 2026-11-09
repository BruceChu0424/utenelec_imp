import '../../../core/formatters/exact_number_text.dart';
// ADR-143 委外「待处理·领料」的状态词表与整格底色。
//
// 档位按 ADR-169 锚定（色值用共享 UtenColors.status* 十档，不再自留一份）：
// 绿 = 可领(剩余全部)·去领料（就绪可动手）/ 紫 = 部分可领（部分就绪）/
// 青 = 已提交领料·待仓库发料（等仓库，与等财务的黄档拉开）/
// 红 = 等计划安排（还缺的物料没有在途供应，锁死要计划先安排）、
// 等待物料（料没到不能领）——「不能执行」不是等待（2026-10-08 用户口径），
// 两档同红靠文案区分（缺 N 种 / 已备 X/Y 种）。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
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
/// 状态说的是整套能不能领(批量领料按套)；各物料的实物数量看「物料」列弹窗，不在状态里
/// 拼单个数——委外件可能有很多种直属物料，一个数说不清(2026-11-09)。
String subcontractDrawStatusLabel(
  SubcontractDrawTaskRow row, {
  required bool actionable,
}) {
  switch (row.status) {
    case SubcontractDrawStatus.drawable:
    case SubcontractDrawStatus.drawablePartial:
      final label = row.status == SubcontractDrawStatus.drawablePartial
          ? '部分物料可领'
          : '物料可领';
      return actionable ? '$label·去领料' : label;
    case SubcontractDrawStatus.drawSubmitted:
      return '已提交领料·待仓库发料';
    case SubcontractDrawStatus.waitingPlanning:
      return '等计划安排·缺 ${row.unplannedShortKindCount} 种';
    case SubcontractDrawStatus.waitingMaterial:
    case SubcontractDrawStatus.unknown:
      return '等待物料·已备 ${row.readyKindCount}/${row.materialKindCount} 种';
  }
}

/// 状态悬停说明：可领与待仓库发同时存在时两者都说；其余状态说明下一步由谁动手。
String subcontractDrawStatusTooltip(SubcontractDrawTaskRow row) {
  switch (row.status) {
    case SubcontractDrawStatus.drawable:
    case SubcontractDrawStatus.drawablePartial:
      return [
        subcontractDrawStatusLabel(row, actionable: false),
        if (row.pendingKindCount > 0) '另有 ${row.pendingKindCount} 种物料待仓库发料',
        '各物料的数量点「物料」列查看',
      ].join('，');
    case SubcontractDrawStatus.drawSubmitted:
      return '已提交领料，等仓库发出';
    case SubcontractDrawStatus.waitingPlanning:
      return '备料差额没有采购、生产或委外在途';
    case SubcontractDrawStatus.waitingMaterial:
    case SubcontractDrawStatus.unknown:
      return '备料差额有在途供应，到货入库后会提醒领料';
  }
}

/// 物料行状态(任务详情、物料弹窗与订货单进度共用，服务端同一判定只取一个)。
/// 2026-11-09 起「本次可领」逐种独立(其它物料还缺也能先领到货的物料)，可领优先于缺口；
/// READY = 不缺但本任务此刻不能领(如已结清)。
String subcontractDrawMaterialStateLabel(SubcontractDrawMaterial material) =>
    switch (material.state.toUpperCase()) {
      'SENT_FULL' => '已发齐',
      'DRAWABLE' => material.shortQty > 0 ? '部分可领' : '可领',
      'PENDING' => '待仓库发料',
      'SHORT' => '备料未满',
      'READY' => '已备',
      'CLOSED' => '已结束领料',
      _ => '—',
    };

/// 物料行状态档位（ADR-169，与任务行口径对齐）：可领=绿（就绪可动手）/ 部分可领=紫
/// （到了一部分、还差一些）/ 待仓库发料=青（等仓库发料，与等财务的黄档拉开）/
/// 备料未满=红（无货可领）/ 已备=紫 / 已发齐·已结束领料=灰；未知无档。
UtenStatusBadgeType? subcontractDrawMaterialBadgeType(
  SubcontractDrawMaterial material,
) => switch (material.state.toUpperCase()) {
  'SENT_FULL' || 'CLOSED' => UtenStatusBadgeType.neutral,
  'PENDING' => UtenStatusBadgeType.sky,
  'DRAWABLE' =>
    material.shortQty > 0
        ? UtenStatusBadgeType.violet
        : UtenStatusBadgeType.success,
  'SHORT' => UtenStatusBadgeType.danger,
  'READY' => UtenStatusBadgeType.violet,
  _ => null,
};

/// 物料行「状态」列整格底色（与 [subcontractDrawMaterialBadgeType] 同一档位）。
Color? subcontractDrawMaterialCellColor(SubcontractDrawMaterial material) =>
    switch (subcontractDrawMaterialBadgeType(material)) {
      final type? => utenStatusBadgeCellColor(type),
      null => null,
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
            '${subcontractDrawQty(source.quantityText('openQty'))}'
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

/// 保留已记数量的完整有效小数。
String subcontractDrawQty(Object? value) => exactNumberDisplay(value) ?? '—';
