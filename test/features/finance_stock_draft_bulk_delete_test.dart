import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_list_page.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_stock_doc_segment.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../helpers/badge_summary_fixture.dart';
import '../support/filter_segment_tap.dart';

void main() {
  Future<GoRouter> pumpList(
    WidgetTester tester,
    _DraftApi api,
    Widget page, {
    required Set<String> permissions,
    List<RouteBase> extraRoutes = const [],
    bool connectResume = false,
  }) async {
    tester.view.physicalSize = const Size(1500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final router = GoRouter(
      initialLocation: '/list?status=draft',
      routes: [
        GoRoute(path: '/list', builder: (_, _) => page),
        ...extraRoutes,
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue(permissions),
          isSuperAdminProvider.overrideWithValue(false),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'test-user'),
          ),
          documentScopeCapabilityProvider.overrideWith(
            (ref, scope) async => DocumentScopeCapability(
              scope: scope.apiValue,
              writeAll: false,
              writableOwnerIds: const {'owner'},
            ),
          ),
          fixedBadgeSummaryOverride(),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (connectResume) {
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
        listen: false,
      );
      final notifier = container.read(pageResumeProvider.notifier);
      addTearDown(attachPageResume(router, notifier));
      bumpPageResumeState(notifier, '/list');
      await tester.pumpAndSettle();
    }
    return router;
  }

  MasterDataTableView<T> table<T>(WidgetTester tester) => tester.widget(
    find.byWidgetPredicate((widget) => widget is MasterDataTableView<T>),
  );

  Future<void> deleteSelection(
    WidgetTester tester,
    int count, {
    bool confirm = true,
  }) async {
    await tester.tap(find.text('删除所选草稿 ($count)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(confirm ? '确认删除' : '取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final type in FinanceDocType.values) {
    testWidgets('${type.name} 草稿多选删除逐条复核并刷新，不预载全页详情', (tester) async {
      final config = FinanceDocConfig.by(type);
      final api = _DraftApi('/finance/${type.pathSegment}', {
        'a': _row('a'),
        'b': _row('b'),
        'legacy': _row('legacy', legacy: true),
      });
      await pumpList(
        tester,
        api,
        FinanceDocListPage(docType: type, initialStatus: 'draft'),
        permissions: {config.listPerm, config.deletePerm!},
      );
      var grid = table<FinanceDocListItem>(tester);
      expect(grid.selectable, isTrue);
      expect(grid.idOf!(grid.items.last), isNull);
      expect(grid.rowKeyOf!(grid.items.last), 'legacy');
      expect(api.detailReads, isEmpty);
      grid.onSelectedIdsChanged!({'a', 'b'});
      await tester.pumpAndSettle();
      await deleteSelection(tester, 2);
      expect(api.events, ['GET a', 'DELETE a', 'GET b', 'DELETE b']);
      grid = table<FinanceDocListItem>(tester);
      expect(grid.selectedIds, isEmpty);
      expect(grid.items.map((item) => item.id), ['legacy']);
      expect(api.listReads, greaterThanOrEqualTo(2));
    });
  }

  testWidgets('财务草稿删除拒绝跨负责人、最新历史标识及已审核状态', (tester) async {
    final api = _DraftApi(
      '/finance/receipts',
      {
        'own': _row('own'),
        'foreign': _row('foreign', maker: 'other-owner'),
        'becameLegacy': _row('becameLegacy'),
        'approved': _row('approved'),
      },
      detailChanges: {
        'becameLegacy': {'legacyId': 123},
        'approved': {'status': 1},
      },
    );
    await pumpList(
      tester,
      api,
      const FinanceDocListPage(
        docType: FinanceDocType.receipt,
        initialStatus: 'draft',
      ),
      permissions: {Perm.financeReceiptView, Perm.financeReceiptDelete},
    );
    table<FinanceDocListItem>(tester).onSelectedIdsChanged!({
      'own',
      'foreign',
      'becameLegacy',
      'approved',
    });
    await tester.pumpAndSettle();
    await deleteSelection(tester, 4);
    expect(api.deleted, ['own']);
    expect(table<FinanceDocListItem>(tester).selectedIds, {
      'foreign',
      'becameLegacy',
      'approved',
    });
  });

  testWidgets('仓库草稿删除保留生产自动单、永久调整和跨负责人单据', (tester) async {
    final api = _DraftApi(
      '/stock/docs',
      {
        'manual': _row('manual'),
        'production': _row('production'),
        'adjustment': _row('adjustment'),
        'foreign': _row('foreign', maker: 'other-owner'),
      },
      detailChanges: {
        'production': {
          'productionLinked': true,
          'canDelete': false,
          'restrictionReason': '生产链自动单不可删除',
        },
        'adjustment': {'canDelete': false, 'restrictionReason': '永久调整记录不可删除'},
      },
    );
    await pumpList(
      tester,
      api,
      const StockDocListPage(
        docType: StockDocType.finishedIn,
        initialStatus: 'draft',
      ),
      permissions: {Perm.stockDocView, Perm.stockDocDelete},
    );
    expect(api.detailReads, isEmpty);
    final grid = table<StockDocListItem>(tester);
    expect(grid.selectable, isTrue);
    expect(grid.rowKeyOf!(grid.items.first), 'manual');
    grid.onSelectedIdsChanged!({
      'manual',
      'production',
      'adjustment',
      'foreign',
    });
    await tester.pumpAndSettle();
    await deleteSelection(tester, 4);
    expect(api.deleted, ['manual']);
    expect(table<StockDocListItem>(tester).selectedIds, {
      'production',
      'adjustment',
      'foreign',
    });
  });

  testWidgets('仓库拒绝非草稿最新状态并在明确失败后继续可删记录', (tester) async {
    final api = _DraftApi(
      '/stock/docs',
      {'changed': _row('changed'), 'manual': _row('manual')},
      detailChanges: {
        'changed': {'status': 1},
      },
    );
    await pumpList(
      tester,
      api,
      const StockDocListPage(
        docType: StockDocType.transfer,
        initialStatus: 'draft',
      ),
      permissions: {Perm.stockDocView, Perm.stockDocDelete},
    );
    table<StockDocListItem>(tester).onSelectedIdsChanged!({
      'changed',
      'manual',
    });
    await tester.pumpAndSettle();
    await deleteSelection(tester, 2);
    expect(api.events, ['GET changed', 'GET manual', 'DELETE manual']);
    expect(table<StockDocListItem>(tester).selectedIds, {'changed'});
  });

  testWidgets('仓库删除结果不确定时停止后续条目，刷新后保留未处理选择', (tester) async {
    final api = _DraftApi('/stock/docs', {
      'a': _row('a'),
      'b': _row('b'),
    }, deleteFailure: NetworkTimeoutException());
    await pumpList(
      tester,
      api,
      const StockDocListPage(
        docType: StockDocType.check,
        initialStatus: 'draft',
      ),
      permissions: {Perm.stockDocView, Perm.stockDocDelete},
    );
    table<StockDocListItem>(tester).onSelectedIdsChanged!({'a', 'b'});
    await tester.pumpAndSettle();
    await deleteSelection(tester, 2);
    expect(api.events, ['GET a', 'DELETE a']);
    expect(api.listReads, greaterThanOrEqualTo(2));
    expect(table<StockDocListItem>(tester).selectedIds, {'a', 'b'});
  });

  testWidgets('财务没有删除权限时草稿不启用勾选', (tester) async {
    final api = _DraftApi('/finance/receipts', {'a': _row('a')});
    await pumpList(
      tester,
      api,
      const FinanceDocListPage(
        docType: FinanceDocType.receipt,
        initialStatus: 'draft',
      ),
      permissions: {Perm.financeReceiptView},
    );
    expect(table<FinanceDocListItem>(tester).selectable, isFalse);
    expect(find.text('删除所选草稿 (0)'), findsNothing);
  });

  testWidgets('仓库没有删除权限时草稿不启用勾选', (tester) async {
    final api = _DraftApi('/stock/docs', {'a': _row('a')});
    await pumpList(
      tester,
      api,
      const StockDocListPage(
        docType: StockDocType.otherIn,
        initialStatus: 'draft',
      ),
      permissions: {Perm.stockDocView},
    );
    expect(table<StockDocListItem>(tester).selectable, isFalse);
    expect(find.text('删除所选草稿 (0)'), findsNothing);
  });

  testWidgets('财务筛选清除选择，已审段禁用多选，取消删除不读取详情', (tester) async {
    final api = _DraftApi('/finance/receipts', {'a': _row('a')});
    await pumpList(
      tester,
      api,
      const FinanceDocListPage(
        docType: FinanceDocType.receipt,
        initialStatus: 'draft',
      ),
      permissions: {Perm.financeReceiptView, Perm.financeReceiptDelete},
    );
    table<FinanceDocListItem>(tester).onSelectedIdsChanged!({'a'});
    await tester.pumpAndSettle();
    await deleteSelection(tester, 1, confirm: false);
    expect(api.events, isEmpty);
    table<FinanceDocListItem>(tester).onFilterChanged('accountId', 'account');
    await tester.pumpAndSettle();
    expect(table<FinanceDocListItem>(tester).selectedIds, isEmpty);
    table<FinanceDocListItem>(tester).onFilterChanged('status', '1');
    await tester.pumpAndSettle();
    expect(table<FinanceDocListItem>(tester).selectable, isFalse);
    expect(find.text('删除所选草稿 (0)'), findsNothing);
  });

  testWidgets('仓库表头过滤清除选择', (tester) async {
    final api = _DraftApi('/stock/docs', {'a': _row('a')});
    await pumpList(
      tester,
      api,
      const StockDocListPage(
        docType: StockDocType.otherOut,
        initialStatus: 'draft',
      ),
      permissions: {Perm.stockDocView, Perm.stockDocDelete},
    );
    table<StockDocListItem>(tester).onSelectedIdsChanged!({'a'});
    await tester.pumpAndSettle();
    table<StockDocListItem>(tester).onFilterChanged('warehouse', 'warehouse');
    await tester.pumpAndSettle();
    expect(table<StockDocListItem>(tester).selectedIds, isEmpty);
    expect(api.events, isEmpty);
  });

  testWidgets('仓库内嵌草稿共用删除预检，拒绝生产关联单并保留失败选择', (tester) async {
    final api = _DraftApi(
      '/stock/docs',
      {'manual': _row('manual'), 'production': _row('production')},
      detailChanges: {
        'production': {'productionLinked': true, 'canDelete': false},
      },
    );
    await pumpList(
      tester,
      api,
      const Scaffold(
        body: WarehouseStockDocSegment(docType: StockDocType.finishedIn),
      ),
      permissions: {Perm.stockDocView, Perm.stockDocDelete},
    );
    await selectFilterSegment(tester, '草稿');
    await tester.pumpAndSettle();
    final grid = table<StockDocListItem>(tester);
    expect(grid.selectable, isTrue);
    grid.onSelectedIdsChanged!({'manual', 'production'});
    await tester.pumpAndSettle();
    await deleteSelection(tester, 2);
    expect(api.deleted, ['manual']);
    expect(table<StockDocListItem>(tester).selectedIds, {'production'});
  });

  testWidgets('仓库出库与草稿删除共享选择，各自按权限和状态显示动作', (tester) async {
    final api = _DraftApi('/stock/docs', {
      'manual': _row('manual'),
      'closed': {..._row('closed'), 'closed': true},
    });
    await pumpList(
      tester,
      api,
      const Scaffold(
        body: WarehouseStockDocSegment(docType: StockDocType.otherOut),
      ),
      permissions: {
        Perm.stockDocView,
        Perm.stockDocDelete,
        Perm.stockDocApprove,
      },
    );
    await selectFilterSegment(tester, '草稿');
    await tester.pumpAndSettle();
    table<StockDocListItem>(tester).onSelectedIdsChanged!({'closed'});
    await tester.pumpAndSettle();
    final outboundFinder = find.byKey(
      const Key('stock-doc-batch-outbound-OTHER_OUT'),
    );
    expect(tester.widget<UtenButton>(outboundFinder).onPressed, isNull);
    expect(find.text('删除所选草稿 (1)'), findsOneWidget);
    table<StockDocListItem>(tester).onSelectedIdsChanged!({'manual'});
    await tester.pumpAndSettle();
    expect(tester.widget<UtenButton>(outboundFinder).onPressed, isNotNull);
    await deleteSelection(tester, 1);
    expect(api.events, ['GET manual', 'DELETE manual']);
    expect(tester.widget<UtenButton>(outboundFinder).onPressed, isNull);
  });

  testWidgets('仓库内嵌草稿无删除权限保留原出库动作，不显示删除', (tester) async {
    final api = _DraftApi('/stock/docs', {'manual': _row('manual')});
    await pumpList(
      tester,
      api,
      const Scaffold(
        body: WarehouseStockDocSegment(docType: StockDocType.otherOut),
      ),
      permissions: {Perm.stockDocView, Perm.stockDocApprove},
    );
    await selectFilterSegment(tester, '草稿');
    await tester.pumpAndSettle();
    expect(table<StockDocListItem>(tester).selectable, isTrue);
    expect(find.text('删除所选草稿 (0)'), findsNothing);
    expect(
      find.byKey(const Key('stock-doc-batch-outbound-OTHER_OUT')),
      findsOneWidget,
    );
  });

  testWidgets('仓库内嵌草稿只有查看权限时不启用多选', (tester) async {
    final api = _DraftApi('/stock/docs', {'manual': _row('manual')});
    await pumpList(
      tester,
      api,
      const Scaffold(
        body: WarehouseStockDocSegment(docType: StockDocType.otherIn),
      ),
      permissions: {Perm.stockDocView},
    );
    await selectFilterSegment(tester, '草稿');
    await tester.pumpAndSettle();
    expect(table<StockDocListItem>(tester).selectable, isFalse);
    expect(find.text('删除所选草稿 (0)'), findsNothing);
  });

  testWidgets('仓库待收生产退料不是手工草稿，不提供批量删除', (tester) async {
    final api = _DraftApi('/stock/docs', {'production': _row('production')});
    await pumpList(
      tester,
      api,
      const Scaffold(
        body: WarehouseStockDocSegment(
          docType: StockDocType.wdraw,
          productionReturnRequests: true,
        ),
      ),
      permissions: {Perm.stockDocView, Perm.stockDocDelete},
    );
    await selectFilterSegment(tester, '待仓库收料');
    await tester.pumpAndSettle();
    expect(table<StockDocListItem>(tester).selectable, isFalse);
    expect(find.text('删除所选草稿 (0)'), findsNothing);
  });

  testWidgets('财务预检详情等待时更改筛选，不再发送删除', (tester) async {
    final gate = Completer<void>();
    final api = _DraftApi('/finance/receipts', {
      'a': _row('a'),
    }, detailGate: gate);
    await pumpList(
      tester,
      api,
      const FinanceDocListPage(
        docType: FinanceDocType.receipt,
        initialStatus: 'draft',
      ),
      permissions: {Perm.financeReceiptView, Perm.financeReceiptDelete},
    );
    table<FinanceDocListItem>(tester).onSelectedIdsChanged!({'a'});
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除所选草稿 (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pump();
    expect(api.detailReads, ['a']);
    table<FinanceDocListItem>(tester).onFilterChanged('accountId', 'other');
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(api.deleted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('仓库预检详情等待时更改筛选，不再发送删除', (tester) async {
    final gate = Completer<void>();
    final api = _DraftApi('/stock/docs', {'a': _row('a')}, detailGate: gate);
    await pumpList(
      tester,
      api,
      const StockDocListPage(
        docType: StockDocType.transfer,
        initialStatus: 'draft',
      ),
      permissions: {Perm.stockDocView, Perm.stockDocDelete},
    );
    table<StockDocListItem>(tester).onSelectedIdsChanged!({'a'});
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除所选草稿 (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pump();
    expect(api.detailReads, ['a']);
    table<StockDocListItem>(tester).onFilterChanged('warehouse', 'other');
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();
    expect(api.deleted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('仓库出库子流程期间禁用删除与勾选，go返回后恢复两种动作', (tester) async {
    final api = _DraftApi('/stock/docs', {'manual': _row('manual')});
    final router = await pumpList(
      tester,
      api,
      const Scaffold(
        body: WarehouseStockDocSegment(docType: StockDocType.otherOut),
      ),
      permissions: {
        Perm.stockDocView,
        Perm.stockDocDelete,
        Perm.stockDocApprove,
      },
      connectResume: true,
      extraRoutes: [
        GoRoute(
          path: '/warehouse/OTHER_OUT/:id',
          builder: (_, _) => const Scaffold(body: Text('模拟出库详情')),
        ),
      ],
    );
    await selectFilterSegment(tester, '草稿');
    await tester.pumpAndSettle();
    table<StockDocListItem>(tester).onSelectedIdsChanged!({'manual'});
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('stock-doc-batch-outbound-OTHER_OUT')),
    );
    await tester.pumpAndSettle();
    expect(find.text('模拟出库详情'), findsOneWidget);
    final parentTable = tester.widget<MasterDataTableView<StockDocListItem>>(
      find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView<StockDocListItem>,
        skipOffstage: false,
      ),
    );
    expect(parentTable.onSelectedIdsChanged, isNull);
    final deleteButton = tester.widget<UtenButton>(
      find.ancestor(
        of: find.text('删除所选草稿 (1)', skipOffstage: false),
        matching: find.byType(UtenButton, skipOffstage: false),
      ),
    );
    expect(deleteButton.onPressed, isNull);
    expect(api.events, isEmpty);

    router.go('/list?status=draft');
    await tester.pumpAndSettle();
    expect(find.text('模拟出库详情'), findsNothing);
    expect(table<StockDocListItem>(tester).onSelectedIdsChanged, isNotNull);
    expect(
      tester
          .widget<UtenButton>(
            find.ancestor(
              of: find.text('删除所选草稿 (1)'),
              matching: find.byType(UtenButton),
            ),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('仓库删除预检期间禁用出库与勾选，旧出库回调也不能启动', (tester) async {
    final gate = Completer<void>();
    final api = _DraftApi('/stock/docs', {
      'manual': _row('manual'),
    }, detailGate: gate);
    final router = await pumpList(
      tester,
      api,
      const Scaffold(
        body: WarehouseStockDocSegment(docType: StockDocType.otherOut),
      ),
      permissions: {
        Perm.stockDocView,
        Perm.stockDocDelete,
        Perm.stockDocApprove,
      },
    );
    await selectFilterSegment(tester, '草稿');
    await tester.pumpAndSettle();
    table<StockDocListItem>(tester).onSelectedIdsChanged!({'manual'});
    await tester.pumpAndSettle();
    final outboundFinder = find.byKey(
      const Key('stock-doc-batch-outbound-OTHER_OUT'),
    );
    final staleOutbound = tester.widget<UtenButton>(outboundFinder).onPressed!;
    await tester.tap(find.text('删除所选草稿 (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pump();
    expect(tester.widget<UtenButton>(outboundFinder).onPressed, isNull);
    expect(table<StockDocListItem>(tester).onSelectedIdsChanged, isNull);
    staleOutbound();
    await tester.pump();
    expect(topMatchedLocationOf(router), '/list');
    gate.complete();
    await tester.pumpAndSettle();
    expect(api.events, ['GET manual', 'DELETE manual']);
    expect(tester.takeException(), isNull);
  });
}

Map<String, dynamic> _row(
  String id, {
  String maker = 'owner',
  bool legacy = false,
}) => {
  'id': id,
  'billNo': 'DRAFT-$id',
  'billDate': '2026-09-26',
  'status': 0,
  'makerId': maker,
  'canDelete': true,
  if (legacy) 'legacyId': 123,
};

class _DraftApi extends ApiClient {
  _DraftApi(
    this.basePath,
    this.rows, {
    this.detailChanges = const {},
    this.deleteFailure,
    this.detailGate,
  }) : super(Dio());

  final String basePath;
  final Map<String, Map<String, dynamic>> rows;
  final Map<String, Map<String, dynamic>> detailChanges;
  final ApiException? deleteFailure;
  final Completer<void>? detailGate;
  final events = <String>[];
  final deleted = <String>[];
  final detailReads = <String>[];
  int listReads = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == basePath) {
      listReads++;
      final items = rows.values
          .where(
            (row) =>
                query?['status'] == null || row['status'] == query!['status'],
          )
          .toList();
      return {
        'items': items,
        'page': 1,
        'size': 20,
        'total': items.length,
        'totalPages': 1,
      };
    }
    if (path == '$basePath/facets') return {'billNo': <Object>[]};
    if (path.startsWith('$basePath/')) {
      final id = path.substring(basePath.length + 1);
      detailReads.add(id);
      events.add('GET $id');
      await detailGate?.future;
      return {...rows[id]!, ...?detailChanges[id]};
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<void> delete(String path) async {
    final id = path.substring(basePath.length + 1);
    events.add('DELETE $id');
    if (deleteFailure != null) throw deleteFailure!;
    deleted.add(id);
    rows.remove(id);
  }
}
