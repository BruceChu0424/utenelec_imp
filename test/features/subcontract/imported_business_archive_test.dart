import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_history_time_filter.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_business_list_pages.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/production/models/production_plan.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/features/finance/repositories/finance_repository.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/documents/imported_document_policy.dart';
import '../../support/native_detail_reader_overrides.dart';

const _types = [
  SubcontractDocType.order,
  SubcontractDocType.receipt,
  SubcontractDocType.materialIssue,
  SubcontractDocType.returnDoc,
  SubcontractDocType.materialReturn,
  SubcontractDocType.waste,
];

void main() {
  test(
    'all five shared historical repositories retain all-origin queries',
    () async {
      final api = _ScopeApi();
      await PurchaseRepository(api, PurchaseDocType.order).list(
        filter: const PurchaseDocFilter(origin: BusinessDocumentOrigin.all),
      );
      await SalesRepository(
        api,
        SalesDocType.order,
      ).list(filter: const SalesDocFilter(origin: BusinessDocumentOrigin.all));
      await FinanceRepository(api, FinanceDocType.receipt).list(
        filter: const FinanceDocFilter(origin: BusinessDocumentOrigin.all),
      );
      await ProductionPlanRepository(api).list(
        filter: const ProductionPlanFilter(origin: BusinessDocumentOrigin.all),
      );
      await StockDocRepository(api, StockDocType.otherIn).list(
        filter: const StockDocFilter(
          origin: BusinessDocumentOrigin.all,
          view: WarehouseTaskView.history,
        ),
      );
      expect(api.queries.length, 5);
      for (final query in api.queries) {
        expect(query['originScope'], 'ALL');
        for (final key in [
          'status',
          'closed',
          'financeApproval',
          'dateFrom',
          'dateTo',
        ]) {
          expect(query.containsKey(key), isFalse);
        }
      }
    },
  );
  test(
    'archive query ignores workflow slices while retaining explicit dates',
    () {
      final query = const SubcontractDocFilter(
        origin: BusinessDocumentOrigin.legacy,
        status: 1,
        financeApproval: 'IN_PROGRESS',
        closed: true,
        dateFrom: '2014-01-01',
        keyword: 'original',
      ).toQuery();
      expect(query, {
        'originScope': 'LEGACY',
        'dateFrom': '2014-01-01',
        'keyword': 'original',
      });
      expect(const SubcontractDocFilter(status: 0).toQuery(), {'status': 0});
    },
  );

  test(
    'legacy identity and server history flags fence every main document model',
    () {
      for (final marker in [
        {'legacyId': 12, 'legacyImported': false, 'historyReadOnly': false},
        {'historyReadOnly': true},
      ]) {
        final json = <String, dynamic>{'id': 'old', ...marker};
        expect(SubcontractDocDetail.fromJson(json).legacyImported, isTrue);
        expect(PurchaseDocDetail.fromJson(json).legacyImported, isTrue);
        expect(SalesDocDetail.fromJson(json).historyReadOnly, isTrue);
        expect(FinanceDocDetail.fromJson(json).legacyImported, isTrue);
        expect(ProductionPlanDetail.fromJson(json).legacyImported, isTrue);
        expect(ProductionDailyReportDetail.fromJson(json).canApprove, isFalse);
        expect(StockDocDetail.fromJson(json).historyReadOnly, isTrue);
      }
      expect(importedBusinessDocument({'id': 'native'}), isFalse);
      expect(
        importedDocumentPermissionAllowed('subcontract_order:edit', false),
        isTrue,
      );
      expect(
        importedDocumentPermissionAllowed('subcontract_order:edit', true),
        isFalse,
      );
      expect(
        importedDocumentPermissionAllowed('subcontract_order:view', true),
        isTrue,
      );
    },
  );

  for (final type in _types) {
    testWidgets(
      '${type.name} archive loads all years and raw0/-1/1 independently',
      (tester) async {
        final api = _ArchiveApi(type);
        await _mount(tester, api, SubcontractLegacyHistoryPage(type: type));
        expect(api.listQueries.single, {
          'page': 1,
          'size': 20,
          'originScope': 'LEGACY',
        });
        final table = tester
            .widget<MasterDataTableView<SubcontractDocListItem>>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is MasterDataTableView<SubcontractDocListItem>,
              ),
            );
        expect(table.items.map((row) => row.status), [0, -1, 1]);
        expect(
          table.items.every((row) => row.billDate == '2014-10-28'),
          isTrue,
        );
        final status = table.columns.singleWhere(
          (column) => column.key == 'status',
        );
        expect(
          table.items.map(status.value),
          everyElement(importedBusinessHistoryLabel),
        );
        expect(table.selectable, isFalse);
        expect(
          tester
              .widget<UtenHistoryTimeFilter>(find.byType(UtenHistoryTimeFilter))
              .value
              .all,
          isTrue,
        );
        expect(find.text('草稿'), findsNothing);
        expect(find.text('进行中'), findsNothing);
        expect(api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    for (final status in [0, 1, -1]) {
      testWidgets(
        '${type.name} imported $status cannot mutate despite stale true capabilities',
        (tester) async {
          final api = _ArchiveApi(type, status: status);
          await _mount(
            tester,
            api,
            SubcontractDocDetailPage(docType: type, id: 'history'),
          );
          for (final action in [
            '编辑',
            '编辑订货单',
            '删除',
            '审核',
            '审核入库',
            '红冲',
            '提交财务审核',
            '修改数量',
          ]) {
            expect(find.widgetWithText(UtenButton, action), findsNothing);
          }
          expect(api.writes, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

Future<void> _mount(WidgetTester tester, _ArchiveApi api, Widget page) async {
  tester.view.physicalSize = const Size(2300, 1700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => page)],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...nativeDetailReaderOverrides(),
        currentPermissionsProvider.overrideWithValue({
          for (final type in _types)
            ...SubcontractDocConfig.by(type).permissions.actionCodes,
          Perm.subcontractOrderSubmitFinance,
          Perm.subcontractOrderChangeQty,
          Perm.financeOrderApprovalView,
        }),
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ScopeApi extends ApiClient {
  _ScopeApi() : super(Dio());
  final queries = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add({...?query});
    return {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 1,
    };
  }
}

class _ArchiveApi extends ApiClient {
  _ArchiveApi(this.type, {this.status = 0}) : super(Dio());
  final SubcontractDocType type;
  final int status;
  final listQueries = <Map<String, dynamic>>[];
  final writes = <String>[];
  String get base => '/subcontract/${type.pathSegment}';
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == base) {
      listQueries.add({...?query});
      return {
        'items': [
          for (final value in [0, -1, 1])
            {
              'id': 'old$value',
              'legacyId': 901 + value,
              'status': value,
              'billNo': 'OLD$value',
              'billDate': '2014-10-28',
            },
        ],
        'page': 1,
        'size': 20,
        'total': 3,
        'totalPages': 1,
      };
    }
    if (path == '$base/history') {
      return {
        'id': 'history',
        'legacyId': 901,
        'billNo': 'OLD',
        'billDate': '2014-10-28',
        'status': status,
        'makerId': 'maker',
        'canEdit': true,
        'canDelete': true,
        'canReverse': true,
        'items': <Map<String, dynamic>>[],
      };
    }
    return {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 20,
      'total': 0,
      'totalPages': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add(path);
    return {};
  }
}
