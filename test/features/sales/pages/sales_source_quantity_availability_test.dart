import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_doc_link_picker_sheet.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/config/sales_doc_config.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/features/sales/widgets/sales_doc_link_picker.dart';

class _Api extends ApiClient {
  _Api(this.quantity, {this.shipment = false}) : super(Dio());
  final double? quantity;
  final bool shipment;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.endsWith('/source')
      ? {
          'id': 'source',
          'billNo': 'SOURCE-1',
          'status': 1,
          'writable': true,
          'financeConfirmed': true,
          'items': [
            {
              'id': 'line',
              'goodsId': 'goods',
              'qty': 10,
              'returnedQty': quantity,
            },
          ],
        }
      : {
          'items': [
            {
              'id': 'source',
              'billNo': 'SOURCE-1',
              'billDate': '2026-10-26',
              'status': 1,
            },
          ],
          'page': 1,
          'size': 20,
          'total': 1,
          'totalPages': 1,
        };
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [
    {
      'orderItemId': 'line',
      'goodsId': 'goods',
      'qty': 10,
      'shippableQty': quantity,
    },
  ];
}

class _Names extends SalesMasterNameService {
  _Names(super.api);
  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsNames(Iterable<String> ids) async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  Map<String, String> get clientEntries => {};
  @override
  String goods(String? id) => '来源货品';
  @override
  String unit(String? id) => '件';
}

void main() {
  for (final shipment in [false, true]) {
    for (final quantity in <double?>[null, 0, 2]) {
      testWidgets(
        'sales source preserves ${shipment ? 'shippable' : 'returned'} quantity=$quantity',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(1600, 1000));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final api = _Api(quantity, shipment: shipment);
          final upstream = shipment
              ? SalesDocType.order
              : SalesDocType.shipment;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                salesRepositoryProvider(
                  upstream,
                ).overrideWithValue(SalesRepository(api, upstream)),
                salesMasterNameServiceProvider.overrideWithValue(_Names(api)),
              ],
              child: MaterialApp(
                locale: const Locale('zh'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: Consumer(
                    builder: (context, ref, _) => ElevatedButton(
                      onPressed: () => showSalesDocLinkPicker(
                        context,
                        ref,
                        SalesDocConfig.by(
                          shipment
                              ? SalesDocType.shipment
                              : SalesDocType.returnDoc,
                        ),
                      ),
                      child: const Text('选择来源'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('选择来源'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('SOURCE-1'));
          await tester.pump(const Duration(milliseconds: 50));
          await tester.tap(find.text('SOURCE-1'));
          await tester.pumpAndSettle();
          final grid = tester
              .widget<UtenEditableGrid<UtenDocLinkItemRow<SalesDocItem>>>(
                find.byType(UtenEditableGrid<UtenDocLinkItemRow<SalesDocItem>>),
              );
          if (quantity == null) {
            expect(grid.controller.rows, isEmpty);
            expect(find.textContaining('来源数量不完整'), findsOneWidget);
            expect(find.text('该单据明细已全部完成，无剩余可引入'), findsNothing);
          } else if (shipment && quantity == 0) {
            expect(grid.controller.rows, isEmpty);
            expect(find.text('该单据明细已全部完成，无剩余可引入'), findsOneWidget);
          } else {
            expect(
              grid.controller.rows.single.qty.text,
              shipment ? '2.0' : '${10 - quantity}',
            );
            expect(find.textContaining('来源数量不完整'), findsNothing);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
