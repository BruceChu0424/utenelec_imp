import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/config/purchase_doc_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_list_page.dart';
import 'package:uten_imp/features/sales/config/sales_doc_config.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_list_page.dart';
import 'package:uten_imp/features/sales/pages/sales_task_center_page.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_list_page.dart';
import 'package:uten_imp/shared/auth/document_permission_set.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/document_status_counts_provider.dart';
import 'package:uten_imp/shared/providers/draft_counts_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/filter_segment_tap.dart';

class _ListCase {
  const _ListCase({
    required this.name,
    required this.page,
    required this.permissions,
    required this.createKey,
    required this.newPath,
    this.canCreate = true,
    this.historyLabel = '历史记录',
  });

  final String name;
  final Widget Function(String? initialStatus, bool embedded) page;
  final DocumentPermissionSet permissions;
  final String createKey;
  final String newPath;
  final bool canCreate;
  final String historyLabel;
}

final _cases = [
  for (final type in SalesDocType.values)
    _ListCase(
      name: 'sales/${type.pathSegment}',
      page: (status, embedded) => SalesDocListPage(
        docType: type,
        initialStatus: status,
        embedded: embedded,
      ),
      permissions: SalesDocConfig.by(type).permissions,
      createKey: 'sales-list-create',
      newPath: '/sales/${type.pathSegment}/new',
      canCreate: type != SalesDocType.otherShipment,
    ),
  for (final type in PurchaseDocType.values)
    _ListCase(
      name: 'purchase/${type.pathSegment}',
      page: (status, embedded) => PurchaseDocListPage(
        docType: type,
        initialStatus: status,
        embedded: embedded,
      ),
      permissions: PurchaseDocConfig.by(type).permissions,
      createKey: 'purchase-list-create',
      newPath: '/purchase/${type.pathSegment}/new',
      canCreate: PurchaseDocConfig.by(type).allowDirectCreate,
    ),
  for (final type in StockDocType.values)
    _ListCase(
      name: 'stock/${type.code}',
      page: (status, _) =>
          StockDocListPage(docType: type, initialStatus: status),
      permissions: DocumentPermissionCatalog.stockDocument,
      createKey: 'stock-list-create',
      newPath: '/warehouse/${type.code}/new',
      canCreate: type.supportsManualDraft,
      historyLabel: '历史单据',
    ),
];

class _ListApi extends ApiClient {
  _ListApi({this.populated = false}) : super(Dio());
  final bool populated;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/facets') ||
        path.endsWith('/stats') ||
        path == '/documents/status-counts' ||
        path == '/workbench/badges') {
      return const {};
    }
    return {
      'items': [
        if (populated)
          {
            'id': 'draft-1',
            'billNo': 'TEST202610170001',
            'billDate': '2026-10-17',
            'status': 0,
            'writable': true,
            'closed': false,
            'financeApproval': {'status': 'DRAFT'},
          },
      ],
      'page': 1,
      'size': 20,
      'total': populated ? 1 : 0,
      'totalPages': populated ? 1 : 0,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

class _Harness {
  _Harness(this.container, this.permissions);
  final ProviderContainer container;
  final StateProvider<Set<String>> permissions;
  void grant(Set<String> values) =>
      container.read(permissions.notifier).state = values;
}

Future<_Harness> _pump(
  WidgetTester tester,
  _ListCase scenario, {
  String? initialStatus,
  bool embedded = false,
  bool populated = false,
  Set<String>? permissions,
  Widget? pageOverride,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();
  final granted = StateProvider<Set<String>>(
    (ref) => permissions ?? scenario.permissions.actionCodes.toSet(),
  );
  final router = GoRouter(
    initialLocation: '/list',
    routes: [
      GoRoute(
        path: '/list',
        builder: (_, _) {
          final page = pageOverride ?? scenario.page(initialStatus, embedded);
          return embedded ? Scaffold(body: page) : page;
        },
      ),
      GoRoute(
        path: scenario.newPath,
        builder: (_, state) =>
            Scaffold(body: Text('created at ${state.uri.path}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_ListApi(populated: populated)),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWith((ref) => ref.watch(granted)),
        isSuperAdminProvider.overrideWithValue(false),
        draftCountsProvider.overrideWith((ref) => DraftCounts.empty),
        effectiveDocumentStatusCountsProvider.overrideWith(
          (ref, scope) => const AsyncData({}),
        ),
      ],
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
  );
  return _Harness(container, granted);
}

void _expectCreate(WidgetTester tester, _ListCase scenario, {bool? visible}) {
  final finder = find.byKey(Key(scenario.createKey));
  if (!(visible ?? scenario.canCreate)) {
    expect(finder, findsNothing);
    return;
  }
  expect(finder, findsOneWidget);
  expect(
    find.ancestor(of: finder, matching: find.byType(UtenFloatingActionGroup)),
    findsOneWidget,
  );
  final rect = tester.getRect(finder);
  expect(rect.center.dx, greaterThan(720));
  expect(rect.center.dy, greaterThan(650));
  expect(finder.hitTestable(), findsOneWidget);
}

MasterDataTableView<dynamic> _table(WidgetTester tester) => tester.widget(
  find.byWidgetPredicate((widget) => widget is MasterDataTableView<dynamic>),
);

void main() {
  for (final scenario in _cases) {
    testWidgets(
      '${scenario.name}: empty categories keep one authorized floating create action',
      (tester) async {
        final harness = await _pump(tester, scenario);
        _expectCreate(tester, scenario);
        await selectFilterSegment(tester, '草稿');
        await tester.pumpAndSettle();
        _expectCreate(tester, scenario);
        await selectFilterSegment(tester, scenario.historyLabel);
        await tester.pumpAndSettle();
        _expectCreate(tester, scenario);
        harness.grant({scenario.permissions.view});
        await tester.pumpAndSettle();
        _expectCreate(tester, scenario, visible: false);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final name in ['sales/orders', 'purchase/orders', 'stock/TRANSFER']) {
    final scenario = _cases.singleWhere((entry) => entry.name == name);
    testWidgets(
      '$name: selected drafts share create and delete in one floating group',
      (tester) async {
        final harness = await _pump(
          tester,
          scenario,
          initialStatus: 'draft',
          populated: true,
        );
        _expectCreate(tester, scenario);
        final table = _table(tester);
        expect(table.selectable, isTrue);
        expect(table.items, hasLength(1));
        final checkboxes = find
            .descendant(
              of: find.byWidgetPredicate(
                (widget) => widget is MasterDataTableView<dynamic>,
              ),
              matching: find.byType(Checkbox),
            )
            .hitTestable();
        expect(checkboxes, findsWidgets);
        await tester.tap(checkboxes.last);
        await tester.pumpAndSettle();
        final groups = find.ancestor(
          of: find.byKey(Key(scenario.createKey)),
          matching: find.byType(UtenFloatingActionGroup),
        );
        expect(groups, findsOneWidget);
        expect(
          find.descendant(of: groups, matching: find.text('删除所选草稿 (1)')),
          findsOneWidget,
        );
        expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
        harness.grant({
          scenario.permissions.view,
          scenario.permissions.create!,
        });
        await tester.pumpAndSettle();
        _expectCreate(tester, scenario);
        expect(_table(tester).selectable, isFalse);
        expect(find.textContaining('删除所选草稿'), findsNothing);
        harness.grant({scenario.permissions.view});
        await tester.pumpAndSettle();
        _expectCreate(tester, scenario, visible: false);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'embedded purchase keeps create with and without draft-delete permission',
    (tester) async {
      final scenario = _cases.singleWhere(
        (entry) => entry.name == 'purchase/orders',
      );
      final harness = await _pump(
        tester,
        scenario,
        embedded: true,
        permissions: {scenario.permissions.view, scenario.permissions.create!},
      );
      _expectCreate(tester, scenario);
      await selectFilterSegment(tester, '草稿');
      await tester.pumpAndSettle();
      _expectCreate(tester, scenario);
      harness.grant(scenario.permissions.actionCodes.toSet());
      await tester.pumpAndSettle();
      _expectCreate(tester, scenario);
      expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
      await tester.tap(find.byKey(Key(scenario.createKey)));
      await tester.pumpAndSettle();
      expect(find.text('created at ${scenario.newPath}'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'sales task center preserves the embedded create action and real navigation',
    (tester) async {
      final scenario = _cases.singleWhere(
        (entry) => entry.name == 'sales/shipments',
      );
      await _pump(
        tester,
        scenario,
        pageOverride: const SalesTaskCenterPage(initialGroup: 'shipments'),
      );
      _expectCreate(tester, scenario);
      await selectFilterSegment(tester, '草稿');
      await tester.pumpAndSettle();
      _expectCreate(tester, scenario);
      expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
      await tester.tap(find.byKey(Key(scenario.createKey)));
      await tester.pumpAndSettle();
      expect(find.text('created at ${scenario.newPath}'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
