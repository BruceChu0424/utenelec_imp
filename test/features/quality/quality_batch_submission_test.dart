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
    'response loss keeps the whole report retryable with the exact frozen body',
    () async {
      // 2026-10-10 整份检验报告一次提交：decide-report 单事务原子执行全部收货单，
      // 响应丢失后整份报告保持未确认，重试发同一个报告体（服务端重放已提交的单）。
      var attempts = 0;
      final api = _Api((path, body) async {
        if (path == '/procurement/inspection/decide-report' &&
            attempts++ == 0) {
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
      var report = QualityBatchSubmission(
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
        report.send(
          iqc: iqc,
          fqc: fqc,
          requestScope: await api.captureRequestScope(isCurrent: () => true),
        ),
        throwsA(isA<NetworkTimeoutException>()),
      );
      expect(report.completedReceiptCount, 0);
      expect(report.complete, isFalse);
      final originalFqcKey = report.fqcIdempotencyKey;
      // Process restart must retain the frozen request keys.
      report = QualityBatchSubmission.fromDraft(
        jsonDecode(jsonEncode(report.exportDraft())) as Map<String, dynamic>,
      );
      expect(report.completedReceiptCount, 0);
      expect(report.fqcIdempotencyKey, originalFqcKey);
      await report.send(
        iqc: iqc,
        fqc: fqc,
        requestScope: await api.captureRequestScope(isCurrent: () => true),
      );
      // 失败的整份报告请求 + 重试成功的整份报告请求 + 一次 FQC pass-all。
      expect(api.requests.length, 3);
      expect(api.requests[0].$1, '/procurement/inspection/decide-report');
      expect(api.requests[1].$1, '/procurement/inspection/decide-report');
      expect(api.requests[2].$1, contains('pass-all'));
      expect(api.requests[0].$2, api.requests[1].$2,
          reason: '重试发同一个整份报告体');
      final body = api.requests[0].$2;
      expect(body['reason'], '按原报告确认少量不合格');
      final receipts = (body['receipts'] as List).cast<Map<String, dynamic>>();
      expect(receipts, hasLength(2));
      expect(receipts[0]['receiptType'], 'PURCHASE');
      expect(receipts[0]['receiptId'], 'receipt-1');
      expect(receipts[1]['receiptType'], 'SUBCONTRACT');
      expect(receipts[1]['receiptId'], 'receipt-2');
      expect(report.complete, isTrue);
      expect(report.acknowledgedIqcIds, ['inspection-1', 'inspection-2']);
      await report.send(
        iqc: iqc,
        fqc: fqc,
        requestScope: await api.captureRequestScope(isCurrent: () => true),
      );
      expect(
        api.requests.length,
        3,
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
        report.send(
          iqc: iqc,
          fqc: fqc,
          requestScope: await api.captureRequestScope(isCurrent: () => true),
        ),
        throwsA(isA<NetworkException>()),
      );
      expect(report.complete, isFalse);
      await report.send(
        iqc: iqc,
        fqc: fqc,
        requestScope: await api.captureRequestScope(isCurrent: () => true),
      );
      expect(api.requests[0].$1, api.requests[1].$1);
      expect(api.requests[0].$2, api.requests[1].$2);
      expect(api.requests[1].$2['inspectionIds'], ['fqc-2', 'fqc-1']);
      expect(report.complete, isTrue);
      expect(() => report.fqcInspectionIds.clear(), throwsUnsupportedError);
    },
  );

  test(
    'a legacy partially-acknowledged draft resends the whole report atomically',
    () async {
      // 旧版(逐单 decide-batch)草稿可能带部分确认集：新 send 不再逐单补发，
      // 整份报告一次重发——服务端对已提交的单静默重放（见服务端
      // legacyPerReceiptCommitReplaysInsideTheWholeReport 契约测试）。
      final api = _Api((path, body) async => {'receiptCount': 2});
      final report = QualityBatchSubmission.fromDraft({
        'receipts': [
          {
            'receiptType': 'PURCHASE',
            'receiptId': 'receipt-1',
            'label': 'R1',
            'items': [
              _item('inspection-1').toJson(),
            ],
          },
          {
            'receiptType': 'PURCHASE',
            'receiptId': 'receipt-2',
            'label': 'R2',
            'items': [_item('inspection-2').toJson()],
          },
        ],
        'fqcInspectionIds': <String>[],
        'fqcLotCount': 0,
        'reason': null,
        'fqcIdempotencyKey': 'legacy-fqc-key',
        'acknowledged': [0],
        'fqcAcknowledged': false,
      });
      expect(report.completedReceiptCount, 1, reason: '旧草稿恢复出部分确认');
      await report.send(
        iqc: DioProcurementInspectionRepository(api),
        fqc: ProductionFqcRepository(api),
        requestScope: await api.captureRequestScope(isCurrent: () => true),
      );
      expect(api.requests, hasLength(1));
      expect(api.requests.single.$1, '/procurement/inspection/decide-report');
      final receipts = (api.requests.single.$2['receipts'] as List)
          .cast<Map<String, dynamic>>();
      expect(receipts, hasLength(2), reason: '两张单一并重发，服务端逐单重放/执行');
      expect(report.complete, isTrue);
      expect(report.acknowledgedIqcIds, ['inspection-1', 'inspection-2']);
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
    final running = report.send(
      iqc: iqc,
      fqc: fqc,
      requestScope: await api.captureRequestScope(isCurrent: () => true),
    );
    await expectLater(
      report.send(
        iqc: iqc,
        fqc: fqc,
        requestScope: await api.captureRequestScope(isCurrent: () => true),
      ),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);
    expect(api.requests.length, 1);
    gate.complete({'processedCount': 1});
    await running;
    expect(report.complete, isTrue);
  });

  test(
    'definite rejection keeps the exact report body for the retry',
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
          report.send(
            iqc: iqc,
            fqc: fqc,
            requestScope: await api.captureRequestScope(isCurrent: () => true),
          ),
          throwsA(isA<ApiException>()),
        );
      }
      expect(report.completedReceiptCount, 0);
      // 整批原子提交：每次尝试只发一个 decide-report；IQC 未确认前 FQC 一张都不发。
      expect(api.requests.length, 2);
      expect(
        api.requests.map((request) => request.$1).toSet(),
        {'/procurement/inspection/decide-report'},
      );
      expect(api.requests[0].$2, api.requests[1].$2);
      expect((api.requests[0].$2['receipts'] as List), hasLength(2));
    },
  );

  test('all receipts go to the server in one atomic report request', () async {
    // 2026-10-10：不再逐单串行发 decide-batch——整份报告一个请求，服务端原子执行。
    final gates = <Completer<Map<String, dynamic>>>[];
    final paths = <String>[];
    final api = _Api((path, body) {
      paths.add(path);
      final gate = Completer<Map<String, dynamic>>();
      gates.add(gate);
      return gate.future;
    });
    final report = QualityBatchSubmission(
      receipts: [
        for (var i = 1; i <= 4; i++)
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
    final running = report.send(
      iqc: iqc,
      fqc: fqc,
      requestScope: await api.captureRequestScope(isCurrent: () => true),
    );
    await Future<void>.delayed(Duration.zero);
    expect(gates, hasLength(1), reason: '四张收货单只发一个请求');
    expect(paths.single, '/procurement/inspection/decide-report');
    final receipts = (api.requests.single.$2['receipts'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      receipts.map((receipt) => receipt['receiptId']),
      ['receipt-1', 'receipt-2', 'receipt-3', 'receipt-4'],
      reason: '报告顺序原样进入请求体',
    );
    expect(report.completedReceiptCount, 0, reason: '响应未回不确认');
    gates.single.complete({'receiptCount': 4});
    await running;
    expect(report.completedReceiptCount, 4);
    expect(report.complete, isTrue);
  });
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
