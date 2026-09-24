import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_business_list_pages.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('order stages filter the server aggregate and reset pagination', (
    tester,
  ) async {
    final api = await _mount(tester);

    expect(_primaryLabels(tester), ['草稿', '进行中', '历史记录']);
    expect(find.text('等待财务审核'), findsNothing);
    expect(find.text('财务已退回'), findsNothing);
    expect(find.text('执行中'), findsNothing);
    expect(find.text('红冲'), findsNothing);
    expect(api.queries, isEmpty);

    await _tap(tester, '进行中');
    expect(api.lastQuery, {
      'page': 1,
      'size': 20,
      'financeApproval': 'IN_PROGRESS',
    });

    await _tap(tester, '等待财务审核');
    expect(api.lastQuery, {
      'page': 1,
      'size': 20,
      'status': 0,
      'financeApproval': 'PENDING',
    });
    await _tap(tester, '财务已退回');
    expect(api.lastQuery, {
      'page': 1,
      'size': 20,
      'status': 0,
      'financeApproval': 'REJECTED',
    });
    await _tap(tester, '执行中');
    expect(api.lastQuery, {
      'page': 1,
      'size': 20,
      'status': 1,
      'closed': false,
    });

    _table(tester).onPageChange!(2);
    await tester.pumpAndSettle();
    expect(api.lastQuery['page'], 2);
    await _showHeader(tester);
    await _tap(tester, '清除状态筛选');
    expect(api.lastQuery, {
      'page': 1,
      'size': 20,
      'financeApproval': 'IN_PROGRESS',
    });
    await _showHeader(tester);
    expect(find.text('清除状态筛选'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'order history requires time and retains it when clearing status',
    (tester) async {
      final api = await _mount(tester);
      await _tap(tester, '历史记录');
      expect(find.text('已结案'), findsOneWidget);
      expect(find.text('红冲'), findsOneWidget);
      expect(find.text('执行中'), findsNothing);
      expect(api.queries, isEmpty);

      await _tap(tester, '已结案');
      expect(api.queries, isEmpty);
      final range = DateTimeRange(
        start: DateTime.utc(2026, 8),
        end: DateTime.utc(2026, 8, 31),
      );
      tester
          .widget<UtenHistoryTimeFilter>(find.byType(UtenHistoryTimeFilter))
          .onChanged(UtenHistoryTimeValue.range(range));
      await tester.pumpAndSettle();
      expect(api.lastQuery, {
        'page': 1,
        'size': 20,
        'status': 1,
        'closed': true,
        'dateFrom': '2026-08-01',
        'dateTo': '2026-08-31',
      });

      await _tap(tester, '红冲');
      expect(api.lastQuery, {
        'page': 1,
        'size': 20,
        'status': -1,
        'dateFrom': '2026-08-01',
        'dateTo': '2026-08-31',
      });
      _table(tester).onPageChange!(2);
      await tester.pumpAndSettle();
      await _showHeader(tester);
      await _tap(tester, '清除状态筛选');
      expect(api.lastQuery, {
        'page': 1,
        'size': 20,
        'dateFrom': '2026-08-01',
        'dateTo': '2026-08-31',
      });
      await _showHeader(tester);
      expect(
        tester
            .widget<UtenHistoryTimeFilter>(find.byType(UtenHistoryTimeFilter))
            .value,
        UtenHistoryTimeValue.range(range),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in <String, Widget>{
    'returns': const SubcontractFinishedReturnHistoryPage(),
    'material-returns': const SubcontractMaterialReturnHistoryPage(),
    'wastes': const SubcontractWasteResponsibilityPage(),
  }.entries) {
    testWidgets(
      '${entry.key} keeps completed states under time-gated history',
      (tester) async {
        final api = await _mount(
          tester,
          pathSegment: entry.key,
          page: entry.value,
        );
        expect(_primaryLabels(tester), ['草稿', '历史记录']);
        expect(find.text('进行中'), findsNothing);
        expect(find.text('已审'), findsNothing);
        expect(find.text('红冲'), findsNothing);
        expect(api.queries, isEmpty);

        await _tap(tester, '草稿');
        expect(api.lastQuery, {'page': 1, 'size': 20, 'status': 0});
        final beforeHistory = api.queries.length;
        await _tap(tester, '历史记录');
        expect(find.text('已审'), findsOneWidget);
        expect(find.text('红冲'), findsOneWidget);
        await _tap(tester, '已审');
        expect(api.queries.length, beforeHistory);
        await _tap(tester, '全部');
        expect(api.lastQuery, {'page': 1, 'size': 20, 'status': 1});
        await _tap(tester, '红冲');
        expect(api.lastQuery, {'page': 1, 'size': 20, 'status': -1});
        await _tap(tester, '清除状态筛选');
        expect(api.lastQuery, {'page': 1, 'size': 20});
        expect(
          tester
              .widget<UtenHistoryTimeFilter>(find.byType(UtenHistoryTimeFilter))
              .value
              .all,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('order draft deep link still loads only unsubmitted drafts', (
    tester,
  ) async {
    final api = await _mount(tester, query: '?status=draft');
    expect(api.lastQuery, {
      'page': 1,
      'size': 20,
      'status': 0,
      'financeApproval': 'NONE',
    });
    expect(find.byType(UtenFilterPlaceholder), findsNothing);
    expect(find.text('等待财务审核'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<_RecordingApi> _mount(
  WidgetTester tester, {
  String pathSegment = 'orders',
  Widget? page,
  String query = '',
}) async {
  tester.view.physicalSize = const Size(1500, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _RecordingApi('/subcontract/$pathSegment');
  final router = GoRouter(
    initialLocation: '/subcontract/$pathSegment$query',
    routes: [
      GoRoute(
        path: '/subcontract/$pathSegment',
        builder: (_, state) =>
            page ??
            SubcontractOrderWorkspacePage(
              initialStatus: state.uri.queryParameters['status'],
            ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(const {}),
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Iterable<String> _primaryLabels(WidgetTester tester) => tester
    .widgetList<UtenFilterToolbar<dynamic>>(
      find.byWidgetPredicate((widget) => widget is UtenFilterToolbar),
    )
    .first
    .segments
    .map((segment) => segment.label);

MasterDataTableView<SubcontractDocListItem> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<SubcontractDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<SubcontractDocListItem>,
      ),
    );

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _showHeader(WidgetTester tester) async {
  // 翻页会把表体回顶并收起联动页头，重新展开后再操作分类。
  tester
      .state<NestedScrollViewState>(find.byType(NestedScrollView))
      .outerController
      .jumpTo(0);
  await tester.pumpAndSettle();
}

class _RecordingApi extends ApiClient {
  _RecordingApi(this.listPath) : super(Dio());

  final String listPath;
  final queries = <Map<String, dynamic>>[];
  Map<String, dynamic> get lastQuery => queries.last;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != listPath) return {};
    queries.add(Map<String, dynamic>.from(query ?? {}));
    return {
      'items': const <Map<String, dynamic>>[],
      'page': query?['page'] ?? 1,
      'size': 20,
      'total': 40,
      'totalPages': 2,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}
