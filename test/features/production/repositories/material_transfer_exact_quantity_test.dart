import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/material_transfer_quantity.dart';
import 'package:uten_imp/features/production/models/material_future_transfer.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

void main() {
  for (final text in [
    '0.0001',
    '1.2345',
    '99999999999999.9999',
    '90071992547409.0001',
  ]) {
    test(
      'all transfer commands preserve $text and both CAS identities',
      () async {
        final requests = <RequestOptions>[];
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              requests.add(request);
              handler.resolve(
                Response(
                  requestOptions: request,
                  data: {'analysisId': 'a', 'version': 4, 'fingerprint': 'f'},
                ),
              );
            },
          ),
        );
        final repository = ProductionPlanRepository(ApiClient(dio));
        const analysis = ProductionMaterialAnalysisView(
          analysisId: 'a',
          version: 4,
          fingerprint: 'a-cas',
        );
        const target = MaterialCrossReallocationCandidate(
          targetAnalysisId: 'b',
          targetVersion: 7,
          targetFingerprint: 'b-cas',
          targetMaterialLineId: 'bm',
        );
        const donor = MaterialCrossReallocationSourceCandidate(
          sourceAnalysisId: 'b',
          sourceVersion: 7,
          sourceFingerprint: 'b-cas',
          sourceMaterialLineId: 'bm',
        );
        const future = MaterialFutureTransferSource(
          sourceAllocationId: 'allocation',
          sourceAnalysisId: 'b',
          sourceMaterialId: 'bm',
          sourceLabel: 'B',
          availableQty: 1,
          receivedQty: 0,
          sourceVersion: 7,
          sourceFingerprint: 'b-cas',
          targetVersion: 4,
          targetFingerprint: 'a-cas',
          targetUncoveredQty: 1,
        );
        final record = MaterialFutureTransferRecord.fromJson({
          'id': 't',
          'sourceAllocationId': 'allocation',
          'sourceAnalysisId': 'b',
          'sourceMaterialId': 'bm',
          'targetAnalysisId': 'a',
          'targetMaterialId': 'am',
          'qty': 1,
          'status': 'WAITING_RECEIPT',
          'sourceVersion': 7,
          'sourceFingerprint': 'b-cas',
          'targetVersion': 4,
          'targetFingerprint': 'a-cas',
        });
        await repository.createMaterialAnalysisBorrow(
          analysis: analysis,
          idempotencyKey: 'key-borrow',
          fromMaterialLineId: 'am',
          toMaterialLineId: 'am2',
          qty: text,
          reason: 'exact',
        );
        await repository.createMaterialCrossReallocation(
          sourceAnalysis: analysis,
          target: target,
          sourceMaterialLineId: 'am',
          qty: text,
          reason: 'exact',
          idempotencyKey: 'key-cross',
        );
        await repository.acceptMaterialCrossReallocation(
          targetAnalysis: analysis,
          targetMaterialLineId: 'am',
          source: donor,
          qty: text,
          reason: 'exact',
          idempotencyKey: 'key-receive',
        );
        await repository.createMaterialFutureTransfer(
          targetAnalysis: analysis,
          targetMaterialId: 'am',
          source: future,
          qty: text,
          allowLateSupply: true,
          reason: 'exact',
          idempotencyKey: 'key-future',
        );
        await repository.cancelMaterialFutureTransfer(
          analysisId: 'a',
          transfer: record,
          qty: text,
          reason: 'exact',
          idempotencyKey: 'key-cancel',
        );
        for (final request in requests) {
          final body = request.data as Map<String, dynamic>;
          expect(body['qty'].toString(), text);
        }
        Map<String, dynamic> body(int index) =>
            requests[index].data as Map<String, dynamic>;
        expect(body(1)['sourceVersion'], 4);
        expect(body(1)['targetVersion'], 7);
        expect(body(2)['sourceFingerprint'], 'b-cas');
        expect(body(2)['targetFingerprint'], 'a-cas');
        expect(body(4)['sourceVersion'], 7);
        expect(body(4)['targetVersion'], 4);
      },
    );
  }
  test('invalid, over-scale and already rounded large values fail closed', () {
    for (final value in <Object>[
      'NaN',
      'Infinity',
      '0',
      '-1',
      '1.00001',
      '100000000000000',
      double.nan,
      double.infinity,
      99999999999999.9999,
    ]) {
      expect(
        () => materialTransferWire(value),
        throwsFormatException,
        reason: '$value',
      );
    }
    expect(
      materialTransferUnits('99999999999999.9999'),
      BigInt.parse('999999999999999999'),
    );
  });
  test(
    'future capacity retains exact facts instead of reconstructing large doubles',
    () {
      final record = MaterialFutureTransferRecord.fromJson({
        'id': 't',
        'sourceAllocationId': 'allocation',
        'sourceAnalysisId': 'b',
        'sourceMaterialId': 'bm',
        'targetAnalysisId': 'a',
        'targetMaterialId': 'am',
        'qty': 100000000000000.0,
        'remainingQty': 100000000000000.0,
        'status': 'WAITING_RECEIPT',
        'sourceVersion': 7,
        'sourceFingerprint': 'b-cas',
        'targetVersion': 4,
        'targetFingerprint': 'a-cas',
        'quantityFactsExact': {
          'remainingQty': '99999999999999.9999',
          'cancelRestoreToSourceQty': '99999999999999.9999',
        },
      });
      expect(record.maxCancelableUnits, BigInt.parse('999999999999999999'));
      expect(record.maxRestoreUnits, record.maxCancelableUnits);
    },
  );
}
