import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/repositories/procurement_inspection_repository.dart';

void main() {
  test('batch pass posts one receipt-scoped atomic request', () async {
    final api = _RecordingApi();
    final repository = DioProcurementInspectionRepository(api);

    await repository.passBatch(
      receiptType: 'PURCHASE',
      receiptId: 'receipt-1',
      items: const [
        ProcurementInspectionBatchPassItem(
          inspectionItemId: 'inspection-1',
          expectedRemainingBaseQty: 5,
          idempotencyKey: 'iqc-batch-item-0001',
        ),
        ProcurementInspectionBatchPassItem(
          inspectionItemId: 'inspection-2',
          expectedRemainingBaseQty: 3.5,
          idempotencyKey: 'iqc-batch-item-0002',
        ),
      ],
      reason: '  常规来料检验合格  ',
    );

    expect(api.path, '/procurement/inspection/PURCHASE/receipt-1/pass-batch');
    expect(api.body?['reason'], '常规来料检验合格');
    final items = api.body?['items'] as List<dynamic>;
    expect(items, hasLength(2));
    expect(items.first, {
      'inspectionItemId': 'inspection-1',
      'expectedRemainingBaseQty': 5.0,
      'idempotencyKey': 'iqc-batch-item-0001',
    });
  });
}

class _RecordingApi extends ApiClient {
  _RecordingApi() : super(Dio());

  String? path;
  Map<String, dynamic>? body;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.body = Map<String, dynamic>.from(body! as Map);
    return const {};
  }
}
