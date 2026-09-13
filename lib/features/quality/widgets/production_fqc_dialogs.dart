// 生产成品质检（FQC）共享文案口径。
//
// 2026-09-12 起 FQC 的详情/决定/检查单办理从弹窗改为独立页面
//（production_fqc_handling_page.dart，对齐采购 IQC 处置页范式），
// 本文件原三个弹窗类随之退役；这里保留全站仍在用的状态与数量文案函数。

import '../models/production_fqc_inspection.dart';

/// FQC 状态中文口径（列表列、详情头部共用）。
String fqcStatusLabel(ProductionFqcInspection inspection) =>
    switch (inspection.status) {
      'PENDING' => '待检',
      'PARTIAL' => '部分已决定',
      'RESOLVED' => '已全部决定',
      'CANCELLED' => '已取消（来源报工红冲或登记撤回）',
      _ => inspection.status,
    };

/// 数量展示（去尾零，保留实际精度）。
String fqcQtyText(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');
