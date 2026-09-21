// 单据列表页分段计数(GET /documents/status-counts?kind=...) + 三类单据「财务已退回」张数
// (GET /documents/finance-rejected/count)。
//
// 2026-09-21 用户口径: 「父分类有红色通知徽章, 子分类也要有数字」——hub 单据卡挂了红徽章
// (草稿 / 财务已退回)的列表页, 状态分段一律带数: 草稿与财务已退回是红徽章(等本人动手),
// 等待财务审核 / 已审 / 已出库 / 红冲是中性括号数(供掂量); 「财务退回」不再混在草稿里,
// 有自己的分段与徽章(后端草稿口径同步收紧, 见 DocumentDraftCountQueryService)。
//
// 计数与列表同一对象级读范围, 一次请求带回该类型全部桶; 分桶键见 [DocumentStatusBucket]。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../auth/permissions.dart';
import 'draft_counts_provider.dart';

const _pollInterval = Duration(seconds: 60);

/// 分桶键(与后端 DocumentStatusCountQueryService 逐字一致)。
abstract final class DocumentStatusBucket {
  static const draft = 'DRAFT';
  static const pendingFinance = 'PENDING_FINANCE';
  static const financeRejected = 'FINANCE_REJECTED';

  /// 通用单据 = 已审(status 1); 销售出货 = 财务已放行待出库(status 0 + finance_audit 1)。
  static const approved = 'APPROVED';
  static const shipped = 'SHIPPED';
  static const reversed = 'REVERSED';
}

/// 一次分段计数的范围: 单据类型 + 出货类型切片(仅 salesShipment, 客户零星发货列表传
/// DIRECT_CUSTOMER) + 仓库单据类型(仅 stockDocument)。作 family 键, 值相等即同一份计数。
class DocumentStatusScope {
  const DocumentStatusScope(this.kind, {this.shipmentKind, this.docType});

  final DraftDocKind kind;
  final String? shipmentKind;
  final String? docType;

  @override
  bool operator ==(Object other) =>
      other is DocumentStatusScope &&
      other.kind == kind &&
      other.shipmentKind == shipmentKind &&
      other.docType == docType;

  @override
  int get hashCode => Object.hash(kind, shipmentKind, docType);
}

/// 列表页分段计数: 桶键 → 张数。autoDispose——只在列表页打开期间 60s 轮询, 列表重拉/
/// 写操作成功后由页面 `ref.invalidate(documentStatusCountsProvider(scope))` 立即重取;
/// 无该类型 *:view 权限不发请求(返回空表, 分段不渲染数字)。
final documentStatusCountsProvider = FutureProvider.autoDispose
    .family<Map<String, int>, DocumentStatusScope>((ref, scope) async {
      final permissions = ref.watch(currentPermissionsProvider);
      if (!ref.watch(isSuperAdminProvider) &&
          !permissions.contains(scope.kind.viewPerm)) {
        return const {};
      }
      final timer = Timer(_pollInterval, ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      final json = await ref
          .watch(apiClientProvider)
          .get(
            ApiEndpoints.documentStatusCounts,
            query: {
              'kind': scope.kind.name,
              if (scope.shipmentKind != null)
                'shipmentKind': scope.shipmentKind,
              if (scope.docType != null) 'docType': scope.docType,
            },
          );
      return {
        for (final entry in json.entries)
          if (entry.value is num) entry.key: (entry.value as num).toInt(),
      };
    });

/// 三类单据的「财务已退回」张数快照。
class FinanceRejectedCounts {
  const FinanceRejectedCounts({
    this.salesShipment = 0,
    this.purchaseOrder = 0,
    this.subcontractOrder = 0,
  });

  factory FinanceRejectedCounts.fromJson(Map<String, dynamic> json) {
    int read(String key) => (json[key] as num?)?.toInt() ?? 0;
    return FinanceRejectedCounts(
      salesShipment: read('salesShipment'),
      purchaseOrder: read('purchaseOrder'),
      subcontractOrder: read('subcontractOrder'),
    );
  }

  static const empty = FinanceRejectedCounts();

  final int salesShipment;
  final int purchaseOrder;
  final int subcontractOrder;

  /// 该类型的财务已退回张数; 没有退回桶的类型恒 0。
  int of(DraftDocKind kind) => switch (kind) {
    DraftDocKind.salesShipment => salesShipment,
    DraftDocKind.purchaseOrder => purchaseOrder,
    DraftDocKind.subcontractOrder => subcontractOrder,
    _ => 0,
  };

  /// 有「财务已退回」桶、hub 卡徽章要算「草稿 + 财务已退回」的三类单据。
  static const kinds = {
    DraftDocKind.salesShipment,
    DraftDocKind.purchaseOrder,
    DraftDocKind.subcontractOrder,
  };
}

/// 三类单据的「财务已退回」张数(hub 单据卡徽章 = 草稿 + 财务已退回; 销售出货退回件经
/// [salesShipmentFinanceRejectedCountProvider] 登记进销售待办累加)。
// 徽章计数 provider 一律**常驻**(不 autoDispose)并自带 60s 轮询——与 draftCountsProvider
// 同款: 离开页面不销毁, 刷新期间带住旧值, 徽章不闪; bumpListRefresh / invalidateTodoBadgeCaches
// 在写操作成功后主动失效。
final financeRejectedCountsProvider = FutureProvider<FinanceRejectedCounts>((
  ref,
) async {
  final permissions = ref.watch(currentPermissionsProvider);
  final anyVisible =
      ref.watch(isSuperAdminProvider) ||
      FinanceRejectedCounts.kinds.any(
        (kind) => permissions.contains(kind.viewPerm),
      );
  if (!anyVisible) return FinanceRejectedCounts.empty;
  final timer = Timer(_pollInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final json = await ref
      .watch(apiClientProvider)
      .get(ApiEndpoints.documentFinanceRejectedCounts);
  return FinanceRejectedCounts.fromJson(json);
});

/// 销售出货「财务已退回」张数 = TodoEntry.salesShipmentFinanceRejected 的计数源。
///
/// 由 [financeRejectedCountsProvider] 派生(同一次请求), 失效要打在源头; 采购/委外订货的
/// 退回件已由各自任务中心的 FINANCE_REJECTED 计入待办, 不再另行登记(同一件活只数一次)。
final salesShipmentFinanceRejectedCountProvider = FutureProvider<int>((
  ref,
) async {
  final counts = await ref.watch(financeRejectedCountsProvider.future);
  return counts.salesShipment;
});
