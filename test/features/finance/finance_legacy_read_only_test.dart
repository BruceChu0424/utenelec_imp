import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_table_facets.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/sales_order_money_summary_card.dart';

import '../../support/document_scope_capability_overrides.dart';

void main() {
  test(
    'legacy identity cannot be made writable by an absent or false new flag',
    () {
      for (final payload in [
        <String, dynamic>{'id': 'legacy', 'legacyId': 7},
        <String, dynamic>{
          'id': 'legacy',
          'legacyId': 7,
          'legacyImported': false,
        },
        <String, dynamic>{'id': 'legacy', 'legacyImported': true},
        <String, dynamic>{'id': 'legacy', 'receiptKind': 'LEGACY_UNCLASSIFIED'},
      ]) {
        expect(FinanceDocListItem.fromJson(payload).legacyImported, isTrue);
        expect(FinanceDocDetail.fromJson(payload).legacyImported, isTrue);
      }
      expect(
        FinanceDocDetail.fromJson({'id': 'current'}).legacyImported,
        isFalse,
      );
      expect(
        const FinanceDocDetail(id: 'legacy', legacyId: 7).legacyImported,
        isTrue,
      );
      expect(financeReceiptKindLabel('LEGACY_UNCLASSIFIED'), '历史收款类型待核实');
      expect(
        financeReceiptKindLabel('CUSTOMER_PREPAYMENT', historical: true),
        contains('待核实'),
      );
      expect(financeReceiptKindLabel('AR_SETTLEMENT'), '货款收款(核销应收)');
    },
  );

  for (final type in FinanceDocType.values) {
    for (final status in [0, 1]) {
      testWidgets(
        'legacy ${type.name} status $status stays read-only even with every action permission',
        (tester) async {
          final api = _HistoryApi(status: status);
          await _pump(tester, api, type: type);
          expect(find.text(financeLegacyReadOnlyMessage), findsOneWidget);
          for (final action in ['编辑', '删除', '审核', '红冲', '财务确认']) {
            expect(find.text(action), findsNothing);
          }
          if (type == FinanceDocType.receipt) {
            expect(find.text('历史收款类型待核实'), findsOneWidget);
            expect(find.text('原始收款金额'), findsOneWidget);
            expect(find.text('原始本币金额'), findsOneWidget);
            expect(find.text('本批核销折算合计(人民币)'), findsNothing);
            expect(find.text('应收币种'), findsNothing);
            expect(find.byType(SalesOrderMoneySummaryCard), findsNothing);
          }
          expect(api.writes, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'list labels original money as read-only without relabeling its approved status',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/finance/receipts',
        routes: [
          GoRoute(
            path: '/finance/receipts',
            builder: (_, _) =>
                const FinanceDocListPage(docType: FinanceDocType.receipt),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(tester, _HistoryApi(status: 1), router: router);
      expect(find.text('历史记录（只读）'), findsOneWidget);
      expect(find.text('历史收款类型待核实'), findsOneWidget);
      expect(find.text('已审'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the reversed column filter sends the actual -1 financial status',
    (tester) async {
      final api = _HistoryApi(status: -1);
      final router = GoRouter(
        initialLocation: '/finance/receipts',
        routes: [
          GoRoute(
            path: '/finance/receipts',
            builder: (_, _) =>
                const FinanceDocListPage(docType: FinanceDocType.receipt),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(tester, api, router: router);
      final table = tester.widget<MasterDataTableView<FinanceDocListItem>>(
        find.byType(MasterDataTableView<FinanceDocListItem>),
      );
      table.onFilterChanged(
        'status',
        financeDocumentStatusFacets
            .singleWhere((facet) => facet.label == '红冲')
            .value,
      );
      await tester.pumpAndSettle();
      expect(api.listQueries.last['status'], -1);
      expect(find.text('历史记录（只读）'), findsOneWidget);
    },
  );

  testWidgets(
    'old guessed prepayment classification remains explicitly historical and has no live balance card',
    (tester) async {
      final api = _HistoryApi(kind: 'CUSTOMER_PREPAYMENT');
      await _pump(tester, api);
      expect(find.text('历史标记：客户订单预收（待核实）'), findsOneWidget);
      expect(find.byType(SalesOrderMoneySummaryCard), findsNothing);
      expect(find.text('本批预收原币金额'), findsNothing);
      expect(api.writes, isEmpty);
    },
  );

  testWidgets('historical type marker never hides original detail lines', (
    tester,
  ) async {
    await _pump(
      tester,
      _HistoryApi(kind: 'CUSTOMER_PREPAYMENT', withLines: true),
    );
    expect(find.text('历史原始明细'), findsOneWidget);
    expect(find.text('历史标记：客户订单预收（待核实）'), findsOneWidget);
    expect(find.byType(SalesOrderMoneySummaryCard), findsNothing);
  });

  testWidgets(
    'direct edit URL for an imported draft redirects to its read-only detail',
    (tester) async {
      final api = _HistoryApi();
      final router = GoRouter(
        initialLocation: '/finance/receipts/history/edit',
        routes: [
          GoRoute(
            path: '/finance/receipts/history/edit',
            builder: (_, _) => const FinanceDocEditPage(
              docType: FinanceDocType.receipt,
              id: 'history',
            ),
          ),
          GoRoute(
            path: '/finance/receipts/history',
            builder: (_, _) => const FinanceDocDetailPage(
              docType: FinanceDocType.receipt,
              id: 'history',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(tester, api, router: router);
      expect(
        router.routeInformationProvider.value.uri.path,
        '/finance/receipts/history',
      );
      expect(find.byType(FinanceDocEditPage), findsNothing);
      expect(find.text('保存'), findsNothing);
      expect(find.text(financeLegacyReadOnlyMessage), findsWidgets);
      expect(api.writes, isEmpty);
    },
  );

  testWidgets(
    'a current receipt with no explicit kind is not guessed from empty lines',
    (tester) async {
      final api = _HistoryApi(imported: false, kind: null);
      await _pump(tester, api, edit: true);
      expect(
        find.byKey(const ValueKey('finance-doc-edit-load-error')),
        findsOneWidget,
      );
      expect(find.textContaining('收款类型待核实，不能根据明细数量推断或编辑。'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
      expect(find.text('登记订单预收'), findsNothing);
      expect(api.writes, isEmpty);
    },
  );

  for (final status in [0, 1]) {
    testWidgets(
      'current explicitly classified receipt status $status retains its normal actions',
      (tester) async {
        await _pump(
          tester,
          _HistoryApi(status: status, imported: false, kind: 'AR_SETTLEMENT'),
        );
        expect(find.text(financeLegacyReadOnlyMessage), findsNothing);
        if (status == 0) {
          expect(find.text('编辑'), findsOneWidget);
          expect(find.text('删除'), findsOneWidget);
          expect(find.text('审核'), findsOneWidget);
        } else {
          expect(find.text('红冲'), findsOneWidget);
        }
      },
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  _HistoryApi api, {
  FinanceDocType type = FinanceDocType.receipt,
  GoRouter? router,
  bool edit = false,
}) async {
  tester.view.physicalSize = const Size(1300, 1900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final config = FinanceDocConfig.by(type);
  final permissions = {
    config.listPerm,
    ?config.editPerm,
    ?config.deletePerm,
    ?config.approvePerm,
    ?config.reversePerm,
    Perm.financeViewAll,
    Perm.financeExpenseGlConfirm,
    Perm.customerPrepaymentView,
  };
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        financeWriteAllDocumentScope(),
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: router == null
          ? MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              home: edit
                  ? FinanceDocEditPage(docType: type, id: 'history')
                  : FinanceDocDetailPage(docType: type, id: 'history'),
            )
          : MaterialApp.router(
              routerConfig: router,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
            ),
    ),
  );
  await tester.pumpAndSettle();
}

class _HistoryApi extends ApiClient {
  _HistoryApi({
    this.status = 0,
    this.imported = true,
    this.kind = 'LEGACY_UNCLASSIFIED',
    this.withLines = false,
  }) : super(Dio());
  final int status;
  final bool imported;
  final String? kind;
  final bool withLines;
  final writes = <String>[];
  final listQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('scope')) {
      return {
        'scope': 'finance',
        'writeAll': true,
        'writableOwnerIds': <String>[],
      };
    }
    final detail = {
      'id': 'history', 'billNo': 'XS-HISTORY', 'billDate': '2025-01-02',
      'status': status, 'glStatus': 1, 'makerId': 'maker',
      if (imported) 'legacyId': 906002,
      // Deliberately omit legacyImported to exercise older server responses.
      'receiptKind': kind, 'salesOrderId': 'old-order',
      'amountOriginal': 8, 'amountLocal': 8, 'exchangeRate': 1,
      'settlementAuthorityVersion': 0,
      'items': <Map<String, dynamic>>[
        if (withLines)
          {'id': 'original-line', 'amountLocal': 8, 'remark': '历史原始明细'},
      ],
    };
    if (path == '/finance/receipts') {
      listQueries.add({...?query});
      return {
        'items': [detail],
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
      };
    }
    return detail;
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
    throw StateError('unexpected financial mutation');
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writes.add('PUT $path');
    throw StateError('unexpected financial mutation');
  }

  @override
  Future<void> delete(String path) async {
    writes.add('DELETE $path');
    throw StateError('unexpected financial mutation');
  }
}
