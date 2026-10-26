import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/features/basic_data/pages/master_record_history_page.dart';
import 'package:uten_imp/features/basic_data/pages/master_record_revision_page.dart';
import 'package:uten_imp/features/basic_data/repositories/master_record_history_repository.dart'
    as history;
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'reader-a'),
);

/// 历史门默认近三个月（2026-10-24 口径）下，无其他筛选时的期望查询。
Map<String, dynamic> _defaultDatedQuery() {
  final range = UtenHistoryTimeValue.lastThreeMonths().range!;
  return {
    'size': 50,
    'dateFrom': ChinaDateTime.formatDate(range.start),
    'dateTo': ChinaDateTime.formatDate(range.end),
  };
}

final _grants = StateProvider<Set<String>>(
  (_) => {
    Perm.goodsView,
    Perm.goodsEdit,
    Perm.clientView,
    Perm.materialCategoryView,
  },
);
final _generation = StateProvider<int>((_) => 1);

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async =>
      ref.watch(authenticatedScopeProvider) == null
      ? null
      : SessionSnapshot(generation: ref.watch(_generation));
}

class _OldLayout extends PlatformTableLayoutNotifier {
  _OldLayout() : super('master.record.history');
  @override
  PlatformTableLayout build() {
    super.build();
    return const PlatformTableLayout(
      order: ['recordCode', 'recordedAt', 'action', 'recordLabel', 'actorName'],
      hidden: {'recordLabel'},
      widths: {'recordCode': 145, 'summary': 300},
    );
  }

  @override
  void persist() {}
}

Map<String, dynamic> _revision(
  String id,
  String label, {
  String entity = 'goods',
}) => {
  'id': id,
  'entityType': entity,
  'sourceType': 'RECORD',
  'recordId': 'record-$id',
  'recordCode': 'V$id',
  'recordLabel': label,
  'recordName': label,
  'categoryId': 'cat-original',
  'categoryName': '塑胶件',
  'action': 'EDIT',
  'actorId': 'employee-1',
  'actorName': '张师傅',
  'recordedAt': '2026-10-22T14:00:00Z',
  'summary': '名称由旧值更改为新值',
  'expectedHead': '12',
  'affectedCount': 1,
  'changes': [
    {'label': '名称', 'beforeValue': '旧名称', 'afterValue': '新名称'},
  ],
  'canRestoreBefore': true,
  'canRestoreAfter': true,
};
Map<String, dynamic> _page(
  String label, {
  String id = '8',
  String? cursor,
  String entity = 'goods',
}) => {
  'entries': [_revision(id, label, entity: entity)],
  'nextCursor': cursor,
};

class _Transport {
  final requests =
      <({String method, String path, Map<String, dynamic> query})>[];
  final restores = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> Function(
    Map<String, dynamic> query,
    int request,
  )?
  list;
  Future<Map<String, dynamic>> Function(String id)? detail;
  Future<void> Function()? restore;
  int _reads = 0;
  late final api = () {
    final dio = Dio(BaseOptions(baseUrl: 'https://history.invalid/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          final path = request.path.split('?').first;
          requests.add((
            method: request.method,
            path: request.path,
            query: Map.of(request.queryParameters),
          ));
          Object body;
          if (path == '/master/record-history/categories') {
            body = [
              {
                'id': 'cat-deleted',
                'code': 'CAT-OLD',
                'name': '塑胶类（已删除）',
                'level': 0,
                'goodsCount': 0,
                'children': <Map<String, dynamic>>[],
              },
              {
                'id': 'cat-active',
                'code': 'CAT-NOW',
                'name': '当前分类',
                'level': 0,
                'children': <Map<String, dynamic>>[],
              },
            ];
          } else if (path.endsWith('/restore')) {
            restores.add(Map<String, dynamic>.from(request.data as Map));
            await restore?.call();
            body = <String, Object>{};
          } else if (path == '/master/record-history') {
            final index = _reads++;
            body =
                await (list?.call(Map.of(request.queryParameters), index) ??
                    Future.value(
                      request.queryParameters['cursor'] == null
                          ? _page('第一页货品', cursor: 'opaque-next-token')
                          : _page('第二页货品', id: '7'),
                    ));
          } else if (path.startsWith('/master/record-history/')) {
            final id = request.path.split('/').last;
            body =
                await (detail?.call(id) ?? Future.value(_revision(id, '版本货品')));
          } else {
            body = <String, Object>{};
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              data: body,
              statusCode: 200,
            ),
          );
        },
      ),
    );
    return ApiClient(dio);
  }();
  List<Map<String, dynamic>> get queries => [
    for (final request in requests)
      if (request.path == '/master/record-history') request.query,
  ];
}

Future<({ProviderContainer container, GoRouter router})> _pump(
  WidgetTester tester,
  _Transport transport, {
  String? entity,
  String? record,
  String? category,
  String? initialLocation,
  Set<String>? permissions,
  bool pending = false,
  bool oldLayout = false,
  Size size = const Size(1500, 1000),
  double scale = 1,
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: initialLocation ?? '/basicinfo/history',
    routes: [
      GoRoute(
        path: '/basicinfo/history',
        builder: (_, state) => MasterRecordHistoryPage(
          entityType: state.uri.queryParameters['entityType'] ?? entity,
          recordId: state.uri.queryParameters['recordId'] ?? record,
          categoryId: state.uri.queryParameters['categoryId'] ?? category,
        ),
      ),
      GoRoute(
        path: '/basicinfo/history/:entityType/:id',
        builder: (_, state) => MasterRecordRevisionPage(
          entityType: state.pathParameters['entityType']!,
          id: state.pathParameters['id']!,
          changeSignal: state.extra is ValueNotifier<bool>
              ? state.extra as ValueNotifier<bool>
              : null,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(transport.api),
        history.masterRecordHistoryRepositoryProvider.overrideWithValue(
          history.MasterRecordHistoryRepository(transport.api),
        ),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        currentPermissionsProvider.overrideWith(
          (ref) => permissions ?? ref.watch(_grants),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        apiBaseUrlProvider.overrideWithValue('https://history.invalid/api'),
        sessionSnapshotProvider.overrideWith(_Snapshots.new),
        if (oldLayout)
          platformTableLayoutProvider(
            'master.record.history',
          ).overrideWith(_OldLayout.new),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: dark ? buildDarkTheme() : buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
    ),
  );
  if (pending) {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  } else {
    await tester.pumpAndSettle();
  }
  return (
    container: ProviderScope.containerOf(
      tester.element(find.byType(MasterRecordHistoryPage)),
    ),
    router: router,
  );
}

Finder _button(String label) => find.widgetWithText(UtenButton, label);
Finder get _columnInput => find.byKey(const Key('uten-column-keyword-input'));

Future<void> _openHeader(WidgetTester tester, String key) async {
  final header = find.byKey(ValueKey('master-column-filter-$key'));
  const labelPoint = Alignment(-.7, 0);
  if (header.hitTestable(at: labelPoint).evaluate().isEmpty) {
    // A left-aligned reveal can put a non-frozen filter behind the identity
    // prefix. Reveal its trailing edge and verify the actual label hit target.
    await Scrollable.ensureVisible(tester.element(header.first), alignment: 1);
    await tester.pump();
  }
  final target = header.hitTestable(at: labelPoint).first;
  final rect = tester.getRect(target);
  // Help and resize have independent hit targets; tap the filter label side.
  await tester.tapAt(rect.topLeft + labelPoint.alongSize(rect.size));
  await tester.pump();
}

Future<void> _searchHeader(WidgetTester tester, String key, String text) async {
  await _openHeader(tester, key);
  await tester.enterText(_columnInput, text);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

Future<void> _selectHeader(
  WidgetTester tester,
  String key,
  String label,
) async {
  await _openHeader(tester, key);
  await tester.enterText(_columnInput, label);
  await tester.pump();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _openCategory(WidgetTester tester) async {
  await _openHeader(tester, 'categoryName');
  // The selection operation stays busy until the panel returns. Wait for its
  // actual tree rather than requiring every covered-page ticker to stop.
  for (
    var frame = 0;
    frame < 30 && find.text('塑胶类（已删除）').evaluate().isEmpty;
    frame++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(find.text('塑胶类（已删除）'), findsOneWidget);
}

void main() {
  testWidgets(
    'record and category filters align with the table toolbar and remain clearable',
    (tester) async {
      final wire = _Transport();
      await _pump(
        tester,
        wire,
        entity: 'goods',
        record: 'goods-a',
        category: 'cat-original',
      );
      final record = find.byKey(const Key('master-history-record-filter'));
      final category = find.byKey(const Key('master-history-category-filter'));
      final fullscreen = find.byKey(
        const ValueKey('master-table-fullscreen-toggle'),
      );
      final clear = _button('清除筛选');
      final expected = tester.getRect(fullscreen);
      for (final control in [record, category, clear]) {
        final rect = tester.getRect(control);
        expect(rect.top, closeTo(expected.top, 0.5));
        expect(rect.bottom, closeTo(expected.bottom, 0.5));
      }
      await tester.tap(record);
      await tester.pumpAndSettle();
      expect(wire.queries.last.containsKey('recordId'), isFalse);
      expect(wire.queries.last['categoryId'], 'cat-original');
      await tester.tap(category);
      await tester.pumpAndSettle();
      expect(wire.queries.last.containsKey('categoryId'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  for (final browserBack in [false, true]) {
    testWidgets('单位DELETE表头筛选在恢复后${browserBack ? '浏览器' : 'AppBar'}返回保持', (
      tester,
    ) async {
      final wire = _Transport();
      wire.list = (query, index) => Future.value({
        'entries': [
          {..._revision('8', '箱', entity: 'units'), 'action': 'DELETE'},
        ],
      });
      wire.detail = (id) => Future.value({
        ..._revision(id, '箱', entity: 'units'),
        'action': 'DELETE',
      });
      final app = await _pump(
        tester,
        wire,
        initialLocation: '/basicinfo/history?entityType=units',
        permissions: {Perm.unitView, Perm.unitEdit},
      );
      await _selectHeader(tester, 'action', '删除');
      expect(wire.queries.last['entityType'], 'units');
      expect(wire.queries.last['action'], 'DELETE');
      await tester.tap(find.text('箱').hitTestable().first);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('箱').hitTestable().first);
      await tester.pumpAndSettle();
      await tester.tap(_button('恢复到此次修改前'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(UtenAlertDialog),
          matching: find.widgetWithText(FilledButton, '恢复到此次修改前'),
        ),
      );
      await tester.pumpAndSettle();
      expect(wire.restores, hasLength(1));
      if (browserBack) {
        app.router.pop();
      } else {
        await tester.tap(find.byType(UtenBackButton));
      }
      await tester.pumpAndSettle();
      expect(
        wire.queries.last['entityType'],
        'units',
        reason: 'Returning from a revision must not clear the host query',
      );
      expect(wire.queries.last['action'], 'DELETE');
      final table = tester
          .widget<MasterDataTableView<history.MasterRecordRevision>>(
            find.byKey(const Key('master-record-history-table')),
          );
      expect(table.filters['entityType'], 'units');
      expect(table.filters['action'], 'DELETE');
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('版本恢复返回保留类型分类操作日期关键字并重新读取当前筛选', (tester) async {
    final wire = _Transport();
    wire.list = (query, index) => Future.value({
      'entries': [
        {..._revision('8', '筛选删除资料$index'), 'action': 'DELETE'},
      ],
    });
    wire.detail = (id) =>
        Future.value({..._revision(id, '筛选删除资料'), 'action': 'DELETE'});
    await _pump(
      tester,
      wire,
      initialLocation:
          '/basicinfo/history?entityType=goods&categoryId=cat-original',
    );
    await _selectHeader(tester, 'action', '删除');
    await _searchHeader(tester, 'recordLabel', '名称');
    await _searchHeader(tester, 'actorName', '张师傅');
    await _openHeader(tester, 'recordedAt');
    await tester.pump(const Duration(milliseconds: 350));
    Navigator.of(tester.element(find.byType(UtenDateRangePickerDialog))).pop(
      DateTimeRange(start: DateTime(2026, 10), end: DateTime(2026, 10, 22)),
    );
    await tester.pumpAndSettle();
    final expected = Map<String, dynamic>.of(wire.queries.last);
    expect(expected['categoryId'], 'cat-original');
    expect(expected['dateFrom'], '2026-10-01');
    expect(expected['dateTo'], '2026-10-22');
    final beforeTable = tester
        .widget<MasterDataTableView<history.MasterRecordRevision>>(
          find.byKey(const Key('master-record-history-table')),
        );
    final beforeLabel = beforeTable.items.single.recordLabel;
    await tester.tap(find.text(beforeLabel).hitTestable().first);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text(beforeLabel).hitTestable().first);
    await tester.pumpAndSettle();
    await tester.tap(_button('恢复到此次修改前'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(UtenAlertDialog),
        matching: find.widgetWithText(FilledButton, '恢复到此次修改前'),
      ),
    );
    await tester.pumpAndSettle();
    final readsBeforeReturn = wire.queries.length;
    await tester.tap(find.byType(UtenBackButton));
    await tester.pumpAndSettle();
    expect(wire.queries.length, greaterThan(readsBeforeReturn));
    expect(wire.queries.skip(readsBeforeReturn), everyElement(expected));
    final afterTable = tester
        .widget<MasterDataTableView<history.MasterRecordRevision>>(
          find.byKey(const Key('master-record-history-table')),
        );
    expect(afterTable.items.single.recordLabel, isNot(beforeLabel));
    expect(tester.takeException(), isNull);
  });
  testWidgets('未进入共享表头保存的受控操作筛选返回不被路由本身清空', (tester) async {
    final wire = _Transport();
    wire.list = (query, index) => Future.value(_page('单位历史', entity: 'units'));
    wire.detail = (id) => Future.value(_revision(id, '单位历史', entity: 'units'));
    await _pump(
      tester,
      wire,
      initialLocation: '/basicinfo/history?entityType=units',
      permissions: {Perm.unitView, Perm.unitEdit},
    );
    var table = tester
        .widget<MasterDataTableView<history.MasterRecordRevision>>(
          find.byKey(const Key('master-record-history-table')),
        );
    table.onFilterChanged('action', 'DELETE');
    await tester.pumpAndSettle();
    await tester.tap(find.text('单位历史'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('单位历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(UtenBackButton));
    await tester.pumpAndSettle();
    table = tester.widget<MasterDataTableView<history.MasterRecordRevision>>(
      find.byKey(const Key('master-record-history-table')),
    );
    expect(table.filters['entityType'], 'units');
    expect(table.filters['action'], 'DELETE');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'server filters include scope, action, actor, keyword, dates and confirmed deleted category',
    (tester) async {
      final wire = _Transport();
      await _pump(
        tester,
        wire,
        entity: 'goods',
        record: 'object-1',
        category: 'cat-original',
      );
      expect(wire.queries.last, containsPair('entityType', 'goods'));
      expect(wire.queries.last, containsPair('recordId', 'object-1'));
      expect(wire.queries.last, containsPair('categoryId', 'cat-original'));
      expect(wire.queries.last['size'], 50);
      expect(find.byType(UtenFilterToolbar<String>), findsNothing);
      expect(find.byType(UtenSearchBar), findsNothing);
      await _selectHeader(tester, 'action', '删除');
      await _searchHeader(tester, 'recordLabel', '  名称变更  ');
      await _searchHeader(tester, 'actorName', '  张师傅  ');
      await _openHeader(tester, 'recordedAt');
      await tester.pump(const Duration(milliseconds: 350));
      Navigator.of(tester.element(find.byType(UtenDateRangePickerDialog))).pop(
        DateTimeRange(start: DateTime(2026, 10), end: DateTime(2026, 10, 22)),
      );
      await tester.pumpAndSettle();
      expect(wire.queries.last, containsPair('action', 'DELETE'));
      expect(wire.queries.last, containsPair('keyword', '名称变更'));
      expect(wire.queries.last, containsPair('actorKeyword', '张师傅'));
      expect(wire.queries.last, containsPair('dateFrom', '2026-10-01'));
      expect(wire.queries.last, containsPair('dateTo', '2026-10-22'));
      await _openCategory(tester);
      expect(
        wire.requests
            .lastWhere(
              (request) => request.path == '/master/record-history/categories',
            )
            .query['entityType'],
        'goods',
      );
      await tester.tap(find.text('塑胶类（已删除）'));
      await tester.pump();
      expect(
        wire.queries.last['categoryId'],
        'cat-original',
        reason: 'Picker changes remain local until confirmation',
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(wire.queries.last['categoryId'], 'cat-deleted');
      expect(wire.queries.last.containsKey('recordId'), isFalse);
      await _selectHeader(tester, 'entityType', '客户资料');
      expect(wire.queries.last['entityType'], 'clients');
      expect(wire.queries.last.containsKey('categoryId'), isFalse);
      expect(wire.queries.last.containsKey('recordId'), isFalse);
      await tester.tap(_button('清除筛选'));
      await tester.pumpAndSettle();
      // 清除筛选回到历史门默认的近三个月（2026-10-24 口径）。
      expect(
        wire.queries.lastWhere((query) => !query.containsKey('cursor')),
        _defaultDatedQuery(),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opaque cursors move one page at a time and previous reuses its known cursor',
    (tester) async {
      final wire = _Transport();
      await _pump(tester, wire);
      final initial = wire.queries.length;
      // 初始查询即带历史门默认的近三个月（2026-10-24 口径）。
      expect(wire.queries, [
        _defaultDatedQuery(),
        {..._defaultDatedQuery(), 'cursor': 'opaque-next-token'},
      ]);
      expect(find.text('第一页货品'), findsOneWidget);
      expect(find.text('第 1 页'), findsOneWidget);
      expect(tester.widget<UtenButton>(_button('上一页')).onPressed, isNull);
      await tester.tap(_button('下一页'));
      await tester.pumpAndSettle();
      expect(wire.queries.length, initial);
      expect(wire.queries.last['cursor'], 'opaque-next-token');
      expect(find.text('第一页货品'), findsNothing);
      expect(find.text('第二页货品'), findsOneWidget);
      expect(find.text('第 2 页'), findsOneWidget);
      expect(tester.widget<UtenButton>(_button('下一页')).onPressed, isNull);
      final table = tester
          .widget<MasterDataTableView<history.MasterRecordRevision>>(
            find.byKey(const Key('master-record-history-table')),
          );
      expect(table.showPaginationControls, isFalse);
      expect(table.items, hasLength(1));
      expect(
        table.columns.any((column) => column.key == 'affectedCount'),
        isFalse,
        reason:
            'Summary responses do not establish a real affected-record count',
      );
      expect(
        table.columns.every((column) => !column.sortable),
        isTrue,
        reason:
            'A chronological server cursor cannot offer full-history sorting through only the loaded page',
      );
      await tester.tap(_button('上一页'));
      await tester.pumpAndSettle();
      expect(wire.queries.length, initial);
      expect(wire.queries.first.containsKey('cursor'), isFalse);
      expect(find.text('第一页货品'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a single click selects and a second click opens the real independent revision page',
    (tester) async {
      final wire = _Transport();
      await _pump(tester, wire, entity: 'goods');
      await tester.tap(find.text('第一页货品'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(MasterRecordHistoryPage), findsOneWidget);
      expect(find.byType(MasterRecordRevisionPage), findsNothing);
      expect(
        wire.requests.where(
          (request) => request.path == '/master/record-history/8',
        ),
        isEmpty,
      );
      await tester.tap(find.text('第一页货品'));
      await tester.pumpAndSettle();
      expect(find.byType(MasterRecordRevisionPage), findsOneWidget);
      final detail = tester.widget<MasterRecordRevisionPage>(
        find.byType(MasterRecordRevisionPage),
      );
      expect(detail.entityType, 'goods');
      expect(detail.id, '8');
      expect(wire.requests.last.query['entityType'], 'goods');
      expect(find.textContaining('旧名称'), findsOneWidget);
      expect(find.textContaining('新名称'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'header keyword resets the cursor and never filters only the loaded rows',
    (tester) async {
      final wire = _Transport();
      await _pump(tester, wire);
      await tester.tap(_button('下一页'));
      await tester.pumpAndSettle();
      expect(wire.queries.last['cursor'], 'opaque-next-token');
      await _searchHeader(tester, 'recordLabel', '通过摘要匹配');
      expect(wire.queries.last['keyword'], '通过摘要匹配');
      expect(
        wire.queries.lastWhere((query) => !query.containsKey('cursor'))['keyword'],
        '通过摘要匹配',
      );
      expect(find.text('第 1 页'), findsOneWidget);
      // The server may match an immutable before-value/summary that is absent
      // from visible identity cells. A local current-page search would hide it.
      expect(find.text('第一页货品'), findsOneWidget);
      final beforeCandidateSearch = wire.queries.length;
      await _openHeader(tester, 'entityType');
      await tester.enterText(_columnInput, '客户');
      await tester.pump();
      expect(wire.queries.length, beforeCandidateSearch);
      expect(find.widgetWithText(TextButton, '搜索'), findsNothing);
      await tester.tap(find.text('客户资料').last);
      await tester.pumpAndSettle();
      expect(wire.queries.last['entityType'], 'clients');
      expect(
        wire.queries.lastWhere((query) => !query.containsKey('cursor'))['entityType'],
        'clients',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a superseded header query cannot replace the latest server result',
    (tester) async {
      final delayed = Completer<Map<String, dynamic>>();
      final wire = _Transport()
        ..list = (query, index) => index == 1
            ? delayed.future
            : Future.value(_page(index == 0 ? '初始查询' : '最新查询'));
      await _pump(tester, wire);
      tester
          .widget<MasterDataTableView<history.MasterRecordRevision>>(
            find.byKey(const Key('master-record-history-table')),
          )
          .onFilterChanged('search.recordLabel', '旧搜索');
      await tester.pump();
      await _searchHeader(tester, 'recordLabel', '新搜索');
      expect(wire.queries.last['keyword'], '新搜索');
      delayed.complete(_page('过期搜索结果'));
      await tester.pumpAndSettle();
      expect(find.text('过期搜索结果'), findsNothing);
      expect(find.text('最新查询'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'date picker cancellation is a no-op and identity changes close its old scope',
    (tester) async {
      final wire = _Transport();
      final app = await _pump(tester, wire, entity: 'goods');
      final initial = wire.queries.length;
      await _openHeader(tester, 'recordedAt');
      await tester.pump(const Duration(milliseconds: 350));
      Navigator.of(
        tester.element(find.byType(UtenDateRangePickerDialog)),
      ).pop();
      await tester.pumpAndSettle();
      expect(wire.queries.length, initial);
      await _openHeader(tester, 'recordedAt');
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(UtenDateRangePickerDialog), findsOneWidget);
      app.container.read(_identity.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.byType(UtenDateRangePickerDialog), findsNothing);
      // 取消不重查（上文计数断言）；身份切换也只关弹窗，不多发请求。
      expect(wire.queries.length, initial);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old hidden identity preferences show separate required single-line code and name columns',
    (tester) async {
      await _pump(tester, _Transport(), oldLayout: true);
      final table = tester
          .widget<MasterDataTableView<history.MasterRecordRevision>>(
            find.byKey(const Key('master-record-history-table')),
          );
      expect(table.requiredLeadingColumnKeys, ['recordCode', 'recordLabel']);
      expect(table.columns.take(2).map((column) => column.key), [
        'recordCode',
        'recordLabel',
      ]);
      final fallback = history.MasterRecordRevision.fromJson({
        ..._revision('fallback', '历史名称'),
        'recordName': '',
      });
      expect(table.columns[0].value(fallback), 'Vfallback');
      expect(table.columns[1].value(fallback), '历史名称');
      expect(find.text('V8').hitTestable(), findsOneWidget);
      expect(find.text('第一页货品').hitTestable(), findsOneWidget);
      expect(find.text('编号 / 名称'), findsNothing);
      final code = tester.getRect(find.text('编号').hitTestable());
      final name = tester.getRect(find.text('名称').hitTestable());
      // 默认近三个月挂值后表头显示「修改时间：<起> ~ <止>」，按前缀定位。
      final time = tester.getRect(find.textContaining('修改时间').hitTestable());
      expect(code.left, lessThan(name.left));
      expect(name.left, lessThan(time.left));
      expect(
        tester.getRect(find.text('V8').hitTestable()).top,
        closeTo(tester.getRect(find.text('第一页货品').hitTestable()).top, 1),
      );
      final context = tester.element(
        find.byKey(const Key('master-record-history-table')),
      );
      for (final column in table.columns) {
        final cell = column.cellBuilder!(context, table.items.single) as Text;
        expect(cell.maxLines, 1, reason: column.key);
        expect(cell.softWrap, isFalse, reason: column.key);
        expect(cell.overflow, TextOverflow.ellipsis, reason: column.key);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'code search keeps the full server history query and resets cursors',
    (tester) async {
      final wire = _Transport();
      await _pump(tester, wire);
      await tester.tap(_button('下一页'));
      await tester.pumpAndSettle();
      expect(wire.queries.last['cursor'], 'opaque-next-token');
      await _searchHeader(tester, 'recordCode', ' V8 ');
      expect(wire.queries.last['keyword'], 'V8');
      expect(
        wire.queries.lastWhere((query) => !query.containsKey('cursor'))['keyword'],
        'V8',
      );
      final table = tester
          .widget<MasterDataTableView<history.MasterRecordRevision>>(
            find.byKey(const Key('master-record-history-table')),
          );
      expect(table.filters['search.recordCode'], 'V8');
      expect(table.items, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'identity A-B-A rejects the old list response even after the same identity returns',
    (tester) async {
      final old = Completer<Map<String, dynamic>>();
      final wire = _Transport()
        ..list = (query, index) =>
            index == 0 ? old.future : Future.value(_page('新身份记录'));
      final app = await _pump(tester, wire, pending: true);
      app.container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'reader-b',
      );
      await tester.pump();
      app.container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'reader-a',
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      old.complete(_page('过期身份记录'));
      await tester.pumpAndSettle();
      expect(find.text('过期身份记录'), findsNothing);
      expect(find.text('新身份记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a new permission snapshot rejects a pending old response', (
    tester,
  ) async {
    final old = Completer<Map<String, dynamic>>();
    final wire = _Transport()
      ..list = (query, index) =>
          index == 0 ? old.future : Future.value(_page('新权限记录'));
    final app = await _pump(tester, wire, pending: true);
    app.container.read(_generation.notifier).state = 2;
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    old.complete(_page('过期权限记录'));
    await tester.pumpAndSettle();
    expect(find.text('过期权限记录'), findsNothing);
    expect(find.text('新权限记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'restoring from the independent revision page refreshes the cursor list after browser back',
    (tester) async {
      final wire = _Transport()
        ..list = (query, index) =>
            Future.value(_page(index == 0 ? '恢复前记录' : '恢复后记录'));
      final app = await _pump(tester, wire, entity: 'goods');
      await tester.tap(find.text('恢复前记录'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('恢复前记录'));
      await tester.pumpAndSettle();
      await tester.tap(_button('恢复到此次修改前'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(UtenAlertDialog),
          matching: find.widgetWithText(FilledButton, '恢复到此次修改前'),
        ),
      );
      await tester.pumpAndSettle();
      expect(wire.restores, hasLength(1));
      expect(wire.restores.single, {'expectedHead': '12', 'before': true});
      app.router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(MasterRecordHistoryPage), findsOneWidget);
      expect(find.text('恢复后记录'), findsOneWidget);
      expect(wire.queries.last.containsKey('cursor'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changing history route scope reloads the newly requested record',
    (tester) async {
      final wire = _Transport()
        ..list = (query, index) => Future.value(
          _page(query['recordId'] == 'customer-b' ? '客户新范围' : '货品旧范围'),
        );
      final app = await _pump(tester, wire, entity: 'goods', record: 'goods-a');
      expect(find.text('货品旧范围'), findsOneWidget);
      app.router.go(
        '/basicinfo/history?entityType=clients&recordId=customer-b',
      );
      await tester.pumpAndSettle();
      expect(wire.queries.last['entityType'], 'clients');
      expect(wire.queries.last['recordId'], 'customer-b');
      expect(find.text('货品旧范围'), findsNothing);
      expect(find.text('客户新范围'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending restoration cannot leave through the actual app bar back button',
    (tester) async {
      final gate = Completer<void>();
      final wire = _Transport()..restore = () => gate.future;
      await _pump(tester, wire, entity: 'goods');
      await tester.tap(find.text('第一页货品'));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(find.text('第一页货品'));
      await tester.pumpAndSettle();
      await tester.tap(_button('恢复到此次修改前'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(UtenAlertDialog),
          matching: find.widgetWithText(FilledButton, '恢复到此次修改前'),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(wire.restores, hasLength(1));
      try {
        final back = find.byType(UtenBackButton);
        if (back.evaluate().isNotEmpty) {
          await tester.tap(back, warnIfMissed: false);
        }
        await tester.pump(const Duration(milliseconds: 30));
        expect(find.byType(MasterRecordRevisionPage), findsOneWidget);
      } finally {
        gate.complete();
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an open category tree from the old identity is removed immediately',
    (tester) async {
      final wire = _Transport();
      final app = await _pump(tester, wire, entity: 'goods');
      await _openCategory(tester);
      expect(find.text('塑胶类（已删除）'), findsOneWidget);
      app.container.read(_identity.notifier).state = null;
      await tester.pumpAndSettle();
      expect(find.text('塑胶类（已删除）'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'revoking the selected type clears accepted rows immediately while other view access remains',
    (tester) async {
      final wire = _Transport()
        ..list = (query, index) => Future.value(
          query['entityType'] == 'goods'
              ? _page('旧货品私密记录')
              : _page('客户当前记录', entity: 'clients'),
        );
      final app = await _pump(
        tester,
        wire,
        entity: 'goods',
        record: 'old-goods',
      );
      expect(find.text('旧货品私密记录'), findsOneWidget);
      app.container.read(_grants.notifier).state = {Perm.clientView};
      await tester.pump();
      expect(find.text('旧货品私密记录'), findsNothing);
      await tester.pumpAndSettle();
      expect(wire.queries.last.containsKey('entityType'), isFalse);
      expect(wire.queries.last.containsKey('recordId'), isFalse);
      expect(find.text('客户当前记录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.5, 2.0]) {
    testWidgets(
      '390px dark large text keeps both independent pages usable (scale=$scale)',
      (tester) async {
        final wire = _Transport();
        final app = await _pump(
          tester,
          wire,
          entity: 'goods',
          size: const Size(390, 900),
          scale: scale,
          dark: true,
        );
        expect(
          find.byKey(const Key('master-record-history-table')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        app.router.go('/basicinfo/history/goods/8');
        await tester.pumpAndSettle();
        expect(find.byType(MasterRecordRevisionPage), findsOneWidget);
        expect(find.text('版本货品'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
