import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_list_page.dart';
import 'package:uten_imp/features/finance/repositories/finance_repository.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_business_list_pages.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_category.dart';
import 'package:uten_imp/shared/drafts/form_draft_category_table.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../helpers/badge_summary_fixture.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'reader', code: 'reader', name: '筛选读者'),
  );
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Drafts extends FormDraftsNotifier {
  @override
  List<FormDraft> build() => const [];
}

Future<void> _pumpPage(
  WidgetTester tester,
  _Api api,
  Widget page, {
  Set<String>? extraPermissions,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({'performancePreference': 'lite'});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => page)],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(_Session.new),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        apiBaseUrlProvider.overrideWithValue('https://filters.invalid/api'),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeReceiptView,
          Perm.subcontractReturnView,
          ...?extraPermissions,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        formDraftsProvider.overrideWith(_Drafts.new),
        fixedBadgeSummaryOverride(),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

class _Api extends ApiClient {
  _Api({this.financeRows = const []}) : super(Dio());
  final List<Map<String, dynamic>> financeRows;
  final calls = <({String path, Map<String, dynamic> query})>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    calls.add((path: path, query: {...?query}));
    final rows =
        {
          '/finance/receipts',
          '/finance/payments',
          '/finance/expenses',
          '/finance/incomes',
          '/finance/bank-transfers',
        }.contains(path)
        ? financeRows
        : const <Map<String, dynamic>>[];
    return path.endsWith('/facets')
        ? {'billNo': <Object>[]}
        : {'items': rows, 'page': 1, 'total': rows.length, 'totalPages': 1};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

void main() {
  for (final type in FinanceDocType.values) {
    testWidgets(
      'finance $type list preserves exact amount beyond double cents',
      (tester) async {
        final payload = <String, dynamic>{
          'id': 'exact-amount',
          'billNo': 'EXACT-001',
          'billDate': '2026-10-02',
          'status': 1,
          'amountLocal': 90071992547409.93,
          'amountLocalExact': '90071992547409.93',
        };
        await _pumpPage(
          tester,
          _Api(financeRows: [payload]),
          FinanceDocListPage(docType: type),
          extraPermissions: {FinanceDocConfig.by(type).listPerm},
        );
        final table = tester.widget<MasterDataTableView<FinanceDocListItem>>(
          find.byWidgetPredicate(
            (widget) => widget is MasterDataTableView<FinanceDocListItem>,
          ),
        );
        final amount = table.columns.singleWhere(
          (column) => column.key == 'amountLocal',
        );
        expect(table.items, hasLength(1));
        final item = table.items.single;
        expect(item.amountLocal!.toStringAsFixed(2), '90071992547409.94');
        expect(amount.value(item), '90071992547409.93');
        expect(
          amount.value(
            FinanceDocListItem.fromJson({
              'id': 'unknown-amount',
              'billNo': 'UNKNOWN-001',
              'status': 1,
            }),
          ),
          '—',
        );
        expect(
          amount.value(
            FinanceDocListItem.fromJson({
              'id': 'zero-amount',
              'billNo': 'ZERO-001',
              'status': 1,
              'amountLocal': 0,
              'amountLocalExact': '0',
            }),
          ),
          '0.00',
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'finance $type list keeps missing and partial historical dates readable',
      (tester) async {
        final samples = <String?, String?>{
          null: null,
          '': '',
          '2026': '2026',
          '2026-10-02': '2026-10-02',
          '2026-10-02T23:30:00Z': '2026-10-02',
        };
        await _pumpPage(
          tester,
          _Api(
            financeRows: [
              for (final (index, sample) in samples.entries.indexed)
                {
                  'id': 'date-$index',
                  'billNo': 'DATE-$index',
                  'status': 1,
                  'billDate': sample.key,
                },
            ],
          ),
          FinanceDocListPage(docType: type),
          extraPermissions: {FinanceDocConfig.by(type).listPerm},
        );
        final table = tester.widget<MasterDataTableView<FinanceDocListItem>>(
          find.byWidgetPredicate(
            (widget) => widget is MasterDataTableView<FinanceDocListItem>,
          ),
        );
        final date = table.columns.singleWhere(
          (column) => column.key == 'billDate',
        );
        expect(table.items, hasLength(samples.length));
        for (final item in table.items) {
          expect(date.value(item), samples[item.billDate]);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'finance source header reloads page one and its bill-number facet together',
    (tester) async {
      final api = _Api();
      await _pumpPage(
        tester,
        api,
        const FinanceDocListPage(docType: FinanceDocType.receipt),
      );
      MasterDataTableView<FinanceDocListItem> table() => tester.widget(
        find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<FinanceDocListItem>,
        ),
      );
      expect(table().facets['recordOrigin']!.map((bucket) => bucket.value), [
        'CURRENT',
        'LEGACY',
      ]);
      expect(
        table().columns
            .singleWhere((column) => column.key == 'recordOrigin')
            .filterFromRows,
        isFalse,
      );
      for (final origin in <String?>['LEGACY', 'CURRENT', null]) {
        api.calls.clear();
        table().onFilterChanged('recordOrigin', origin);
        await tester.pumpAndSettle();
        final list = api.calls.lastWhere(
          (call) => call.path == '/finance/receipts',
        );
        final facet = api.calls.lastWhere(
          (call) => call.path == '/finance/receipts/facets',
        );
        expect(list.query['page'], 1);
        expect(list.query['hf.recordOrigin'], origin);
        expect(facet.query['hf.recordOrigin'], origin);
        expect(list.query.containsKey('hf.recordOrigin'), origin != null);
        expect(table().filters['recordOrigin'], origin);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'return AP header sends true false and clear without client-side row filtering',
    (tester) async {
      final api = _Api();
      await _pumpPage(
        tester,
        api,
        const SubcontractFinishedReturnHistoryPage(initialStatus: 'draft'),
      );
      MasterDataTableView<SubcontractDocListItem> table() => tester
          .widget<FormDraftCategoryTable<SubcontractDocListItem>>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is FormDraftCategoryTable<SubcontractDocListItem>,
            ),
          )
          .table;
      expect(table().facets['apReverse']!.map((bucket) => bucket.value), [
        'true',
        'false',
      ]);
      expect(
        table().columns
            .singleWhere((column) => column.key == 'apReverse')
            .filterFromRows,
        isFalse,
      );
      for (final posted in <String?>['true', 'false', null]) {
        api.calls.clear();
        table().onFilterChanged('apReverse', posted);
        await tester.pumpAndSettle();
        final list = api.calls.lastWhere(
          (call) => call.path == '/subcontract/returns',
        );
        final facet = api.calls.lastWhere(
          (call) => call.path == '/subcontract/returns/facets',
        );
        expect(list.query['page'], 1);
        expect(
          list.query['hf.apPosted'],
          posted == null ? null : posted == 'true',
        );
        expect(facet.query['hf.apPosted'], list.query['hf.apPosted']);
        expect(list.query.containsKey('hf.apPosted'), posted != null);
        expect(list.query['status'], 0);
        expect(table().filters['apReverse'], posted);
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final type in FinanceDocType.values) {
    test(
      '${type.name} origin applies to list and bill-number facets with the same scope',
      () async {
        final api = _Api();
        final repository = FinanceRepository(api, type);
        const filter = FinanceDocFilter(
          recordOrigin: FinanceRecordOrigin.legacy,
          keyword: 'invoice',
          status: 1,
          dateFrom: '2025-01-01',
          dateTo: '2026-10-01',
          billNo: 'EXACT-1',
        );
        await repository.list(page: 3, filter: filter);
        await repository.billNoFacets(filter: filter);
        final list = api.calls[0];
        final facets = api.calls[1];
        expect(list.path, '/finance/${type.pathSegment}');
        expect(facets.path, '${list.path}/facets');
        expect(list.query['hf.recordOrigin'], 'LEGACY');
        expect(facets.query['hf.recordOrigin'], 'LEGACY');
        for (final field in ['keyword', 'status', 'dateFrom', 'dateTo']) {
          expect(facets.query[field], list.query[field], reason: field);
        }
        expect(list.query['billNo'], 'EXACT-1');
        expect(facets.query.containsKey('billNo'), isFalse);
        await repository.list(
          filter: const FinanceDocFilter(
            recordOrigin: FinanceRecordOrigin.current,
          ),
        );
        expect(api.calls.last.query['hf.recordOrigin'], 'CURRENT');
        await repository.list();
        expect(api.calls.last.query.containsKey('hf.recordOrigin'), isFalse);
      },
    );
  }

  for (final posted in [true, false, null]) {
    test(
      'return apPosted=$posted preserves false versus no filter in list and facets',
      () async {
        final api = _Api();
        final repository = SubcontractRepository(
          api,
          SubcontractDocType.returnDoc,
        );
        final filter = SubcontractDocFilter(
          apPosted: posted,
          supplierId: 'supplier-1',
          warehouseId: 'warehouse-1',
          status: 1,
          billNo: 'RETURN-1',
        );
        await repository.list(filter: filter);
        await repository.billNoFacets(filter: filter);
        expect(api.calls.first.path, '/subcontract/returns');
        for (final call in api.calls) {
          expect(call.query.containsKey('hf.apPosted'), posted != null);
          expect(call.query['hf.apPosted'], posted);
          expect(call.query['supplierId'], 'supplier-1');
          expect(call.query['warehouseId'], 'warehouse-1');
          expect(call.query['status'], 1);
        }
        expect(api.calls.last.query.containsKey('billNo'), isFalse);
      },
    );
  }

  test(
    'local editor draft belongs to current source and missing AP status is not invented false',
    () {
      FormDraft draft(Map<String, dynamic> data) => FormDraft(
        id: 'local-1',
        title: '退回草稿',
        module: BadgeModule.subcontract,
        route: '/subcontract/returns/new',
        permission: '',
        updatedAt: DateTime(2026, 10),
        data: data,
      );
      expect(formDraftColumnRawValues(draft({}), 'recordOrigin'), {'CURRENT'});
      expect(formDraftColumnValue(draft({}), 'recordOrigin'), '本机草稿');
      expect(formDraftColumnRawValues(draft({}), 'apReverse'), isEmpty);
      expect(
        formDraftColumnRawValues(
          draft({
            'sourceReceipt': {'apPosted': true},
          }),
          'apReverse',
        ),
        isEmpty,
        reason: 'a nested source receipt does not establish draft AP posting',
      );
      expect(
        formDraftColumnRawValues(draft({'apPosted': false}), 'apReverse'),
        {'false'},
      );
      expect(formDraftColumnRawValues(draft({'apPosted': true}), 'apReverse'), {
        'true',
      });
    },
  );
}
