import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_detail_page.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_list_page.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_detail_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_edit_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/historical_receipt_facts.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/widgets/historical_receipt_totals.dart';

import '../../support/document_scope_capability_overrides.dart';

void main() {
  test(
    'recorded null wins over a numeric fallback and exact decimals never round through double',
    () {
      final payload = <String, dynamic>{
        'id': 'line',
        'qty': 2,
        'qtyExact': '2.0000',
        'unitRate': 1,
        'unitRateExact': null,
        'amountOriginal': 0,
        'amountOriginalExact': null,
        'amountLocalExact': '9007199254740993.1234',
      };
      final purchase = PurchaseDocItem.fromJson(payload);
      final subcontract = SubcontractDocItem.fromJson(payload);
      expect(purchase.unitRateText, isNull);
      expect(subcontract.amountOriginalText, isNull);
      expect(
        historicalReceiptAmount(purchase.amountLocalText),
        '9007199254740993.1234',
      );
      expect(
        historicalReceiptTotal([purchase.amountLocalText, '0.0001']),
        '9007199254740993.1235',
      );
      expect(historicalReceiptTotal(['10', null]), '未知（1 行未记载）');
      expect(historicalReceiptAmount('0'), '0.00');
      expect(historicalReceiptRate('0'), '未知（原始值 0）');
    },
  );

  test(
    'old response legacy identity cannot be made writable by an explicit false flag',
    () {
      final payload = <String, dynamic>{
        'id': 'history',
        'legacyId': 901,
        'legacyImported': false,
      };
      expect(PurchaseDocDetail.fromJson(payload).legacyImported, isTrue);
      expect(SubcontractDocDetail.fromJson(payload).legacyImported, isTrue);
      expect(PurchaseDocListItem.fromJson(payload).legacyImported, isTrue);
      expect(SubcontractDocListItem.fromJson(payload).legacyImported, isTrue);
    },
  );

  testWidgets(
    'purchase history list identifies raw header totals and read-only status',
    (tester) async {
      final api = _HistoryApi(status: 0);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                const PurchaseDocListPage(docType: PurchaseDocType.receipt),
          ),
        ],
      );
      addTearDown(router.dispose);
      await _pump(tester, api, subcontract: false, router: router);
      await tester.tap(find.text('历史记录').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部').first);
      await tester.pumpAndSettle();
      expect(find.text('历史只读（草稿）'), findsOneWidget);
      expect(find.text('原始表头值 0.00'), findsOneWidget);
    },
  );

  for (final subcontract in [false, true]) {
    for (final status in [0, 1, -1]) {
      testWidgets(
        '${subcontract ? 'SC' : 'purchase'} historical receipt $status is read only and never relabels local cost as original',
        (tester) async {
          final api = _HistoryApi(status: status);
          await _pump(tester, api, subcontract: subcontract);
          expect(find.text(historicalReceiptReadOnlyMessage), findsOneWidget);
          for (final action in ['编辑', '删除', '审核', '审核入库', '红冲', '送检']) {
            expect(find.widgetWithText(UtenButton, action), findsNothing);
          }
          expect(find.byType(HistoricalReceiptTotals), findsOneWidget);
          expect(
            find.text('60.00'),
            findsNothing,
          ); // qty2 * price30 is not a missing source amount.
          expect(find.text('未知（1 行未记载）'), findsWidgets);
          if (subcontract) {
            final table = tester
                .widget<MasterDataTableView<SubcontractDocItem>>(
                  find.byType(MasterDataTableView<SubcontractDocItem>),
                );
            final row = table.items.single;
            expect(
              table.columns.singleWhere((c) => c.key == 'amount').value(row),
              '未知',
            );
            expect(
              table.columns
                  .singleWhere((c) => c.key == 'recordedLocalAmount')
                  .value(row),
              '123.4567',
            );
            expect(
              table.columns
                  .singleWhere((c) => c.key == 'recordedUnitRate')
                  .value(row),
              '未知（原始值 0.000000）',
            );
            expect(find.text('原始表头 Total'), findsOneWidget);
            expect(find.text('本币成本合计（STotal）: '), findsOneWidget);
          } else {
            final table = tester.widget<MasterDataTableView<PurchaseDocItem>>(
              find.byType(MasterDataTableView<PurchaseDocItem>),
            );
            final row = table.items.single;
            expect(
              table.columns.singleWhere((c) => c.key == 'amount').value(row),
              '未知',
            );
            expect(
              table.columns
                  .singleWhere((c) => c.key == 'recordedLocalAmount')
                  .value(row),
              '123.4567',
            );
            expect(
              table.columns
                  .singleWhere((c) => c.key == 'recordedUnitRate')
                  .value(row),
              '未知（原始值 0.000000）',
            );
          }
          expect(api.writes, isEmpty);
        },
      );
    }
    testWidgets(
      '${subcontract ? 'SC' : 'purchase'} direct historical edit URL returns to a read-only detail',
      (tester) async {
        final api = _HistoryApi(status: 0);
        final detailPath = subcontract
            ? SubcontractRoute.detail('receipts', 'history')
            : RoutePath.purchaseDocDetail('receipts', 'history');
        final router = GoRouter(
          initialLocation: '/edit',
          routes: [
            GoRoute(
              path: '/edit',
              builder: (_, _) => subcontract
                  ? const SubcontractDocEditPage(
                      docType: SubcontractDocType.receipt,
                      id: 'history',
                    )
                  : const PurchaseDocEditPage(
                      docType: PurchaseDocType.receipt,
                      id: 'history',
                    ),
            ),
            GoRoute(path: detailPath, builder: (_, _) => _detail(subcontract)),
          ],
        );
        addTearDown(router.dispose);
        await _pump(tester, api, subcontract: subcontract, router: router);
        expect(router.routeInformationProvider.value.uri.path, detailPath);
        expect(find.text(historicalReceiptReadOnlyMessage), findsWidgets);
        expect(find.byType(PurchaseDocEditPage), findsNothing);
        expect(find.byType(SubcontractDocEditPage), findsNothing);
        expect(api.writes, isEmpty);
      },
    );
  }
}

Widget _detail(bool subcontract) => subcontract
    ? const SubcontractDocDetailPage(
        docType: SubcontractDocType.receipt,
        id: 'history',
      )
    : const PurchaseDocDetailPage(
        docType: PurchaseDocType.receipt,
        id: 'history',
      );

Future<void> _pump(
  WidgetTester tester,
  _HistoryApi api, {
  required bool subcontract,
  GoRouter? router,
}) async {
  tester.view.physicalSize = const Size(2300, 1700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        writeAllDocumentScope(DocumentDataScope.purchase),
        writeAllDocumentScope(DocumentDataScope.subcontract),
        currentPermissionsProvider.overrideWithValue({
          Perm.purchaseReceiptView,
          Perm.purchaseReceiptEdit,
          Perm.purchaseReceiptDelete,
          Perm.purchaseReceiptApprove,
          Perm.purchaseReceiptReverse,
          Perm.purchaseReceiptPriceView,
          Perm.subcontractReceiptView,
          Perm.subcontractReceiptEdit,
          Perm.subcontractReceiptDelete,
          Perm.subcontractReceiptApprove,
          Perm.subcontractReceiptReverse,
          Perm.subcontractReceiptPriceView,
        }),
        purchaseRepositoryProvider(
          PurchaseDocType.receipt,
        ).overrideWithValue(PurchaseRepository(api, PurchaseDocType.receipt)),
        subcontractRepositoryProvider(
          SubcontractDocType.receipt,
        ).overrideWithValue(
          SubcontractRepository(api, SubcontractDocType.receipt),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
      ],
      child: router == null
          ? MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: _detail(subcontract),
            )
          : MaterialApp.router(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: router,
            ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

class _HistoryApi extends ApiClient {
  _HistoryApi({required this.status}) : super(Dio());
  final int status;
  final List<String> writes = [];
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('currencies')) {
      return [
        {'id': 'usd', 'name': '美元'},
      ];
    }
    if (path.contains('units')) {
      return [
        {'id': 'unit', 'name': '件'},
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/receipts')) {
      final items = query?['status'] == 0
          ? <Map<String, dynamic>>[]
          : [
              {
                'id': 'history',
                'legacyId': 901001,
                'billNo': 'SYN-HISTORY',
                'billDate': '2025-01-02',
                'status': status,
                'totalLocal': 0,
              },
            ];
      return {
        'items': items,
        'total': items.length,
        'page': 1,
        'size': 50,
        'totalPages': 1,
      };
    }
    if (path.endsWith('/history')) {
      return {
        'id': 'history',
        'legacyId': 901001,
        'billNo': 'SYN-HISTORY',
        'billDate': '2025-01-02',
        'status': status,
        'makerId': 'maker',
        'canEdit': true,
        'canDelete': true,
        'canReverse': true,
        'currencyId': 'usd',
        'exchangeRate': null,
        'exchangeRateExact': null,
        'totalOriginal': 0,
        'totalOriginalExact': '0',
        'totalLocal': null,
        'totalLocalExact': null,
        'items': [
          {
            'id': 'line',
            'goodsId': 'goods',
            'unitId': 'unit',
            'unitRate': 0,
            'unitRateExact': '0.000000',
            'qty': 2,
            'qtyExact': '2.0000',
            'price': 30,
            'priceExact': '30.0000',
            'amountOriginal': null,
            'amountOriginalExact': null,
            'amountLocal': 123.4567,
            'amountLocalExact': '123.4567',
          },
        ],
      };
    }
    return {
      'items': <Map<String, dynamic>>[],
      'total': 0,
      'page': 1,
      'totalPages': 1,
      'size': 50,
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

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writes.add(path);
    return {};
  }

  @override
  Future<void> delete(String path) async {
    writes.add(path);
  }
}
