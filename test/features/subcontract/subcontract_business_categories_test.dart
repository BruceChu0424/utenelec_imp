import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_business_list_pages.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
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
      // 2026-10-04 起历史门默认「全部」：选中历史记录即发一次全量查询（无状态）。
      expect(api.queries, [
        {'page': 1, 'size': 20},
      ]);

      await _tap(tester, '已结案');
      // 2026-10-04 起历史段默认「全部时间段」：进入即全量加载（不带日期）。
      expect(api.lastQuery, {
        'page': 1,
        'size': 20,
        'status': 1,
        'closed': true,
      });
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
        await _tap(tester, '历史记录');
        expect(find.text('已审'), findsOneWidget);
        expect(find.text('红冲'), findsOneWidget);
        // 2026-10-04 起历史门默认「全部」：选中历史记录即全量加载（不带状态）。
        expect(api.lastQuery, {'page': 1, 'size': 20});
        await _tap(tester, '已审');
        expect(api.lastQuery, {'page': 1, 'size': 20, 'status': 1});
        // 时间胶囊「全部」默认已选中：再点不重复发请求。
        await _tap(tester, '全部');
        expect(api.lastQuery, {'page': 1, 'size': 20, 'status': 1});
        await _tap(tester, '红冲');
        expect(api.lastQuery, {'page': 1, 'size': 20, 'status': -1});
        await _tap(tester, '清除状态筛选');
        expect(api.lastQuery, {'page': 1, 'size': 20});
        await _showHeader(tester);
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
    final api = await _mount(
      tester,
      query: '?status=draft',
      permissions: const {
        Perm.subcontractOrderView,
        Perm.subcontractOrderCreate,
      },
    );
    expect(api.lastQuery, {
      'page': 1,
      'size': 20,
      'status': 0,
      'financeApproval': 'NONE',
    });
    expect(find.byType(UtenFilterPlaceholder), findsNothing);
    expect(find.text('等待财务审核'), findsNothing);
    expect(find.text('创建新委外单'), findsNothing);
    await _tap(tester, '进行中');
    expect(find.text('创建新委外单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<_RecordingApi> _mount(
  WidgetTester tester, {
  String pathSegment = 'orders',
  Widget? page,
  String query = '',
  Set<String> permissions = const {},
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
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
        ),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        currentPermissionsProvider.overrideWithValue(permissions),
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
  await _showHeader(tester);
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _showHeader(WidgetTester tester) async {
  // 分类筛选和翻页都会把表体回顶并收起联动页头，先展开再操作分类。
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
