import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../paging/paged_read_intent.dart';
import '../paging/versioned_summary_read.dart';
import '../models/subcontract_short_delivery.dart';

/// 供应商委外损耗汇总(ADR-098, /subcontract/short-deliveries/supplier-summary)。
///
/// 放在 shared 是因为供应商详情页(basic_data)与委外判定页都要读同一份汇总，
/// 而 basic_data 不能反向依赖 subcontract feature(架构边界测试锁边)。
const subcontractSupplierLossSummaryPath =
    '/subcontract/short-deliveries/supplier-summary';

Future<SubcontractSupplierLossSummary> loadSubcontractSupplierLossSummary(
  ApiClient api,
  String supplierId,
) async {
  final parent = PagedReadIntent.currentRead;
  final owner = await api.captureRequestScope(
    isCurrent: () => parent?.call() ?? true,
  );
  return owner.run(() async {
    final snapshot =
        await readVersionedSummarySnapshot<SubcontractGoodsLossRow>(
          isCurrent: () => owner.isCurrent,
          batchSize: 1000,
          idOf: (row) => row.goodsId,
          decode: SubcontractGoodsLossRow.fromJson,
          loadPage: (page, size, revision) => api.get(
            '$subcontractSupplierLossSummaryPath/goods/summaries',
            query: {
              'supplierId': supplierId,
              'page': page,
              'size': size,
              'readSnapshotRevision': ?revision,
            },
          ),
        );
    final metadata = snapshot.metadata['summary'];
    if (metadata is! Map) {
      throw ApiException('INCOMPLETE_READ_PROTOCOL', '供应商损耗摘要未完整读取');
    }
    final head = SubcontractSupplierLossSummary.fromJson(
      Map<String, dynamic>.from(metadata),
    );
    if (head.supplierId.toLowerCase() != supplierId.toLowerCase() ||
        head.byGoods.isNotEmpty) {
      throw ApiException('INCOMPLETE_READ_PROTOCOL', '供应商损耗摘要来源不一致');
    }
    // Rows were already decoded responsively inside the shared complete
    // reader. Keep every exact decimal/header/history field without a second
    // synchronous walk of the complete goods collection.
    return SubcontractSupplierLossSummary(
      exactNumbers: head.exactNumbers,
      supplierId: head.supplierId,
      settledLineCount: head.settledLineCount,
      acceptedLossCount: head.acceptedLossCount,
      orderedQty: head.orderedQty,
      lossQty: head.lossQty,
      lossPct: head.lossPct,
      maxLossPct: head.maxLossPct,
      lastLossAt: head.lastLossAt,
      byGoods: snapshot.items,
      recentCases: head.recentCases,
    );
  });
}
