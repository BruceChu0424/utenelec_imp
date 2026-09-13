import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/quality/repositories/production_fqc_repository.dart';
import 'package:uten_imp/features/quality/services/quality_batch_submission.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';

void main() {
  test(
    'partial acknowledgement skips completed receipt and reuses exact unknown command',
    () async {
      var secondAttempts = 0;
      final api = _Api((path, body) async {
        if (path.contains('receipt-2') && secondAttempts++ == 0) {
          throw NetworkTimeoutException();
        }
        return {'processedCount': 2};
      });
      final mutableItems = [_item('inspection-1')];
      final mutableReceipts = [
        QualityReceiptSubmission(
          receiptType: 'PURCHASE',
          receiptId: 'receipt-1',
          label: 'R1',
          items: mutableItems,
        ),
        QualityReceiptSubmission(
          receiptType: 'SUBCONTRACT',
          receiptId: 'receipt-2',
          label: 'R2',
          items: [_item('inspection-2')],
        ),
      ];
      final report = QualityBatchSubmission(
        receipts: mutableReceipts,
        fqcInspectionIds: ['fqc-1', 'fqc-2'],
        reason: '按原报告确认少量不合格',
      );
      mutableItems.clear();
      mutableReceipts.clear();
      expect(() => report.receipts.clear(), throwsUnsupportedError);
      expect(() => report.receipts.first.items.clear(), throwsUnsupportedError);
      final iqc = DioProcurementInspectionRepository(api);
      final fqc = ProductionFqcRepository(api);
      await expectLater(
        report.send(iqc: iqc, fqc: fqc),
        throwsA(isA<NetworkTimeoutException>()),
      );
      expect(report.completedReceiptCount, 1);
      expect(report.remainingReceiptCount, 1);
      expect(report.acknowledgedIqcIds, ['inspection-1']);
      expect(report.currentLabel, 'R2');
      expect(report.complete, isFalse);
      final unknownBody = api.requests[1].$2;
      await report.send(iqc: iqc, fqc: fqc);
      expect(api.requests.length, 4);
      expect(
        api.requests
            .map((request) => request.$1)
            .where((path) => path.contains('receipt-1'))
            .length,
        1,
      );
      expect(api.requests[2].$2, unknownBody);
      expect(api.requests[2].$2['reason'], '按原报告确认少量不合格');
      expect(report.complete, isTrue);
      expect(report.acknowledgedIqcIds, ['inspection-1', 'inspection-2']);
      await report.send(iqc: iqc, fqc: fqc);
      expect(
        api.requests.length,
        4,
        reason: 'An acknowledged report has no remaining command',
      );
    },
  );

  test(
    'FQC response loss reuses the original whole-batch key and ids',
    () async {
      var attempt = 0;
      final api = _Api((path, body) async {
        if (attempt++ == 0) throw NetworkException('响应丢失');
        return {'processedCount': 2, 'replay': true};
      });
      final originalIds = ['fqc-2', 'fqc-1', 'fqc-2'];
      final report = QualityBatchSubmission(
        receipts: [],
        fqcInspectionIds: originalIds,
        reason: null,
      );
      originalIds.clear();
      final iqc = DioProcurementInspectionRepository(api);
      final fqc = ProductionFqcRepository(api);
      await expectLater(
        report.send(iqc: iqc, fqc: fqc),
        throwsA(isA<NetworkException>()),
      );
      expect(report.complete, isFalse);
      await report.send(iqc: iqc, fqc: fqc);
      expect(api.requests[0].$1, api.requests[1].$1);
      expect(api.requests[0].$2, api.requests[1].$2);
      expect(api.requests[1].$2['inspectionIds'], ['fqc-2', 'fqc-1']);
      expect(report.complete, isTrue);
      expect(() => report.fqcInspectionIds.clear(), throwsUnsupportedError);
    },
  );

  test('a concurrent second click cannot dispatch the report twice', () async {
    final gate = Completer<Map<String, dynamic>>();
    final api = _Api((path, body) => gate.future);
    final report = QualityBatchSubmission(
      receipts: [],
      fqcInspectionIds: ['fqc-1'],
      reason: null,
    );
    final iqc = DioProcurementInspectionRepository(api);
    final fqc = ProductionFqcRepository(api);
    final running = report.send(iqc: iqc, fqc: fqc);
    await expectLater(report.send(iqc: iqc, fqc: fqc), throwsStateError);
    expect(api.requests.length, 1);
    gate.complete({'processedCount': 1});
    await running;
    expect(report.complete, isTrue);
  });

  test(
    'definite rejection still retains the exact command and never reaches later receipts',
    () async {
      final api = _Api(
        (path, body) async => throw ApiException('CONFLICT', '待检量已变化'),
      );
      final report = QualityBatchSubmission(
        receipts: [
          QualityReceiptSubmission(
            receiptType: 'PURCHASE',
            receiptId: 'receipt-1',
            label: 'R1',
            items: [_item('inspection-1')],
          ),
          QualityReceiptSubmission(
            receiptType: 'PURCHASE',
            receiptId: 'receipt-2',
            label: 'R2',
            items: [_item('inspection-2')],
          ),
        ],
        fqcInspectionIds: ['fqc-1'],
        reason: null,
      );
      final iqc = DioProcurementInspectionRepository(api);
      final fqc = ProductionFqcRepository(api);
      for (var i = 0; i < 2; i++) {
        await expectLater(
          report.send(iqc: iqc, fqc: fqc),
          throwsA(isA<ApiException>()),
        );
      }
      expect(report.completedReceiptCount, 0);
      expect(api.requests.length, 2);
      expect(api.requests[0].$1, api.requests[1].$1);
      expect(api.requests[0].$2, api.requests[1].$2);
    },
  );
}

ProcurementInspectionDecideItem _item(String id) =>
    ProcurementInspectionDecideItem(
      inspectionItemId: id,
      expectedRemainingBaseQty: 10.0001,
      passBaseQty: 8.0001,
      failBaseQty: 2,
      idempotencyKey: 'frozen-report-$id',
    );

class _Api extends ApiClient {
  _Api(this.respond) : super(Dio());
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  respond;
  final requests = <(String, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) {
    final captured = (jsonDecode(jsonEncode(body)) as Map)
        .cast<String, dynamic>();
    requests.add((path, captured));
    return respond(path, captured);
  }
}
