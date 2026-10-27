import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/purchase/models/purchase_order_print_document.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_order_print_preview.dart';

Map<String, dynamic> fixture({
  int count = 3,
  bool masked = false,
  String status = '财务已通过',
}) => {
  'id': 'order',
  'billNo': 'CD20261017000001',
  'billDate': '2026-10-17',
  'deliverDate': '2026-10-31',
  'companyName': '测试电器有限公司(虚构)',
  'companyPhone': '0760-12345678',
  'supplierName': '测试金属配件供应商(虚构)',
  'supplierContact': '测试联系人',
  'supplierPhone': '13800000000',
  'deliveryPlace': '五金仓库 A区',
  'currencyName': '人民币',
  'currencyCode': 'CNY',
  'settlementMethod': '月结',
  'totalOriginal': '21300.00',
  'priceMasked': masked,
  'remark': '请按确认图纸生产，分批交货请提前联系。此单使用虚构数据，仅核验打印格式。',
  'makerName': '测试制单员',
  'reviewerName': status == '财务已通过' ? '实际财务审核员' : '',
  'statusLabel': status,
  'lines': [
    for (var i = 0; i < count; i++)
      {
        'id': 'line-$i',
        'lineNo': i + 1,
        'goodsCode': '45AZJ${1000 + i}',
        'goodsName': '大板45A开关N极支架组件 ${i + 1}',
        'model': '45A',
        'spec': '铜粒：5.1*2.3*2.3R 1/2 50C',
        'colorName': '本色',
        'unitName': '个',
        'physicalQty': i == 0 ? '21300.05' : '1000.0000',
        'chargedQty': i == 0 ? '21300' : '1000',
        'giftQty': i == 0 ? '0.05' : '0',
        'material': '紫铜1.2',
        'remark': '包工包料，按样品加工；外观不得有划伤。',
        'deliverDate': i == 1 ? '2026-11-01' : '2026-10-31',
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'paper preserves all rows, exact physical quantities, gifts and line delivery date',
    () {
      final document = PurchaseOrderPrintDocument.fromJson(fixture());
      expect(document.rows, hasLength(3));
      expect(document.rows.first[7], '21300.05');
      expect(document.rows.first.last, contains('计价 21300；赠品 0.05'));
      expect(document.rows[1].last, contains('交期 2026-11-01'));
      expect(document.capitalLabel, '人民币贰万壹仟叁佰元整');
    },
  );

  test(
    'commercial masking survives even an accidentally overfilled response',
    () {
      final document = PurchaseOrderPrintDocument.fromJson(
        fixture(masked: true),
      );
      expect(document.totalOriginal, isNull);
      expect(document.amountLabel, '***');
      expect(document.capitalLabel, '***');
      expect(document.currencyName, isEmpty);
      expect(document.settlementMethod, isEmpty);
    },
  );

  test('a pending response cannot supply a stale reviewer signature', () {
    final json = fixture(status: '等待财务审核')..['reviewerName'] = '旧审核员';
    expect(PurchaseOrderPrintDocument.fromJson(json).reviewerName, isEmpty);
  });

  testWidgets(
    'ended approved order preserves its commercial signature and can print with a visible end status',
    (tester) async {
      final json = fixture(status: '已结束(财务批准)')
        ..['financeApproved'] = true
        ..['reviewerName'] = '原商业财务审核员';
      final document = PurchaseOrderPrintDocument.fromJson(json);
      expect(document.financeApproved, isTrue);
      expect(document.reviewerName, '原商业财务审核员');
      var printed = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showPurchaseOrderPrintPreview(
                    context,
                    document,
                    loader: () async => document,
                    printer: (bytes, _) async {
                      expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
                      printed++;
                      return true;
                    },
                  ),
                  child: const Text('打开已结束采购单'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开已结束采购单'));
      await tester.pumpAndSettle();
      expect(find.text('审核：原商业财务审核员'), findsOneWidget);
      expect(find.text('单据状态：已结束(财务批准)'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('purchase-print-preview-print')));
        for (var i = 0; i < 100 && printed == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(printed, 1);
      final denied = Map<String, dynamic>.from(json)
        ..['financeApproved'] = false;
      expect(PurchaseOrderPrintDocument.fromJson(denied).reviewerName, isEmpty);
      expect(
        PurchaseOrderPrintDocument.fromJson(denied).financeApproved,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final status in ['等待财务审核', '改量待财务复核', '财务退回', '已取消', '已反审', '已审']) {
    test(
      'visible order PDF keeps current status without a stale signature: $status',
      () async {
        final document = PurchaseOrderPrintDocument.fromJson(
          fixture(status: status),
        );
        expect(document.reviewerName, isEmpty);
        expect(document.statusLabel, status);
        final bytes = await buildPurchaseOrderPdf(document);
        expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
      },
    );
  }

  test(
    'RMB capitals keep cents exact above the binary integer precision boundary',
    () {
      expect(
        purchaseOrderRmbCapital('90071992547409.91'),
        '人民币玖拾万亿零柒佰壹拾玖亿玖仟贰佰伍拾肆万柒仟肆佰零玖元玖角壹分',
      );
      expect(purchaseOrderRmbCapital('10001.05'), '人民币壹万零壹元零伍分');
      expect(purchaseOrderRmbCapital('0.00'), '人民币零元整');
      expect(purchaseOrderRmbCapital('1.0001'), '金额含分以下小数，详见小写合计');
      expect(purchaseOrderRmbCapital(null), '—');
    },
  );

  testWidgets(
    'paper remains legible at high UI text scaling and pending review has no signature',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: PurchaseOrderPrintPaper(
                    document: PurchaseOrderPrintDocument.fromJson(
                      fixture(status: '等待财务审核'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('审核：—'), findsOneWidget);
      expect(find.text('单据状态：等待财务审核'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'printing rechecks changed finance status and refreshes the paper before any output',
    (tester) async {
      var printed = 0;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showPurchaseOrderPrintPreview(
                    context,
                    PurchaseOrderPrintDocument.fromJson(fixture()),
                    loader: () async => PurchaseOrderPrintDocument.fromJson(
                      fixture(status: '等待财务审核'),
                    ),
                    printer: (_, _) async {
                      printed++;
                      return true;
                    },
                  ),
                  child: const Text('打开采购单'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开采购单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('purchase-print-preview-print')));
      await tester.pumpAndSettle();
      expect(printed, 0);
      expect(find.text('单据状态：等待财务审核'), findsOneWidget);
      expect(find.text('审核：—'), findsOneWidget);
      expect(find.text('审核：实际财务审核员'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('purchase-print-preview-print')));
        for (var i = 0; i < 100 && printed == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(printed, 1);
      expect(tester.takeException(), isNull);
    },
  );

  test('A4 supplier PDF includes every line across multiple pages', () async {
    final document = PurchaseOrderPrintDocument.fromJson(fixture(count: 75));
    final bytes = await buildPurchaseOrderPdf(document);
    expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
    expect(
      RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes)).length,
      greaterThan(1),
    );
    if (Platform.environment['UTEN_PURCHASE_PRINT_QA'] == '1') {
      await Directory('build/purchase-print-qa').create(recursive: true);
      await File('build/purchase-print-qa/multipage.pdf').writeAsBytes(bytes);
      await File('build/purchase-print-qa/supplier-order.pdf').writeAsBytes(
        await buildPurchaseOrderPdf(
          PurchaseOrderPrintDocument.fromJson(fixture()),
        ),
      );
    }
  });
}
