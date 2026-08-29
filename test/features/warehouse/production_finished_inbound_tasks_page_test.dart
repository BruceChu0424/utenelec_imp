import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_inbound_tasks_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('finished inbound queue remains operable at 375px', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_FinishedInboundApi()),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.stockDocView,
            Perm.stockDocApprove,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: ProductionFinishedInboundTasksPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('产成品待点收'), findsOneWidget);
    expect(find.text('待点收 1 单'), findsOneWidget);
    expect(find.text('短收余量待点收'), findsOneWidget);
    expect(find.text('SJ202608280001'), findsOneWidget);
    expect(find.text('进入逐行点收'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finished inbound queue gives view-only staff no count promise', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_FinishedInboundApi()),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.stockDocView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(home: ProductionFinishedInboundTasksPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('查看待点收详情'), findsOneWidget);
    expect(find.text('进入逐行点收'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _FinishedInboundApi extends ApiClient {
  _FinishedInboundApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/count')) return const {'count': 1};
    return const {
      'items': [
        {
          'documentId': '10000000-0000-0000-0000-000000000001',
          'documentNo': 'CPRK202608280001',
          'documentDate': '2026-08-28',
          'warehouseId': '10000000-0000-0000-0000-000000000002',
          'warehouseName': '半成品仓',
          'planId': '10000000-0000-0000-0000-000000000003',
          'planNo': 'SJ202608280001',
          'reportNos': 'RB202608280001',
          'goodsSummary': 'V5多功能三极插座E极插套(酸洗)',
          'lineCount': 1,
          'pendingQty': 1000,
          'createdAt': '2026-08-28T05:00:00Z',
          'residualTask': true,
        },
      ],
      'page': 1,
      'size': 40,
      'total': 1,
      'totalPages': 1,
    };
  }
}
