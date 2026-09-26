// 销售任务中心表格置顶回归（2026-09-24 用户口径「表格要能置顶到头，
// 参考物料分析页」）：大字号下滑到头后，页面头（单据计数 + 动作按钮）必须
// 已随页滚走，表头钉在剩余固定家具（大类行 + 表格工具条）之下。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/pages/sales_task_center_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

class _FakeApi extends ApiClient {
  _FakeApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/sales/')) {
      final items = <Map<String, dynamic>>[
        for (var i = 0; i < 60; i++)
          {
            'id': 'so-$i',
            'billNo': 'SO-2026-00$i',
            'billDate': '2026-09-01',
            'clientName': '客户$i',
            'status': 1,
            'currencyName': 'CNY',
            'warehouseName': '主仓',
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
    return const <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

void main() {
  testWidgets('large font: page header scrolls away, table pins to top', (
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
            salesMasterNameServiceProvider.overrideWithValue(
              SalesMasterNameService(_FakeApi()),
            ),
            currentPermissionsProvider.overrideWithValue(const <String>{
              Perm.salesShipmentView,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const SalesTaskCenterPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('出货单'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('已审'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // 滑之前：页面头（计数行）与小类行都在场。
    expect(find.textContaining('出货 (60)'), findsOneWidget);
    expect(find.text('历史记录'), findsOneWidget);

    // 滑到头（外层收完 + 表内滚）。
    for (var i = 0; i < 10; i++) {
      await tester.dragFrom(const Offset(750, 700), const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 200));
    }

    // 表头在场且贴近顶部（1.5 倍字号下只剩 AppBar + 表格自身工具条）。
    final header = tester.getRect(find.text('单据号'));
    expect(header.top, lessThan(160));
    // 页面头（计数行）已随页滚走，不再占据表头上方。
    expect(find.textContaining('出货 (60)'), findsNothing);
    // 小类行同样收走。
    expect(find.text('历史记录'), findsNothing);
    // 2026-09-24 第三批：宿主大类行也进折叠头——滑到头后一并收走。
    expect(find.text('订货进度'), findsNothing);
  });
}
