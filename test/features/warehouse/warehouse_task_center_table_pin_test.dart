// 仓库任务中心表格置顶回归（2026-09-24 用户口径「表格滑到顶，对齐物料分析页」）：
// 大字号下方向/来源两行随页滚走，状态在表格首列；不再有第三层状态分类。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_task_center_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/warehouse/task-center/outbound') {
      final items = <Map<String, dynamic>>[
        for (var i = 0; i < 60; i++)
          {
            'id': 'so-out-$i',
            'rowKey': 'SALES:SALES_SHIPMENT:so-out-$i',
            'sourceType': 'SALES',
            'recordType': 'SALES_SHIPMENT',
            'billNo': 'SO-OUT-$i',
            'businessDate': '2026-09-01',
            'partyName': '客户$i',
            'warehouseName': '主仓',
            'status': 'SALES_READY',
            'statusLabel': '销售出库 · 待核对出库',
            'tone': 'accent',
            'action': 'SALES_OUTBOUND',
            'targetId': 'so-out-$i',
            'canHandle': true,
          },
      ];
      return {
        'items': items,
        'page': 1,
        'size': 60,
        'total': 60,
        'totalPages': 1,
        'facets': {'status': [{'value': 'SALES_READY', 'label': '销售出库 · 待核对出库', 'count': 60}],
          'billNo': <Map<String, dynamic>>[]},
      };
    }
    if (path.contains('/items') || path.contains('/summary')) {
      return const {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 20,
        'total': 0,
        'totalPages': 1,
      };
    }
    return const <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

void main() {
  testWidgets('large font: two category rows scroll away, status table pins to top', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1500, 1050);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(_FakeApi()),
            sharedPreferencesProvider.overrideWithValue(preferences),
            fixedBadgeSummaryOverride(badgeSummaryFixture()),
            isSuperAdminProvider.overrideWithValue(true),
            currentPermissionsProvider.overrideWithValue(const <String>{}),
          ],
          child: const WarehouseTaskCenterPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    // 方向 → 出库；来源 → 销售出库，直接读取全状态服务端表格。
    await tester.tap(find.text('出库'));
    await tester.pump(const Duration(milliseconds: 300));
    void expectAlignedCategories() {
      final parent = tester.getRect(
        find.byKey(const Key('warehouse-task-center-groups')),
      );
      final child = tester.getRect(
        find.byKey(const Key('warehouse-task-center-segments-出库任务中心')),
      );
      expect(child.left, parent.left);
    }

    // 选择小类前后都由同一页面容器决定分类左缘。
    expectAlignedCategories();
    await tester.tap(find.text('销售出库'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // 滑之前：只有两层业务分类，状态在表头与每一行。
    expect(find.text('入库'), findsOneWidget);
    expect(find.text('委外出库'), findsOneWidget);
    expect(find.text('已出库'), findsNothing);
    expect(find.text('历史单据'), findsNothing);
    expectAlignedCategories();

    // 滑到头（外层收完 + 表内滚）。
    for (var i = 0; i < 12; i++) {
      await tester.dragFrom(const Offset(750, 700), const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 200));
    }

    // 表头在场且贴近顶部（1.5 倍字号下只剩 AppBar + 表格自身工具条）。
    final header = tester.getRect(find.text('单据 / 任务单号').hitTestable().first);
    expect(header.top, lessThan(200));
    // 两层分类都已随页滚走；状态首列仍在表头。
    expect(find.text('入库'), findsNothing);
    expect(find.text('委外出库'), findsNothing);
    expect(find.text('已出库'), findsNothing);
    expect(find.text('状态').hitTestable(), findsWidgets);
  });
}
