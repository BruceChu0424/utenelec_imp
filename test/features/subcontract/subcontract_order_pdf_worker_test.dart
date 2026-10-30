import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/print/isolated_print_pdf.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_order_pdf_bundle.dart';
import 'package:uten_imp/shared/export/order_document_bundle.dart';
import 'package:uten_imp/shared/print/procurement_order_print_document.dart';

Map<String, dynamic> _order(int index) => {
  'id': 'order-$index',
  'billNo': 'WD-000$index',
  'contentDigest': 'a' * 64,
  'companyName': '优腾合成验证',
  'supplierName': '委外验证供应商',
  'financeApproved': false,
  'statusLabel': '等待财务审核',
  'reviewerName': '不应显示的旧审核员',
  'totalOriginal': '123.450000000000000001',
  'currencyName': '人民币',
  'currencyCode': 'CNY',
  'lines': [
    {
      'id': 'line-$index',
      'goodsCode': '0001',
      'goodsName': '委外加工件',
      'physicalQty': '1.000000000000000001',
      'chargedQty': '1.000000000000000001',
      'giftQty': null,
      'unitName': '个',
    },
  ],
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'subcontract keeps exact physical quantity and does not invent gift semantics',
    () {
      final document = ProcurementOrderPrintDocument.fromJson(_order(1));
      expect(document.rows.single[7], '1.000000000000000001');
      expect(document.rows.single.last, '—');
      expect(document.reviewerName, isEmpty);
      expect(document.totalOriginal, '123.450000000000000001');
    },
  );
  test(
    'subcontract print carries direct materials and their product linkage',
    () async {
      final order = _order(3)
        ..['materials'] = [
          {
            'orderItemId': 'line-3',
            'orderLineNo': 1,
            'goodsCode': 'M-SHELL',
            'goodsName': '外壳',
            'colorName': '黑',
            'unitName': '个',
            'bomUnitQty': '2',
            'requiredQty': '20.0000',
          },
        ];
      final document = ProcurementOrderPrintDocument.fromJson(order);
      // 物料表行: 单耗/需发量去尾随零, 所属成品指回成品行号(对应关系)。
      expect(document.materialRows.single,
          ['1', 'M-SHELL', '外壳', '黑', '个', '2', '20', '第 1 行']);
      // 快照签名覆盖物料内容(服务端内容摘要变化时预览会提示刷新)。
      final without = ProcurementOrderPrintDocument.fromJson(
        _order(3)..['materials'] = <Map<String, dynamic>>[],
      );
      expect(document.signature, isNot(without.signature));
      final font = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
      final worker = IsolatedPrintPdfGenerator();
      try {
        final packet = await worker.generate(
          PrintPdfRequest.binary(
            kind: 'subcontract-order-bundle',
            payload: jsonEncode([order]),
            renderer: renderSubcontractOrderBundle,
            fontBytes: font.buffer.asUint8List(font.offsetInBytes, font.lengthInBytes),
          ),
        );
        final single = OrderDocumentBundleResult.decode(packet);
        expect(single.filename, '委外订货单-WD-0003.pdf');
        expect(String.fromCharCodes(single.bytes.take(5)), '%PDF-');
      } finally {
        worker.dispose();
      }
    },
  );
  test(
    'real isolate renders pending subcontract orders as a named ZIP with exact proofs',
    () async {
      final font = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
      final worker = IsolatedPrintPdfGenerator();
      try {
        final result = OrderDocumentBundleResult.decode(
          await worker.generate(
            PrintPdfRequest.binary(
              kind: 'subcontract-order-bundle',
              payload: jsonEncode([_order(1), _order(2)]),
              renderer: renderSubcontractOrderBundle,
              fontBytes: font.buffer.asUint8List(
                font.offsetInBytes,
                font.lengthInBytes,
              ),
            ),
          ),
        );
        expect(result.filename, '委外订货单批量导出(2份).zip');
        expect(result.failed, isEmpty);
        expect(result.successful.map((value) => value['contentDigest']), [
          'a' * 64,
          'a' * 64,
        ]);
        final entries = ZipDecoder().decodeBytes(result.bytes).files;
        expect(entries.map((entry) => entry.name), [
          '委外订货单-WD-0001.pdf',
          '委外订货单-WD-0002.pdf',
        ]);
        for (final entry in entries) {
          expect(String.fromCharCodes(entry.content.take(5)), '%PDF-');
        }
      } finally {
        worker.dispose();
      }
    },
  );

  for (final kind in ProcurementOrderPrintKind.values) {
    test(
      '${kind.name} filenames never overwrite a prior suffix collision',
      () async {
        final font = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
        final first = _order(1)..['billNo'] = 'same-order-3';
        final second = _order(2)..['billNo'] = 'same';
        final third = _order(3)..['billNo'] = 'same';
        final result = OrderDocumentBundleResult.decode(
          await renderOrderBundle(
            jsonEncode([first, second, third]),
            font.buffer.asUint8List(font.offsetInBytes, font.lengthInBytes),
            kind: kind,
          ),
        );
        final entries = ZipDecoder().decodeBytes(result.bytes).files;
        expect(result.successful, hasLength(3));
        expect(entries, hasLength(3));
        expect(entries.map((entry) => entry.name), [
          '${kind.label}-same-order-3.pdf',
          '${kind.label}-same.pdf',
          '${kind.label}-same-order-3-2.pdf',
        ]);
      },
    );
  }
}
