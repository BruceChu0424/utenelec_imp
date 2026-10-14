import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/visitor/providers/visitor_session_provider.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_edit_page.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/shared/auth/document_permission_set.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/warehouse_selection.dart';

import '../../helpers/document_scope_fixture.dart';
import 'arrival_weight_test_support.dart';

const _allActions = {
  Perm.stockDocView,
  Perm.stockDocCreate,
  Perm.stockDocEdit,
  Perm.stockDocDelete,
  Perm.stockDocApprove,
  Perm.stockDocReverse,
  Perm.stockDocIssue,
  Perm.stockDocReverseIssue,
};

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _VisitorSession extends VisitorSessionNotifier {
  @override
  VisitorSessionState build() => const VisitorSessionState();
}

class _Names extends MasterNameService {
  _Names() : super(ApiClient(Dio()));
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> ensureWarehousesLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '旧料';
  @override
  GoodsDictEntry? goodsInfo(String? id) =>
      const GoodsDictEntry(name: '旧料', code: 'OLD-01', unitId: 'pcs');
  @override
  String unit(String? id) => '个';
  @override
  String warehouse(String? id) => id == 'reject' ? '不良品仓' : '五金仓';
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'normal', name: '五金仓', selectableForNew: true),
    WarehouseDictEntry(id: 'reject', name: '不良品仓', selectableForNew: true),
  ];
}

class _Api extends ApiClient {
  _Api(this.document) : super(Dio());
  final Map<String, dynamic> document;
  final reads = <String>[];
  final writes = <String>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    return document;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add('POST $path');
    return document;
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writes.add('PUT $path');
    return document;
  }

  @override
  Future<void> delete(String path, {Map<String, dynamic>? query}) async {
    writes.add('DELETE $path');
  }
}

Map<String, dynamic> _waste({int status = 0, bool canDelete = true}) => {
  'id': 'legacy-waste',
  'docType': 'WASTE',
  'billNo': 'OLD-WASTE-001',
  'billDate': '2026-01-01',
  'status': status,
  'makerId': 'maker',
  'warehouseId': 'normal',
  'totalLocal': 123.45,
  'canEdit': true,
  'canDelete': canDelete,
  'productionLinked': false,
  'items': [
    {
      'id': 'waste-line',
      'goodsId': 'old-goods',
      'unitId': 'pcs',
      'warehouseId': 'reject',
      'qty': 2.1256,
      'qtyExact': '2.1256',
      'price': 58.0777,
      'amountLocal': 123.45,
    },
  ],
};

Finder _action(String text) => find.widgetWithText(UtenButton, text);

void _expectReadOnly() {
  for (final text in ['编辑', '审核', '反审', '红冲', '出库', '取消出库', '保存']) {
    expect(_action(text), findsNothing, reason: '旧损耗单不可$text');
  }
  expect(
    find.byWidgetPredicate((widget) => widget is UtenEditableGrid),
    findsNothing,
  );
}

Future<_Api> _pump(
  WidgetTester tester, {
  StockDocType type = StockDocType.waste,
  int status = 0,
  bool edit = false,
  bool fresh = false,
  bool routed = false,
  bool canDelete = true,
  bool writableOwner = true,
  Set<String> permissions = _allActions,
}) async {
  tester.view.physicalSize = const Size(1600, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final api = _Api(_waste(status: status, canDelete: canDelete));
  Widget page() => edit
      ? StockDocEditPage(docType: type, id: fresh ? null : 'legacy-waste')
      : StockDocDetailPage(docType: type, id: 'legacy-waste');
  final router = routed
      ? GoRouter(
          initialLocation: '/test',
          routes: [
            GoRoute(path: '/test', builder: (_, _) => page()),
            GoRoute(
              path: '/warehouse/WASTE',
              builder: (_, _) => const Scaffold(body: Text('旧单据列表')),
            ),
            GoRoute(
              path: '/warehouse/WASTE/:id',
              builder: (_, state) => StockDocDetailPage(
                docType: StockDocType.waste,
                id: state.pathParameters['id']!,
              ),
            ),
          ],
        )
      : null;
  if (router != null) addTearDown(router.dispose);
  Widget notifications(BuildContext context, Widget? child) => Stack(
    children: [
      child!,
      const Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: AppNotificationHost(useSafeArea: false),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://legacy-tests.invalid'),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        masterNameServiceProvider.overrideWithValue(_Names()),
        stockDocRepositoryProvider.overrideWith(
          (ref, type) => StockDocRepository(api, type),
        ),
        documentScopeOverride(writeAll: writableOwner),
        ...warehouseWeightTestOverrides(api),
      ],
      child: router == null
          ? MaterialApp(builder: notifications, home: page())
          : MaterialApp.router(routerConfig: router, builder: notifications),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return api;
}

void main() {
  test(
    'legacy type appends without changing eight live document identities',
    () {
      const live = [
        ('TRANSFER', 'transfer', true, WarehouseUse.transfer),
        ('OTHER_IN', 'otherIn', true, WarehouseUse.goodIn),
        ('OTHER_OUT', 'otherOut', true, WarehouseUse.disposalOut),
        ('DRAW', 'draw', true, WarehouseUse.goodOut),
        ('WDRAW', 'wdraw', false, WarehouseUse.goodIn),
        ('FINISHED_IN', 'finishedIn', true, WarehouseUse.goodIn),
        ('FINISHED_OUT', 'finishedOut', true, WarehouseUse.goodOut),
        ('CHECK', 'check', true, WarehouseUse.count),
      ];
      for (var index = 0; index < live.length; index++) {
        final type = StockDocType.values[index];
        expect((
          type.code,
          type.name,
          type.supportsManualDraft,
          type.warehouseUse,
        ), live[index]);
        expect(type.isLegacyReadOnly, isFalse);
        expect(type.refreshKey, 'stock:${live[index].$2}');
      }
      expect(StockDocType.values.last, StockDocType.waste);
      expect(StockDocType.byCode('WASTE'), StockDocType.waste);
      expect(StockDocType.waste.isLegacyReadOnly, isTrue);
      expect(StockDocType.waste.supportsManualDraft, isFalse);
      expect(StockDocType.waste.warehouseUse, WarehouseUse.disposalOut);
      expect(StockDocType.tryByCode('UNKNOWN'), isNull);
    },
  );

  test('legacy route authority permits viewing and draft delete only', () {
    final policy = DocumentPermissionCatalog.stockBySegment['WASTE']!;
    expect(policy.actionCodes, [Perm.stockDocView, Perm.stockDocDelete]);
    for (final action in DocumentPermissionAction.values) {
      expect(
        policy.allows(_allActions, action),
        action == DocumentPermissionAction.view ||
            action == DocumentPermissionAction.delete,
      );
    }
    expect(
      locationAllowedFor(_allActions, false, '/warehouse/WASTE/legacy-waste'),
      isTrue,
    );
    expect(
      locationAllowedFor(_allActions, false, '/warehouse/WASTE/new'),
      isFalse,
    );
    expect(
      locationAllowedFor(
        _allActions,
        false,
        '/warehouse/WASTE/legacy-waste/edit',
      ),
      isFalse,
    );
  });

  testWidgets(
    'registered routes reject legacy forms and preserve live manual routes',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(_Session.new),
          visitorSessionProvider.overrideWith(_VisitorSession.new),
        ],
      );
      addTearDown(container.dispose);
      final router = container.read(appRouterProvider);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      for (final type in StockDocType.values) {
        for (final edit in [false, true]) {
          final path = edit
              ? '/warehouse/${type.code}/legacy-waste/edit'
              : '/warehouse/${type.code}/new';
          final matches = router.configuration.findMatch(Uri.parse(path));
          expect(matches.isError, isFalse);
          final match = matches.last;
          final route = match.route;
          final target = await route.redirect!(
            context,
            match.buildState(router.configuration, matches),
          );
          expect(
            target,
            type.supportsManualDraft
                ? null
                : edit
                ? '/warehouse/${type.code}/legacy-waste'
                : '/warehouse/${type.code}',
          );
        }
      }
    },
  );

  testWidgets(
    'legacy draft opens real viewer, preserves line data and has no write workflow',
    (tester) async {
      final api = await _pump(tester);
      expect(find.text('旧损耗单详情'), findsOneWidget);
      final table = tester.widget<MasterDataTableView<StockDocItem>>(
        find.byType(MasterDataTableView<StockDocItem>),
      );
      expect(table.columns.any((column) => column.key == 'warehouse'), isTrue);
      expect(table.items.single.qtyText, '2.1256');
      expect(table.items.single.amountLocal, 123.45);
      expect(table.items.single.warehouseId, 'reject');
      _expectReadOnly();
      expect(_action('删除'), findsOneWidget);
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'approved legacy remains read only with approve/reverse/issue permissions',
    (tester) async {
      final api = await _pump(tester, status: 1);
      _expectReadOnly();
      expect(_action('删除'), findsNothing);
      expect(api.writes, isEmpty);
    },
  );

  testWidgets('legacy deletion still requires delete permission', (
    tester,
  ) async {
    await _pump(tester, permissions: {Perm.stockDocView, Perm.stockDocApprove});
    _expectReadOnly();
    expect(_action('删除'), findsNothing);
  });

  testWidgets(
    'legacy deletion retains owner scope and server canDelete checks',
    (tester) async {
      await _pump(tester, writableOwner: false);
      expect(_action('删除'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, canDelete: false);
      expect(_action('删除'), findsNothing);
    },
  );

  testWidgets(
    'authorized legacy draft deletion requires confirmation and only deletes that draft',
    (tester) async {
      final api = await _pump(tester, routed: true);
      await tester.tap(_action('删除'));
      await tester.pumpAndSettle();
      expect(find.text('确定删除该草稿单据吗？'), findsOneWidget);
      expect(api.writes, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(api.writes, ['DELETE /stock/docs/legacy-waste']);
      expect(find.text('旧单据列表'), findsOneWidget);
    },
  );

  testWidgets('direct legacy new/editor widgets never build a write form', (
    tester,
  ) async {
    final fresh = await _pump(tester, edit: true, fresh: true);
    expect(find.text('旧损耗单仅可查看，不能新建或编辑。'), findsOneWidget);
    _expectReadOnly();
    expect(fresh.reads, isEmpty);
    expect(fresh.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
    final existing = await _pump(tester, edit: true);
    expect(find.text('旧损耗单详情'), findsOneWidget);
    _expectReadOnly();
    expect(existing.writes, isEmpty);
  });

  testWidgets(
    'actual WASTE under a live detail alias is read only without a router',
    (tester) async {
      final api = await _pump(tester, type: StockDocType.draw);
      expect(find.text('旧损耗单详情'), findsOneWidget);
      _expectReadOnly();
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'actual WASTE under a live editor alias stays fenced without navigation',
    (tester) async {
      final api = await _pump(tester, type: StockDocType.check, edit: true);
      expect(find.text('旧损耗单详情'), findsOneWidget);
      _expectReadOnly();
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'actual WASTE editor alias navigates to its canonical read only detail',
    (tester) async {
      final api = await _pump(
        tester,
        type: StockDocType.check,
        edit: true,
        routed: true,
      );
      expect(find.text('旧损耗单详情'), findsOneWidget);
      _expectReadOnly();
      expect(api.writes, isEmpty);
    },
  );
}
