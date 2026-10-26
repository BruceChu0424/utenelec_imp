import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/layout/uten_doc_link_picker_sheet.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/purchase/config/purchase_doc_config.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/features/purchase/widgets/doc_link_picker.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_doc_config.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_link_picker.dart'
    as subcontract;
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _Names extends MasterNameService {
  _Names(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsNames(Iterable<String> ids) async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  Map<String, String> get supplierEntries => {'supplier': '测试供应商'};
  @override
  String supplier(String? id) => '测试供应商';
  @override
  String goods(String? id) => '精确物料';
  @override
  GoodsDictEntry? goodsInfo(String? id) =>
      const GoodsDictEntry(name: '精确物料', code: 'G-EXACT', unitId: 'piece');
  @override
  String unit(String? id) => '件';
}

class _Api extends ApiClient {
  _Api(this.item, {this.sourceClosed = false, this.sourceTerminated = false})
    : super(Dio());
  final Map<String, dynamic> item;
  final bool sourceClosed;
  final bool sourceTerminated;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.endsWith('/source-doc')
      ? {
          'id': 'source-doc',
          'billNo': 'CS-EXACT',
          'status': 1,
          'closed': sourceClosed,
          if (sourceTerminated)
            'closureRequest': {
              'caseId': 'finance-stop',
              'status': 'APPROVED',
              'mode': 'CLOSE',
            },
          'items': [item],
        }
      : {
          'items': [
            {
              'id': 'source-doc',
              'billNo': 'CS-EXACT',
              'billDate': '2026-10-11',
              'status': 1,
            },
          ],
          'page': 1,
          'size': 20,
          'total': 1,
          'totalPages': 1,
        };
}

Future<Map<String, Object?>> _open(
  WidgetTester tester,
  PurchaseDocType type,
  Map<String, dynamic> item, {
  bool sourceClosed = false,
  bool sourceTerminated = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _Api(
    item,
    sourceClosed: sourceClosed,
    sourceTerminated: sourceTerminated,
  );
  final upstream = type == PurchaseDocType.order
      ? PurchaseDocType.request
      : PurchaseDocType.order;
  final holder = <String, Object?>{};
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        purchaseRepositoryProvider(
          upstream,
        ).overrideWithValue(PurchaseRepository(api, upstream)),
        masterNameServiceProvider.overrideWithValue(_Names(api)),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () {
                holder['result'] = showDocLinkPicker(
                  context,
                  ref,
                  PurchaseDocConfig.by(type),
                  allowOverRemaining: type == PurchaseDocType.order,
                );
              },
              child: const Text('打开来源'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开来源'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('CS-EXACT'));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.text('CS-EXACT'));
  await tester.pumpAndSettle();
  return holder;
}

void main() {
  testWidgets(
    'ended order selected before finance approval cannot become a receipt source',
    (tester) async {
      await _open(
        tester,
        PurchaseDocType.receipt,
        {
          'id': 'line-closed',
          'goodsId': 'goods',
          'unitId': 'piece',
          'qty': 10,
          'receivedQty': 4,
          'returnedQty': 0,
        },
        sourceClosed: true,
        sourceTerminated: true,
      );
      expect(
        find.byType(UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>),
        findsNothing,
      );
      expect(find.textContaining('来源订货单已结束'), findsOneWidget);
    },
  );
  testWidgets(
    'natural completion retains the existing approved over-receipt allowance',
    (tester) async {
      await _open(tester, PurchaseDocType.receipt, {
        'id': 'natural',
        'goodsId': 'goods',
        'unitId': 'piece',
        'qty': 10,
        'receivedQty': 10,
        'returnedQty': 0,
        'allowedOverReceiptPct': 10,
      }, sourceClosed: true);
      final grid = tester
          .widget<UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>>(
            find.byType(UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>),
          );
      expect(grid.controller.rows.single.qty.text, '1');
      expect(find.textContaining('来源订货单已结束'), findsNothing);
    },
  );
  for (final missing in ['receivedQty', 'returnedQty']) {
    testWidgets(
      'actual purchase receipt source does not invent missing $missing',
      (tester) async {
        await _open(tester, PurchaseDocType.receipt, {
          'id': 'line-unknown',
          'goodsId': 'goods',
          'unitId': 'piece',
          'qty': 10,
          'qtyExact': '10',
          'receivedQty': 0,
          'receivedQtyExact': '0',
          'returnedQty': 0,
          'returnedQtyExact': '0',
          missing: null,
          '${missing}Exact': null,
        });
        final grid = tester
            .widget<UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>>(
              find.byType(
                UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>,
              ),
            );
        expect(
          grid.controller.rows,
          isEmpty,
          reason: 'Unknown facts cannot become an available source quantity',
        );
        expect(find.textContaining('来源数量不完整'), findsOneWidget);
        expect(find.text('该单据明细已全部完成，无剩余可引入'), findsNothing);
      },
    );
  }
  for (final received in <double?>[null, 9]) {
    testWidgets(
      'actual subcontract receipt source keeps the net remainder received=$received',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final api = _Api({
          'id': 'line-unknown',
          'goodsId': 'goods',
          'unitId': 'piece',
          'qty': 10,
          'qtyExact': '10',
          'receivedQty': received,
          'returnedQty': 2,
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              subcontractRepositoryProvider(
                SubcontractDocType.order,
              ).overrideWithValue(
                SubcontractRepository(api, SubcontractDocType.order),
              ),
              masterNameServiceProvider.overrideWithValue(_Names(api)),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) => ElevatedButton(
                    onPressed: () => subcontract.showSubcontractLinkPicker(
                      context,
                      ref,
                      SubcontractDocConfig.by(SubcontractDocType.receipt),
                    ),
                    child: const Text('打开来源'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开来源'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('CS-EXACT'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('CS-EXACT'));
        await tester.pumpAndSettle();
        final grid = tester
            .widget<UtenEditableGrid<UtenDocLinkItemRow<SubcontractDocItem>>>(
              find.byType(
                UtenEditableGrid<UtenDocLinkItemRow<SubcontractDocItem>>,
              ),
            );
        if (received == null) {
          expect(
            grid.controller.rows,
            isEmpty,
            reason: 'Missing cumulative receipt is unknown, not zero',
          );
          expect(find.textContaining('来源数量不完整'), findsOneWidget);
        } else {
          expect(grid.controller.rows.single.qty.text, '3.0');
          expect(find.textContaining('来源数量不完整'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'actual purchase request source picker allows paid9 plus extra gift1 and keeps source identity',
    (tester) async {
      final holder = await _open(tester, PurchaseDocType.order, {
        'id': 'line-1',
        'goodsId': 'goods',
        'unitId': 'piece',
        'qty': 10,
        'qtyExact': '10',
        'orderedQty': 0,
        'orderedQtyExact': '0',
        'remainingQty': 10,
        'remainingQtyExact': '10',
        'quantitySemantics': 'CHARGED_PLUS_GIFT_V1',
        'giftQty': 0,
        'giftQtyExact': '0',
        'remainingGiftQtyExact': '0',
        'physicalRemainingQtyExact': '10',
      });
      final finder = find.byType(
        UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>,
      );
      final grid = tester
          .widget<UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>>(
            finder,
          );
      final row = grid.controller.rows.single;
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && identical(w.controller, row.qty),
        ),
        '9',
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && identical(w.controller, row.giftQty),
        ),
        '1',
      );
      await tester.ensureVisible(find.byType(Checkbox).first);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect(row.selected, isTrue);
      expect(row.qty.text, '9');
      expect(row.giftQty.text, '1');
      await tester.tap(find.text('引入'));
      await tester.pumpAndSettle();
      expect(
        row.qtyError.value,
        isNull,
        reason: 'Only a new-order source may offer extra gifts',
      );
      expect(finder, findsNothing);
      final result =
          await (holder['result']! as Future<PurchaseLinkPickResult?>);
      expect(result!.items.single.qtyText, '9');
      expect(result.items.single.giftQtyText, '1');
      expect(result.items.single.maxGiftQtyText, isNull);
      expect(result.items.single.upstreamItemId, 'line-1');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'actual request picker renders exact source counters and tiny recorded remainder',
    (tester) async {
      final holder = await _open(tester, PurchaseDocType.order, {
        'id': 'line-1',
        'goodsId': 'goods',
        'unitId': 'piece',
        'qty': 100000000000000,
        'qtyExact': '99999999999999.9999',
        'orderedQty': 100000000000000,
        'orderedQtyExact': '99999999999999.9998',
        'remainingQty': 0.0001,
        'remainingQtyExact': '0.0001',
        'quantitySemantics': 'LEGACY_RECORDED',
        'giftQty': 1,
        'giftQtyExact': '1',
        'remainingGiftQtyExact': '0',
        'physicalRemainingQtyExact': '0.0001',
      });
      expect(find.text('精确物料'), findsOneWidget);
      expect(find.text('99999999999999.9999'), findsOneWidget);
      expect(find.text('99999999999999.9998'), findsOneWidget);
      expect(find.text('0.0001 件'), findsOneWidget);
      await tester.ensureVisible(find.byType(Checkbox).first);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      await tester.tap(find.text('引入'));
      await tester.pumpAndSettle();
      expect(
        find.byType(UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>),
        findsNothing,
      );
      final result =
          await (holder['result']! as Future<PurchaseLinkPickResult?>);
      expect(result!.items.single.qtyText, '0.0001');
      expect(result.items.single.giftQtyText, '0');
      expect(result.items.single.upstreamItemId, 'line-1');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('actual receipt source picker keeps approved gift quota strict', (
    tester,
  ) async {
    await _open(tester, PurchaseDocType.receipt, {
      'id': 'line-1',
      'goodsId': 'goods',
      'unitId': 'piece',
      'qty': 10,
      'qtyExact': '10',
      'receivedQty': 9,
      'receivedQtyExact': '9',
      'returnedQty': 0,
      'returnedQtyExact': '0',
      'quantitySemantics': 'CHARGED_PLUS_GIFT_V1',
      'giftQty': 1,
      'giftQtyExact': '1',
      'remainingGiftQtyExact': '0',
    });
    final finder = find.byType(
      UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>,
    );
    final grid = tester
        .widget<UtenEditableGrid<UtenDocLinkItemRow<PurchaseDocItem>>>(finder);
    final row = grid.controller.rows.single;
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && identical(w.controller, row.giftQty),
      ),
      '1',
    );
    await tester.ensureVisible(find.byType(Checkbox).first);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(find.text('引入'));
    await tester.pumpAndSettle();
    expect(finder, findsOneWidget);
    expect(row.qtyError.value, '赠品量不能超过来源可用赠品量');
    expect(tester.takeException(), isNull);
  });
}
