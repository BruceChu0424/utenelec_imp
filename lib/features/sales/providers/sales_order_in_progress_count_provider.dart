// 订单进度查询的在途订单数(销售模块唯一的黄色进行中徽章入口，ADR-100)。
//
// 口径 = 已审订单里「还在跑、此刻不用销售动手」的四个阶段：待排产 + 生产中 +
// 出货待财审 + 等仓库出货。按**订单**数，与页内同名分段同源(同一份
// stage-counts)，所以卡面数字 = 页内四个黄段之和。
//
// 刻意不含：
// · REJECTED(财务驳回)与 SHIPPABLE(可分批发货)——那两档要销售改单/开单，
//   是红色待办，已由 salesAttentionCountProvider 计入，黄红两条链各计各的；
// · 出货 / 订货 / 报价 / 退货四张单据卡的在途数——「出货待财审 / 等仓库出货」
//   本就是从出货单派生的(服务端 progressStageExpr 看 shipment_*_qty)，
//   再按单据数一遍就是同一批出货翻倍。

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../models/sales_doc.dart';
import '../repositories/sales_repository.dart';

const _pollInterval = Duration(seconds: 60);

/// 在途阶段(服务端 stage 取值，与订单进度页分段用的是同一串常量)。
const _inFlightStages = <String>[
  'PENDING',
  'PRODUCING',
  'SHIPMENT_PENDING',
  'WAREHOUSE_PENDING',
];

/// 订单进度在途订单数(黄色进行中徽章)。
///
/// 徽章计数 provider 一律**常驻**(不 autoDispose)：autoDispose 的那些离开页面
/// 即销毁、回来从零 loading，表现为「点进去要等一会徽章才出现」。常驻后
/// invalidateSelf 期间 AsyncValue 会带住上一次的数(见 in_progress_badge_registry
/// 的 valueOrNull)，徽章不闪；没人看时定时器不再续期，也不会空转发请求。
/// 无 `sales_order:view` 权限时固定 0 且不发请求。
final salesOrderInProgressCountProvider = FutureProvider<int>((ref) async {
  if (!ref.watch(currentPermissionsProvider).contains(Perm.salesOrderView) &&
      !ref.watch(isSuperAdminProvider)) {
    return 0;
  }
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final counts = await ref
      .watch(salesRepositoryProvider(SalesDocType.order))
      .progressStageCounts();
  var total = 0;
  for (final stage in _inFlightStages) {
    total += counts[stage] ?? 0;
  }
  return total;
});
