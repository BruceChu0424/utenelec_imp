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
    'definite rejection still retains the exact command for every receipt',
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
      // 2026-09-18 并行通道：失败不再连坐取消其它单，两张单各重试一次；
      // 收货单未全部确认前 FQC 一张都不发。
      expect(api.requests.length, 4);
      for (final id in ['receipt-1', 'receipt-2']) {
        final attempts = api.requests
            .where((request) => request.$1.contains(id))
            .toList();
        expect(attempts.length, 2);
        expect(attempts[0].$1, attempts[1].$1);
        expect(attempts[0].$2, attempts[1].$2);
      }
    },
  );

  test(
    'receipts submit on at most four concurrent lanes in one pass',
    () async {
      var active = 0;
      var peak = 0;
      var held = 0;
      final gates = <Completer<Map<String, dynamic>>>[];
      final api = _Api((path, body) {
        active++;
        if (active > peak) peak = active;
        void release() => active--;
        if (held < 4) {
          held++;
          final gate = Completer<Map<String, dynamic>>();
          gates.add(gate);
          return gate.future.whenComplete(release);
        }
        return Future<Map<String, dynamic>>.value({
          'processedCount': 1,
        }).whenComplete(release);
      });
      final report = QualityBatchSubmission(
        receipts: [
          for (var i = 1; i <= 6; i++)
            QualityReceiptSubmission(
              receiptType: 'PURCHASE',
              receiptId: 'receipt-$i',
              label: 'R$i',
              items: [_item('inspection-$i')],
            ),
        ],
        fqcInspectionIds: const [],
        reason: null,
      );
      final iqc = DioProcurementInspectionRepository(api);
      final fqc = ProductionFqcRepository(api);
      final running = report.send(iqc: iqc, fqc: fqc);
      await Future<void>.delayed(Duration.zero);
      expect(gates.length, 4, reason: '首波在飞的只有 4 条通道');
      expect(peak, 4);
      for (final gate in gates) {
        gate.complete({'processedCount': 1});
      }
      await running;
      expect(report.completedReceiptCount, 6);
      expect(report.complete, isTrue);
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
