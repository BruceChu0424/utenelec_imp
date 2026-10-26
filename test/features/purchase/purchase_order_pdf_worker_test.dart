import 'dart:async';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/print/isolated_print_pdf.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/features/purchase/models/purchase_order_pdf_bundle.dart';

Map<String, dynamic> _paper(int id, {int lines = 1}) => {
  'id': 'order-$id',
  'contentDigest': 'a' * 64,
  'billNo': 'CD-000$id',
  'companyName': '优腾合成验证',
  'supplierName': '合成供应商',
  'financeApproved': true,
  'statusLabel': '财务已通过',
  'currencyCode': 'CNY',
  'currencyName': '人民币',
  'totalOriginal': '123.450000000000000001',
  'lines': [
    for (var i = 0; i < lines; i++)
      {
        'id': '$id-$i',
        'goodsCode': '000${i + 1}',
        'goodsName': '原始材料龘 $i',
        'physicalQty': '1.000000000000000001',
        'chargedQty': '1.000000000000000001',
        'giftQty': '0',
        'unitName': '个',
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'worker input copies exact decimal strings, yields, and retires an ABA generation',
    () async {
      var current = true;
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        ticks++;
      });
      final encoded = await encodePurchaseOrderBundleInput([
        _paper(1, lines: 10001),
      ], stillCurrent: () => current);
      timer.cancel();
      final decoded = jsonDecode(encoded.payload) as List;
      expect(
        (decoded.single as Map)['totalOriginal'],
        '123.450000000000000001',
      );
      expect(encoded.bytes, utf8.encode(encoded.payload).length);
      expect(ticks, greaterThan(0));
      final old = encodePurchaseOrderBundleInput([
        _paper(1, lines: 10001),
      ], stillCurrent: () => current);
      current = false;
      await expectLater(old, throwsA(isA<UiWorkCancelled>()));
      current = true;
      expect(
        await encodePurchaseOrderBundleInput([
          _paper(1),
        ], stillCurrent: () => current),
        isNotNull,
      );
    },
  );
  test(
    'source and ZIP budgets refuse before retained output exceeds the boundary',
    () async {
      await expectLater(
        encodePurchaseOrderBundleInput([
          {'remark': 'x' * (PurchaseOrderExportLimits.sourceBytes + 1)},
        ], stillCurrent: () => true),
        throwsStateError,
      );
      await expectLater(
        encodePurchaseOrderBundleInput(
          List.generate(101, _paper),
          stillCurrent: () => true,
        ),
        throwsStateError,
      );
      final out = PurchaseOrderZipOutput(8);
      out.writeBytes(List.filled(8, 1));
      expect(out.length, 8);
      expect(() => out.writeByte(1), throwsA(anything));
      expect(out.length, 8);
      expect(
        () => out.writeStream(InputMemoryStream(Uint8List(1))),
        throwsA(anything),
      );
      expect(out.length, 8);
      expect(
        () => PurchaseOrderBundleResult.decode(Uint8List(2)),
        throwsFormatException,
      );
    },
  );
  test(
    'one real isolate renders original purchase PDFs and ZIP with a single font parse operation',
    () async {
      final font = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
      var started = 0;
      var ticks = 0;
      final worker = IsolatedPrintPdfGenerator(
        debugOnIsolateStarted: (_) {
          started++;
        },
      );
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        ticks++;
      });
      final watch = Stopwatch()..start();
      try {
        final packet = await worker.generate(
          PrintPdfRequest.binary(
            kind: 'purchase-order-bundle',
            payload: jsonEncode([_paper(1, lines: 601), _paper(2, lines: 20)]),
            renderer: renderPurchaseOrderBundle,
            fontBytes: font.buffer.asUint8List(
              font.offsetInBytes,
              font.lengthInBytes,
            ),
          ),
        );
        final result = PurchaseOrderBundleResult.decode(packet);
        expect(started, 1);
        expect(ticks, greaterThan(5));
        expect(result.failed, isEmpty);
        expect(result.successful.map((e) => e['id']), ['order-1', 'order-2']);
        expect(
          result.successful.every((e) => e['contentDigest'] == 'a' * 64),
          isTrue,
        );
        final entries = ZipDecoder().decodeBytes(result.bytes).files;
        expect(entries.map((e) => e.name), [
          '采购单-CD-0001.pdf',
          '采购单-CD-0002.pdf',
        ]);
        for (final entry in entries) {
          expect(String.fromCharCodes(entry.content.take(5)), '%PDF-');
        }
        // Non-quiet targeted observation, not a platform p95/p99 benchmark.
        // ignore: avoid_print
        print(
          'purchase worker docs=2 lines=621 bytes=${result.bytes.length} elapsedMs=${watch.elapsedMilliseconds} uiTicks=$ticks isolates=$started',
        );
      } finally {
        timer.cancel();
        worker.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'disposing a native bundle generator retires its worker without a result',
    () async {
      final worker = IsolatedPrintPdfGenerator();
      final future = worker.generate(
        PrintPdfRequest.binary(
          kind: 'purchase-order-bundle',
          payload: jsonEncode([_paper(1, lines: 10001)]),
          renderer: renderPurchaseOrderBundle,
        ),
      );
      final assertion = expectLater(future, throwsA(isA<UiWorkCancelled>()));
      worker.dispose();
      await assertion;
    },
  );
}
