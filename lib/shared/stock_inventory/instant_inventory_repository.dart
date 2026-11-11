// Authorized read-only inventory projection; no balance mutation or local totals.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../models/paged_result.dart';
import '../paging/complete_paged_snapshot.dart';
import '../paging/complete_summary_stream.dart';
import '../paging/paged_read_intent.dart';
import '../paging/versioned_summary_read.dart';
import 'instant_inventory_row.dart';

class InstantInventoryRepository {
  InstantInventoryRepository(this._api);

  final ApiClient _api;

  /// 即时库存分页（货品+颜色聚合余额；categoryId=分类含子树 / warehouseId=仓库 / keyword 模糊）。
  /// includeDefective=「含不良品仓」开关(仅仓库=全部/主仓聚合时生效；ADR-146 默认 false，
  /// 打开后每行另带 defectiveQty 与合计「其中不良品数量」)。
  /// 2026-09-16 起表头筛选：owningWarehouse=归属仓库 UUID；colorId/series/unitId=颜色/
  /// 物料系列/单位列筛选（值为颜色 UUID / 系列文本 / 单位 UUID，桶由列表响应 facets 下发）。
  /// attention 为服务器白名单行动规则；明细和 totals 包含规则筛选，facets 保持基础范围。
  /// warehouseRelatedOnly 仅保留所选仓范围内有余额或收货记录的货品+颜色，
  /// 用于仓库资料内的库存表，避免全公司零库存货品占位。
  /// 行动清单使用专用路由，旧服务端必须明确失败，不能把忽略规则的全量数据当风险。
  /// [includeMetadata]=false(完整读取的续批)按共享读取计划只取同口径的行与计数，
  /// 合计与表头桶只在首批由服务端在整个结果集上计算。
  Future<PagedResult<InstantInventoryRow>> instantInventory({
    int page = 1,
    int size = 20,
    bool includeMetadata = true,
    String? categoryId,
    String? warehouseId,
    bool includeDefective = false,
    bool includeLineSide = false,
    bool warehouseRelatedOnly = false,
    String? keyword,
    bool includeRelated = false,
    String? owningWarehouse,
    bool owningWarehouseNull = false,
    String? colorId,
    String? series,
    String? unitId,
    String? attention,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
  }) async {
    final json = await _api.get(
      attention == null
          ? ApiEndpoints.stockInstantInventory
          : '${ApiEndpoints.stockInstantInventory}/attention',
      query: {
        'page': page,
        'size': size,
        if (!includeMetadata) ...{
          'includeTotals': false,
          'includeFacets': false,
        },
        'categoryId': ?categoryId,
        'warehouseId': ?warehouseId,
        'includeDefective': includeDefective,
        // V595：线边仓(车间直送料架)默认不算进现实库存，显式打开才计入。
        if (includeLineSide) 'includeLineSide': true,
        if (warehouseRelatedOnly) 'warehouseRelatedOnly': true,
        if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
        if (includeRelated && keyword?.trim().isNotEmpty == true)
          'includeRelated': true,
        // V587/V590 归属表头筛选：UUID 等值 / 未登记。
        'owningWarehouse': ?owningWarehouse,
        if (owningWarehouseNull) 'owningWarehouseNull': true,
        // 2026-09-16 颜色/物料系列/单位表头筛选。
        'colorId': ?colorId,
        'series': ?series,
        'unitId': ?unitId,
        'attention': ?attention,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        if (order != null && order.isNotEmpty) 'order': order,
      },
    );
    return PagedResult.fromJson(json, InstantInventoryRow.fromJson);
  }

  /// 完整流（2026-11-09）：一个 NDJSON 响应内按共享批次计划连续分帧，服务端在同一个
  /// RR 快照里单扫描完成全部批次——不再每批一次 OFFSET 请求（3.5 万行实测约 80 秒的
  /// 根因）。首批 50 行带合计与表头桶（与 GET 首批同口径），续批只取行与计数；帧校验、
  /// 三凭据与逐批追加发布走与主档完整流同一套公共件（CompleteSummaryStream +
  /// readVersionedSummarySnapshot）。分页读取仍走 [instantInventory]。
  Future<PagedResult<InstantInventoryRow>> completeStream({
    String? categoryId,
    String? warehouseId,
    bool includeDefective = false,
    bool includeLineSide = false,
    bool warehouseRelatedOnly = false,
    String? keyword,
    bool includeRelated = false,
    String? owningWarehouse,
    bool owningWarehouseNull = false,
    String? colorId,
    String? series,
    String? unitId,
    String? attention,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
  }) async {
    // Captured before any await: the view's progressive slot lives in the zone
    // of the ScopedPagedRead that owns these rows.
    final progressive = PagedReadIntent.currentProgressive;
    final parent = PagedReadIntent.currentRead;
    final owner = await _api.captureRequestScope(
      isCurrent: () => parent?.call() ?? true,
    );
    final filter = Map<String, dynamic>.unmodifiable({
      'categoryId': ?categoryId,
      'warehouseId': ?warehouseId,
      if (includeDefective) 'includeDefective': true,
      if (includeLineSide) 'includeLineSide': true,
      if (warehouseRelatedOnly) 'warehouseRelatedOnly': true,
      if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
      if (includeRelated && keyword?.trim().isNotEmpty == true)
        'includeRelated': true,
      'owningWarehouse': ?owningWarehouse,
      if (owningWarehouseNull) 'owningWarehouseNull': true,
      'colorId': ?colorId,
      'series': ?series,
      'unitId': ?unitId,
      'attention': ?attention,
      'dateFrom': ?dateFrom,
      'dateTo': ?dateTo,
    });
    return owner.run(
      () => _api.postSummaryStream<PagedResult<InstantInventoryRow>>(
        '${ApiEndpoints.stockInstantInventory}/summaries',
        body: {
          'filter': filter,
          'page': 1,
          // Selects the progressive frame plan: 50 rows first, then aligned
          // growth up to the shared bounded maximum.
          'size': kProgressiveSummaryStreamSize,
          if (sort?.isNotEmpty == true) 'sort': sort,
          if (order?.isNotEmpty == true) 'order': order,
        },
        consume: (frames) async {
          final stream = CompleteSummaryStream(
            frames,
            plan: CompleteReadBatchPlan.progressive,
            frameIdleTimeout: _api.summaryStreamChunkIdleTimeout,
          );
          // This complete read owns the view's rows, so it claims the slot
          // unless another reader in the same zone already did.
          final publish = progressive != null && progressive.claim()
              ? progressive.publish
              : null;
          try {
            final result =
                await readVersionedSummarySnapshot<InstantInventoryRow>(
                  isCurrent: () => owner.isCurrent,
                  decode: InstantInventoryRow.fromJson,
                  idOf: (row) => row.readIdentity,
                  plan: CompleteReadBatchPlan.progressive,
                  loadPage: stream.page,
                  onProgressiveBatch: publish == null
                      ? null
                      : (partial) {
                          if (owner.isCurrent) {
                            publish(partial as PagedResult<Object?>);
                          }
                        },
                );
            return result.page;
          } finally {
            await stream.close();
          }
        },
      ),
    );
  }
}

final instantInventoryRepositoryProvider = Provider<InstantInventoryRepository>(
  (ref) => InstantInventoryRepository(ref.watch(apiClientProvider)),
);
