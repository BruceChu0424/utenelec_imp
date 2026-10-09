// 生产单据状态徽章：草稿 / 已审 / 红冲 + 结案/中止/取消 副标。
//
// 与采购/委外/销售同款 0/1/-1 状态机；ADR-169 后渲染走共享 UtenStatusBadge
// 深色实底档位（原 UtenDocStatusPill + raw Color 浅底胶囊已收编）。
// 生产多出 is_closed/is_stopped/is_canceled 三个布尔，按优先级
// 中止 > 取消 > 结案 拼到主标签后。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/doc_status_badge.dart';
import '../models/production_plan.dart';

class ProductionStatusBadge extends StatelessWidget {
  const ProductionStatusBadge({
    super.key,
    required this.status,
    this.closed = false,
    this.stopped = false,
    this.canceled = false,
  });

  final int? status;
  final bool closed;
  final bool stopped;
  final bool canceled;

  @override
  Widget build(BuildContext context) {
    // 副标优先级：红冲已反向，不再追加；草稿不追加；仅已审追加结案/中止/取消。
    String suffix = '';
    if (status == kProductionStatusApproved) {
      if (stopped) {
        suffix = '·中止';
      } else if (canceled) {
        suffix = '·取消';
      } else if (closed) {
        suffix = '·结案';
      }
    }
    return UtenStatusBadge(
      label: '${productionStatusLabel(status)}$suffix',
      type: docStatusBadgeType(status),
    );
  }
}
