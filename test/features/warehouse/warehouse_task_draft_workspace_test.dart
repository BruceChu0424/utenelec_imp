import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_task_center_page.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/drafts/draft_workspace_table.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/task_form_drafts.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_drafts_page.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart'
    show DraftDocKind;
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_badges.dart';
import 'package:uten_imp/shared/warehouse/warehouse_task_scope.dart';

import '../../helpers/badge_summary_fixture.dart';

class _Drafts extends FormDraftsNotifier {
  _Drafts(this.drafts);
  final List<FormDraft> drafts;
  @override
  List<FormDraft> build() => drafts;
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

FormDraft _draft(
  String id, {
  String type = 'TRANSFER',
  String? createdId,
  BadgeModule module = BadgeModule.warehouse,
  String? route,
  String kind = 'stockDocument',
  DateTime? updatedAt,
}) => FormDraft(
  id: id,
  title: '填写中的仓库单据 $id',
  module: module,
  route: route ?? '/warehouse/$type/new',
  permission: Perm.stockDocCreate,
  draftKind: kind,
  updatedAt: updatedAt ?? DateTime(2026, 10, 14),
  data: {'createdDocId': ?createdId},
);

class _Api extends ApiClient {
  _Api({this.formal = const {}}) : super(Dio());
  final Map<String, String> formal;
  final stockQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async =>
      const {};

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/stock/docs') {
      stockQueries.add(Map.of(query ?? {}));
      final type = query?['docType'];
      final id = formal[type];
      return {
        'items': <Map<String, dynamic>>[
          if (id != null)
            {'id': id, 'docType': type, 'billNo': '$type-001', 'status': 0},
        ],
        'page': 1,
        'totalPages': id == null ? 0 : 1,
        'total': id == null ? 0 : 1,
        'size': 200,
      };
    }
    if (path.startsWith('/warehouse/task-center/')) {
      return const {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'totalPages': 0,
        'total': 0,
      };
    }
    return const {};
  }
}

const _mine = MyWarehouseScope(
  role: WarehouseScopeRole.supervisor,
  canSelectAll: true,
  selectable: [WarehouseScopeOption(id: 'chosen', name: '已记忆的成品仓')],
);

void main() {
  Future<ProviderContainer> container(
    WidgetTester tester, {
    List<FormDraft> drafts = const [],
    Map<String, String> formal = const {},
    bool narrowed = false,
    int tasks = 0,
    Set<String> permissions = const {
      Perm.stockDocView,
      Perm.stockDocCreate,
      Perm.warehouseView,
    },
    bool enterTaskCenter = true,
  }) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _Api(formal: formal);
    final scope = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'warehouse-user'),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://warehouse-tests.invalid'),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        myWarehouseScopeProvider.overrideWith((_) async => _mine),
        formDraftsProvider.overrideWith(() => _Drafts(drafts)),
        fixedBadgeSummaryOverride(
          badgeSummaryFixture(
            entries: {
              BadgeEntry.warehouseDrafts: (formal.length, 0),
              BadgeEntry.warehouseOutboundCenter: (tasks, 0),
            },
            facts: {'drafts.stockDocument': formal.length},
          ),
        ),
      ],
    );
    addTearDown(scope.dispose);
    if (narrowed) {
      scope
          .read(warehouseTaskScopePrefProvider.notifier)
          .select(
            const WarehouseTaskScope.warehouse('chosen', name: '已记忆的成品仓'),
          );
    }
    final router = GoRouter(
      initialLocation: RouteName.warehouse,
      routes: [
        GoRoute(
          path: RouteName.warehouse,
          builder: (_, _) => const WarehouseHubPage(),
        ),
        GoRoute(
          path: RouteName.warehouseTasks,
          builder: (_, _) => const WarehouseTaskCenterPage(),
        ),
        GoRoute(
          path: RouteName.formDrafts,
          builder: (_, state) =>
              FormDraftsPage(categoryId: state.pathParameters['categoryId']!),
        ),
        GoRoute(
          path: '/warehouse/:type/new',
          builder: (_, state) =>
              Scaffold(body: Text('继续填写 ${state.pathParameters['type']}')),
        ),
        GoRoute(
          path: '/warehouse/:type/:id',
          builder: (_, state) =>
              Scaffold(body: Text('正式草稿 ${state.pathParameters['id']}')),
        ),
        GoRoute(
          path: RouteName.stockCountSession,
          builder: (_, _) => const Scaffold(body: Text('继续盘点')),
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp.router(
          theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (enterTaskCenter) {
      await tester.tap(find.text('仓库任务中心'));
      await tester.pumpAndSettle();
    }
    return scope;
  }

  testWidgets(
    'one local transfer draft has the same hub and warehouse entry and can resume',
    (tester) async {
      final scope = await container(tester, drafts: [_draft('local-transfer')]);
      expect(scope.read(badgeModuleTodoProvider(BadgeModule.warehouse)), 1);
      expect(
        scope
            .read(warehouseTaskBadgesProvider)
            .entryTodo(BadgeEntry.warehouseDrafts),
        1,
      );
      expect(scope.read(formDraftsPageCountProvider('warehouse')), 1);
      expect(find.text('仓库草稿'), findsOneWidget);
      await tester.tap(find.text('仓库草稿'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<DraftWorkspaceRow>>(
        find.byType(MasterDataTableView<DraftWorkspaceRow>),
      );
      expect(table.items, hasLength(1));
      expect(table.items.single.local?.id, 'local-transfer');
      table.onRowTap!(table.items.single);
      await tester.pumpAndSettle();
      expect(find.text('继续填写 TRANSFER'), findsOneWidget);
      final api = scope.read(apiClientProvider) as _Api;
      expect(api.stockQueries, isNotEmpty);
      expect(
        api.stockQueries.every(
          (query) =>
              query['standaloneDrafts'] == true &&
              query['status'] == 0 &&
              !query.containsKey('scopeWarehouseId'),
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'formal transfer and check keep checkpoints once and exclude other modules and master drafts',
    (tester) async {
      final scope = await container(
        tester,
        formal: const {'TRANSFER': 'transfer-id', 'CHECK': 'check-id'},
        drafts: [
          _draft('checkpoint', createdId: 'transfer-id', kind: 'stockTransfer'),
          _draft('sales-draft', module: BadgeModule.sales),
          _draft('master-draft', route: '/basicinfo/warehouse', kind: ''),
        ],
      );
      expect(scope.read(formDraftsPageCountProvider('warehouse')), 2);
      expect(scope.read(formDraftsPageCountProvider('warehouse-master')), 1);
      expect(
        scope.read(formDraftsPageCountProvider('warehouse')) +
            scope.read(formDraftsPageCountProvider('warehouse-master')),
        scope.read(badgeEntryTodoProvider(BadgeEntry.warehouseDrafts)),
      );
      await tester.tap(find.text('仓库草稿'));
      await tester.pumpAndSettle();
      expect(find.text('显示本人全部可见的仓库草稿，不受任务页的选仓筛选影响。'), findsOneWidget);
      final table = tester.widget<MasterDataTableView<DraftWorkspaceRow>>(
        find.byType(MasterDataTableView<DraftWorkspaceRow>),
      );
      expect(table.items.map((row) => row.id).toSet(), {
        'transfer-id',
        'check-id',
      });
      expect(
        table.items.where((row) => row.local != null).single.local?.id,
        'checkpoint',
      );
      expect(
        table.items.every((row) => row.location.startsWith('/warehouse/')),
        isTrue,
      );
      final check = table.items.singleWhere((row) => row.id == 'check-id');
      table.onRowTap!(check);
      await tester.pumpAndSettle();
      expect(find.text('正式草稿 check-id'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restored scope stays left of drafts and clears through the selector without a filter notice',
    (tester) async {
      final scope = await container(
        tester,
        narrowed: true,
        tasks: 1,
        drafts: [_draft('local-check', type: 'CHECK')],
      );
      expect(
        find.byKey(const Key('warehouse-task-scope-filter-notice')),
        findsNothing,
      );
      expect(find.text('任务筛选：已记忆的成品仓'), findsNothing);
      final selector = find.byKey(const Key('warehouse-scope-selector'));
      expect(selector, findsOneWidget);
      expect(
        tester.getRect(selector).right,
        lessThan(tester.getRect(find.text('资料草稿')).left),
      );
      expect(find.text('已记忆的成品仓'), findsOneWidget);
      expect(scope.read(warehouseTaskScopeProvider).warehouseId, 'chosen');
      expect(
        scope.read(
          warehouseTaskEntryTodoProvider(BadgeEntry.warehouseOutboundCenter),
        ),
        0,
      );
      expect(scope.read(formDraftsPageCountProvider('warehouse')), 1);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('warehouse-picker-all')));
      await tester.tap(find.byKey(const Key('warehouse-picker-confirm')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(scope.read(warehouseTaskScopeProvider).isAll, isTrue);
      expect(
        find.byKey(const Key('warehouse-task-scope-filter-notice')),
        findsNothing,
      );
      expect(
        scope.read(
          warehouseTaskEntryTodoProvider(BadgeEntry.warehouseOutboundCenter),
        ),
        1,
      );
      expect(scope.read(formDraftsPageCountProvider('warehouse')), 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty facts and no local drafts give zero and an empty warehouse workspace',
    (tester) async {
      final scope = await container(tester);
      expect(scope.read(badgeModuleTodoProvider(BadgeModule.warehouse)), 0);
      expect(scope.read(formDraftsPageCountProvider('warehouse')), 0);
      await tester.tap(find.text('仓库草稿'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<DraftWorkspaceRow>>(
        find.byType(MasterDataTableView<DraftWorkspaceRow>),
      );
      expect(table.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final type in ['TRANSFER', 'CHECK']) {
    testWidgets(
      'one $type formal draft and repeated legacy checkpoint stay one warehouse row',
      (tester) async {
        final checkpoint = _draft(
          'legacy-checkpoint',
          type: type,
          createdId: 'same-formal',
          kind: type == 'TRANSFER' ? 'stockTransfer' : 'stockCheck',
        );
        final current = _draft(
          'current-checkpoint',
          type: type,
          createdId: 'same-formal',
          updatedAt: DateTime(2026, 10, 15),
        );
        final scope = await container(
          tester,
          formal: {type: 'same-formal'},
          drafts: [checkpoint, current, current],
        );
        expect(scope.read(formDraftsPageCountProvider('warehouse')), 1);
        expect(
          scope.read(badgeEntryTodoProvider(BadgeEntry.warehouseDrafts)),
          1,
        );
        await tester.tap(find.text('仓库草稿'));
        await tester.pumpAndSettle();
        final table = tester.widget<MasterDataTableView<DraftWorkspaceRow>>(
          find.byType(MasterDataTableView<DraftWorkspaceRow>),
        );
        expect(table.items, hasLength(1));
        expect(table.items.single.id, 'same-formal');
        expect(table.items.single.local?.id, current.id);
        expect(
          table.items.single.recoveryDrafts.map((draft) => draft.id).toSet(),
          {checkpoint.id, current.id},
        );
        expect(table.items.single.deletable, isFalse);
        table.onRowTap!(table.items.single);
        await tester.pumpAndSettle();
        expect(find.text(checkpoint.title), findsOneWidget);
        expect(find.text(current.title), findsOneWidget);
        await tester.tap(find.text(current.title));
        await tester.pumpAndSettle();
        expect(find.text('继续填写 $type'), findsOneWidget);
        expect(scope.read(formDraftsProvider), hasLength(3));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'creator-only can resume warehouse input from hub without gaining formal view',
    (tester) async {
      final scope = await container(
        tester,
        drafts: [_draft('creator-local')],
        permissions: const {Perm.stockDocCreate},
        enterTaskCenter: false,
      );
      expect(find.text('仓库任务中心'), findsNothing);
      expect(find.text('仓库草稿'), findsOneWidget);
      expect(scope.read(formDraftsPageCountProvider('warehouse')), 1);
      await tester.tap(find.text('仓库草稿'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<DraftWorkspaceRow>>(
        find.byType(MasterDataTableView<DraftWorkspaceRow>),
      );
      expect(table.items.single.local?.id, 'creator-local');
      expect((scope.read(apiClientProvider) as _Api).stockQueries, isEmpty);
      table.onRowTap!(table.items.single);
      await tester.pumpAndSettle();
      expect(find.text('继续填写 TRANSFER'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('formal source unavailable preserves both saved checkpoint inputs', () {
    final legacy = _draft('legacy', createdId: 'formal', kind: 'stockTransfer');
    final current = _draft('current', createdId: 'formal');
    final rows = mergeDraftWorkspaceRows([], [legacy, current]);
    expect(rows.map((row) => row.local!.id).toSet(), {'legacy', 'current'});
  });

  testWidgets(
    'legacy WASTE draft counted by the server remains visible and opens its own detail',
    (tester) async {
      final scope = await container(
        tester,
        formal: const {'WASTE': 'legacy-waste'},
        drafts: [
          _draft(
            'legacy-waste-input-a',
            type: 'WASTE',
            createdId: 'legacy-waste',
          ),
          _draft(
            'legacy-waste-input-b',
            type: 'WASTE',
            createdId: 'legacy-waste',
          ),
        ],
      );
      expect(scope.read(formDraftsPageCountProvider('warehouse')), 1);
      expect(scope.read(badgeModuleTodoProvider(BadgeModule.warehouse)), 1);
      await tester.tap(find.text('仓库草稿'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<DraftWorkspaceRow>>(
        find.byType(MasterDataTableView<DraftWorkspaceRow>),
      );
      expect(table.items, hasLength(1));
      final row = table.items.single;
      expect(row.stockType?.code, 'WASTE');
      expect(row.location, '/warehouse/WASTE/legacy-waste');
      expect(row.recoveryDrafts, hasLength(2));
      expect(
        (scope.read(apiClientProvider) as _Api).stockQueries
            .where((query) => query['docType'] == 'WASTE')
            .single['standaloneDrafts'],
        isTrue,
      );
      table.onRowTap!(row);
      await tester.pumpAndSettle();
      expect(find.text('正式草稿 legacy-waste'), findsOneWidget);
      expect(find.text('继续填写'), findsNothing);
      expect(scope.read(formDraftsProvider), hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'a checkpoint for another stock document type never overlays the row',
    () {
      final rows = mergeDraftWorkspaceRows(
        [
          const DraftWorkspaceRow(
            kind: DraftDocKind.stockDocument,
            id: 'formal',
            category: '盘点',
            location: '/warehouse/CHECK/formal',
            stockType: StockDocType.check,
          ),
        ],
        [_draft('transfer-input', createdId: 'formal')],
      );
      expect(rows, hasLength(2));
      expect(rows.singleWhere((row) => row.kind != null).local, isNull);
      expect(
        rows.singleWhere((row) => row.kind == null).local?.id,
        'transfer-input',
      );
    },
  );

  testWidgets(
    'warehouse count-session input has a module-scoped resumable entry',
    (tester) async {
      final scope = await container(
        tester,
        drafts: [
          _draft(
            'count-session',
            route: RouteName.stockCountSession,
            kind: 'stockCount',
          ),
        ],
      );
      expect(scope.read(badgeModuleTodoProvider(BadgeModule.warehouse)), 1);
      expect(scope.read(formDraftsPageCountProvider('warehouse')), 1);
      expect(scope.read(formDraftsPageCountProvider('warehouse-master')), 0);
      await tester.tap(find.text('仓库草稿'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<DraftWorkspaceRow>>(
        find.byType(MasterDataTableView<DraftWorkspaceRow>),
      );
      expect(table.items.single.local?.id, 'count-session');
      table.onRowTap!(table.items.single);
      await tester.pumpAndSettle();
      expect(find.text('继续盘点'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'every registered standalone warehouse editor has exactly one module-scoped draft destination',
    () {
      final destinations = [
        formDraftsPageCategories['warehouse']!.scope,
        formDraftsPageCategories['warehouse-master']!.scope,
      ];
      var checked = 0;
      for (final descriptor in FormDraftCatalog.all.values.where(
        (entry) => entry.module == BadgeModule.warehouse,
      )) {
        final route = descriptor.route.replaceAllMapped(
          RegExp(r':([A-Za-z][A-Za-z0-9]*)'),
          (match) => match.group(1) == 'code' ? 'TRANSFER' : 'identity',
        );
        final spec = descriptor.spec(route: route);
        final draft = FormDraft(
          id: 'catalog-${checked++}',
          title: spec.title,
          module: spec.module,
          route: spec.route,
          permission: spec.permission,
          draftKind: spec.draftKind,
          updatedAt: DateTime(2026, 10, 14),
          data: const {},
        );
        final expected = isTaskFormDraft(draft) ? 0 : 1;
        expect(
          destinations.where((scope) => scope.matches(draft)).length,
          expected,
          reason: '${descriptor.title}: ${draft.route}',
        );
        final other = FormDraft.fromJson({
          ...draft.toJson(),
          'module': BadgeModule.sales.name,
        });
        expect(destinations.any((scope) => scope.matches(other)), isFalse);
      }
      expect(checked, greaterThan(1));
    },
  );

  test('source-bound warehouse snapshots stay on their task recovery path', () {
    final destinations = [
      formDraftsPageCategories['warehouse']!.scope,
      formDraftsPageCategories['warehouse-master']!.scope,
    ];
    for (final spec in [
      FormDraftCatalog.arrival.spec(
        routeParameters: {'expectationIds': 'expected-arrival'},
      ),
      FormDraftCatalog.finishedArrival.spec(
        routeParameters: {'reportIds': 'production-report'},
      ),
      FormDraftCatalog.warehouseDraw.spec(
        routeParameters: {'documentIds': 'production-draw'},
      ),
      FormDraftCatalog.workshopMaterialIssue.spec(
        routeParameters: {'requisitionId': 'material-requisition'},
      ),
      FormDraftCatalog.workshopMaterialBatchIssue.spec(
        routeParameters: {'selections': '{"material-requisition":["line-1"]}'},
      ),
    ]) {
      final draft = FormDraft(
        id: spec.title,
        title: spec.title,
        module: spec.module,
        route: spec.route,
        permission: spec.permission,
        draftKind: spec.draftKind,
        updatedAt: DateTime(2026, 10, 14),
        data: const {},
      );
      expect(isTaskFormDraft(draft), isTrue);
      expect(destinations.any((scope) => scope.matches(draft)), isFalse);
    }
  });
}
