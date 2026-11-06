import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_detail_summary_card.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/print/print_pdf_document.dart';
import 'package:uten_imp/features/finance/widgets/finance_actual_receipt_context.dart';
import 'package:uten_imp/features/sales/widgets/sales_shipment_print.dart';
import 'package:uten_imp/shared/models/customer_actual_receipt_context.dart';
import '../../support/print_test_font.dart';

Map<String, dynamic> paper({bool masked = false, int count = 2}) => {
  'id': 'shipment-1',
  'companyName': '测试公司',
  'title': '发货清单',
  'formCode': 'YT-FM-XS-05',
  'billNo': 'XC-ANON-001',
  'billDate': '2026-09-30',
  'clientName': '匿名客户',
  'shipAddr': '已核对送货地址',
  'phone': '',
  'currencyName': '人民币',
  'settlementName': '月结',
  'financeAuditorName': '财务原名',
  'financeAuditedAt': '2026-09-30T10:00:00+08:00',
  'quantityTotal': '20',
  'totalOriginal': '12345678901234.1234',
  'contentDigest': 'a' * 64,
  'priceMasked': masked,
  'headers': [
    '序号',
    '编号',
    '产品型号',
    '系列',
    '产品名称',
    '颜色',
    '单位',
    '数量',
    '单价',
    '折扣',
    '金额',
    '备注',
  ],
  'lines': [
    for (int i = 0; i < count; i++)
      {
        'id': 'row-$i',
        'lineNo': i + 1,
        'goodsCode': 'ANON-$i',
        'model': 'MODEL-1',
        'series': 'SERIES-A',
        'goodsName': '匿名产品（保留完整产品名称）',
        'color': '白色',
        'unit': '个',
        'qty': '10',
        'price': '0.12345678901234',
        'discount': '1',
        'amount': '1.2345678901234',
        'remark': '来源第${i + 1}行',
      },
  ],
  'signatures': [
    {'label': '仓管', 'name': ''},
    {'label': '制单员', 'name': '制单原名'},
    {'label': '审核员', 'name': '财务原名'},
    {'label': '仓库审核', 'name': ''},
    {'label': '客户签名', 'name': ''},
  ],
};

void main() {
  test(
    'twelve original columns and exact values are shared by preview/PDF; masked prices never return',
    () {
      final table = buildSalesShipmentPrintTable(paper());
      expect(table.headers, [
        '序号',
        '编号',
        '产品型号',
        '系列',
        '产品名称',
        '颜色',
        '单位',
        '数量',
        '单价',
        '折扣',
        '金额',
        '备注',
      ]);
      expect(table.rows.first, hasLength(12));
      expect(table.rows.first[8], '0.12345678901234');
      expect(table.rows.first[10], '1.2345678901234');
      expect(table.rows[2][10], '12345678901234.1234');
      expect(table.pageFooter, contains('财务原名'));
      final masked = buildSalesShipmentPrintTable(paper(masked: true));
      expect(masked.rows.first[8], '***');
      expect(masked.rows.first[9], '***');
      expect(masked.rows.first[10], '***');
      expect(masked.rows[2][10], '***');
      expect(
        masked.rows.expand((r) => r).join(' '),
        isNot(contains('12345678901234')),
      );
    },
  );
  test(
    'duplicate/partial membership and missing original signatures cannot silently print',
    () {
      final data = paper();
      ((data['lines'] as List)[1] as Map<String, dynamic>)['id'] = 'row-0';
      expect(() => buildSalesShipmentPrintTable(data), throwsFormatException);
      expect(
        () => buildSalesShipmentPrintTable({
          ...paper(),
          'signatures': <Object>[],
        }),
        throwsFormatException,
      );
      expect(
        () => buildSalesShipmentPrintTable({
          ...paper(),
          'headers': ['序号'],
        }),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'verified cash remains separate from pending proof and never claims available credit',
    (tester) async {
      final value = CustomerActualReceiptContext.fromJson({
        'available': true,
        'verifiedCount': 1,
        'verifiedCashLocal': '700.0001',
        'pendingCount': 3,
        'basis': '累计到账不等于可用预收',
        'receipts': [
          {
            'receiptId': 'r1',
            'billNo': 'R-01',
            'bankBookedAt': '2026-09-30',
            'accountCurrency': '美金',
            'accountAmount': '100.0001',
            'cashLocal': '700.0001',
          },
        ],
      });
      var reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FinanceActualReceiptContext(
                onRead: () async {
                  reads++;
                  return value;
                },
              ),
            ),
          ),
        ),
      );
      expect(reads, 0);
      expect(
        find.byKey(const ValueKey('shipment-actual-receipt-total')),
        findsNothing,
      );
      await tester.tap(find.text('客户到账参考（辅助）'));
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(
        tester
            .widget<UtenSummaryField>(
              find.byKey(const ValueKey('shipment-actual-receipt-total')),
            )
            .value,
        '700.0001 元',
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is UtenSummaryField && w.label == '待核对' && w.value == '3笔',
        ),
        findsOneWidget,
      );
      final referenceHint = find.byWidgetPredicate(
        (w) =>
            w is UtenFieldHintIcon && w.info?.contains('累计到账不等于可用预收') == true,
      );
      await tester.tap(referenceHint);
      await tester.pumpAndSettle();
      expect(find.textContaining('另有3笔'), findsOneWidget);
      expect(find.textContaining('累计到账不等于可用预收'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [1280.0, 390.0]) {
    testWidgets(
      'original paper name and finance actor remain reachable at width $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [apiClientProvider.overrideWithValue(_PrintApi())],
            child: MaterialApp(
              home: Consumer(
                builder: (context, ref, _) => Scaffold(
                  body: TextButton(
                    onPressed: () =>
                        showSalesShipmentPrint(context, ref, 'shipment-1'),
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('table-output-all')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('table-output-all')));
        await tester.pumpAndSettle();
        expect(find.textContaining('发货清单'), findsWidgets);
        expect(find.textContaining('审核员'), findsOneWidget);
        expect(find.textContaining('财务原名'), findsOneWidget);
        expect(find.text('产品型号'), findsOneWidget);
        expect(find.text('SERIES-A'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  }
  test(
    'real PDF uses the same original table and preserves 1001 complete source rows',
    () async {
      final data = paper(count: 1001);
      data['quantityTotal'] = '10010';
      data['totalOriginal'] = '1235.7345';
      for (final row in (data['lines'] as List).cast<Map<String, dynamic>>()) {
        row['price'] = '0.12345';
        row['amount'] = '1.2345';
      }
      final table = buildSalesShipmentPrintTable(data);
      final bytes = await renderPrintPdf(
        PrintPdfRequest(
          title: '${data['companyName']}\n发货清单',
          subtitle:
              '表单编号：YT-FM-XS-05\n客户名称：匿名客户　单号：XC-ANON-001\n审核员：财务原名　审核时间：2026-09-30',
          headers: table.headers,
          rows: table.rows,
          columnWidths: table.columnWidths,
          pageHeader: table.pageHeader,
          pageFooter: table.pageFooter,
          fontBytes: await loadPrintTestFontBytes(),
        ),
      );
      expect(bytes.take(5), '%PDF-'.codeUnits);
      expect(table.rows, hasLength(1002));
      if (Platform.environment['UTEN_FINANCE_PDF_EVIDENCE'] == 'true') {
        final directory = Directory('output/pdf/finance-applications');
        await directory.create(recursive: true);
        await File(
          '${directory.path}/发货清单-原表12列-1001行.pdf',
        ).writeAsBytes(bytes);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _PrintApi extends ApiClient {
  _PrintApi() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => paper();
}
