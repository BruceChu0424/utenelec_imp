import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/table_load_progress_notice.dart';
import 'package:uten_imp/features/stock/pages/instant_inventory_page.dart';
import 'package:uten_imp/features/stock/repositories/stock_query_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/complete_read_progress.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/stock_inventory/instant_inventory_row.dart';

import '../../support/pump_until.dart';

/// 即时库存真实页驱动顶部加载进度通知（2026-11-09 用户实测「即时库存也没
/// 显示」排查）：页面自动发起的完整读取（50→50→100→200 阶梯）必须让卡片
/// 在半途出现、完成后铺满并自动收起。
void main() {
  testWidgets(
    'InstantInventory real page drives the top load progress notice',
    (tester) async {
      final events = <String>[];
      void onEvent(CompleteReadProgressEvent e) =>
          events.add('${e.phase.name}(${e.loaded}/${e.total})');
      CompleteReadProgressReporter.addListener(onEvent);
      addTearDown(() => CompleteReadProgressReporter.removeListener(onEvent));

      final stock = _GatedStockRepository();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            apiClientProvider.overrideWithValue(_GatedApi()),
            stockQueryRepositoryProvider.overrideWithValue(stock),
            currentPermissionsProvider.overrideWithValue(const <String>{
              Perm.stockView,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            home: Stack(
              children: [
                InstantInventoryPage(),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: TableLoadProgressNoticeHost(),
                ),
              ],
            ),
          ),
        ),
      );

      // 首批 50 行已到（总量 600），第 2 批被闸门挂住：跨过出现门槛后卡片应在。
      await pumpUntil(
        tester,
        () => events.any((e) => e.startsWith('batch')),
        reason: 'No validated batch reached the progress reporter',
        timeout: const Duration(seconds: 10),
      );
      await tester.pump(
        tableLoadNoticeShowDelay + const Duration(milliseconds: 50),
      );
      expect(
        find.textContaining('正在加载数据'),
        findsOneWidget,
        reason: '即时库存完整读取必须驱动顶部进度卡',
      );
      expect(find.byTooltip('关闭加载提示'), findsOneWidget);

      // 放行尾批：完整结果到达 → 完成态 → 自动收起。
      stock.releaseBatch2();
      await pumpUntil(
        tester,
        () => events.any((e) => e.startsWith('succeeded')),
        reason: 'Complete result did not finish',
        timeout: const Duration(seconds: 10),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('数据加载完成：100%'), findsOneWidget);
      await tester.pump(tableLoadNoticeDoneHold);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('数据加载完成'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

/// 仓储基类需要一个 ApiClient；本测试不触网。
/// postSummaryStream 走真实链路（CompleteSummaryStream + readVersionedSummarySnapshot），
/// 与货品页实证测试同款：帧流按共享批次计划切片，第 2 帧（page 2, size 50）挂闸门。
class _GatedApi extends ApiClient {
  _GatedApi([Completer<void>? gate]) : _batch2 = gate, super(Dio());

  final Completer<void>? _batch2;

  static const _total = 600;

  @override
  Future<T> postSummaryStream<T>(
    String path, {
    required Object body,
    required Future<T> Function(Stream<Map<String, dynamic>>) consume,
  }) async {
    const plan = CompleteReadBatchPlan.progressive;
    var frame = 0;
    Stream<Map<String, dynamic>> frames() async* {
      var offset = 0;
      do {
        final frameSize = plan.sizeAt(offset);
        frame++;
        if (frame == 2 && _batch2 != null) await _batch2.future;
        yield {'type': 'page', 'value': _page(offset, frameSize)};
        offset += frameSize;
      } while (offset < _total);
      yield {
        'type': 'complete',
        'total': _total,
        'readScopeVersion': 'a' * 64,
        'readSnapshotRevision': 'b' * 64,
        'readDataVersion': 'c' * 64,
      };
    }

    return await consume(frames());
  }

  Map<String, dynamic> _page(int offset, int size) => <String, dynamic>{
    'items': <Map<String, dynamic>>[
      for (var i = offset; i < offset + size && i < _total; i++)
        {'goodsId': 'inv-$i', 'name': '库存物料$i', 'qty': 1},
    ],
    'page': offset ~/ size + 1,
    'size': size,
    'total': _total,
    'totalPages': (_total + size - 1) ~/ size,
    'readScopeVersion': 'a' * 64,
    'readSnapshotRevision': 'b' * 64,
    'readDataVersion': 'c' * 64,
  };
}

/// 600 行、按请求页大小精确切片的假仓储；第 2 批（page 2, size 50）挂闸门。
class _GatedStockRepository extends StockQueryRepository {
  _GatedStockRepository() : this._(Completer<void>());
  _GatedStockRepository._(Completer<void> gate)
    : _batch2 = gate,
      super(_GatedApi(gate));

  final Completer<void> _batch2;

  void releaseBatch2() {
    if (!_batch2.isCompleted) _batch2.complete();
  }

  static const total = 600;

  @override
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
    String? owningWarehouse,
    bool owningWarehouseNull = false,
    String? colorId,
    String? series,
    String? unitId,
    String? sort,
    String? order,
    String? attention,
    String? dateFrom,
    String? dateTo,
    bool includeRelated = false,
  }) async {
    if (page == 2 && size == 50) await _batch2.future;
    final start = (page - 1) * size;
    return PagedResult<InstantInventoryRow>(
      items: [
        for (var i = start; i < start + size && i < total; i++)
          InstantInventoryRow(goodsId: 'inv-$i', name: '库存物料$i', qty: 1),
      ],
      page: page,
      size: size,
      total: total,
      totalPages: (total + size - 1) ~/ size,
      readScopeVersion: 'inv-scope-v1',
    );
  }
}
