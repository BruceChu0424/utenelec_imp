// 仓库任务中心表格置顶回归（2026-09-24 用户口径「表格滑到顶，对齐物料分析页」）：
// 大字号下滑到头后，大类行/小类行/状态行必须已随页滚走，表头钉在表格自身
// 工具条之下——三层结构（大类→小类→分段行）全部进同一个折叠头。
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
    if (path == '/warehouse/sales-outbound') {
      final items = <Map<String, dynamic>>[
        for (var i = 0; i < 60; i++)
          {
            'id': 'so-out-$i',
            'billNo': 'SO-OUT-$i',
            'billDate': '2026-09-01',
            'clientName': '客户$i',
            'warehouseName': '主仓',
            'warehouseWorkStatus': 'PENDING',
          },
      ];
      return {
        'items': items,
        'page': 1,
        'size': 60,
        'total': 60,
        'totalPages': 1,
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
  testWidgets('large font: three header rows scroll away, table pins to top', (
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

    // 大类 → 出库；小类 → 销售出库；状态段 → 待出库（加载表格）。
    await tester.tap(find.text('出库'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('销售出库'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('待出库'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // 滑之前：三层行都在场。
    expect(find.text('入库'), findsOneWidget);
    expect(find.text('委外出库'), findsOneWidget);
    expect(find.text('已出库'), findsOneWidget);

    // 滑到头（外层收完 + 表内滚）。
    for (var i = 0; i < 12; i++) {
      await tester.dragFrom(const Offset(750, 700), const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 200));
    }

    // 表头在场且贴近顶部（1.5 倍字号下只剩 AppBar + 表格自身工具条）。
    final header = tester.getRect(find.text('出货单号'));
    expect(header.top, lessThan(200));
    // 三层行（大类/小类/状态）都已随页滚走。
    expect(find.text('入库'), findsNothing);
    expect(find.text('委外出库'), findsNothing);
    expect(find.text('已出库'), findsNothing);
  });
}
