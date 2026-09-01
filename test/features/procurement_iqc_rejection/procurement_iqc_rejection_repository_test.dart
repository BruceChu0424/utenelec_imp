import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/models/procurement_iqc_rejection.dart';
import 'package:uten_imp/features/procurement_iqc_rejection/repositories/procurement_iqc_rejection_repository.dart';

void main() {
  test(
    'repository uses frozen V440 endpoints filters and command bodies',
    () async {
      final requests = <RequestOptions>[];
      final repository = ProcurementIqcRejectionRepository(_api(requests));

      final page = await repository.list(
        const ProcurementIqcRejectionFilter(
          receiptType: ProcurementIqcReceiptType.purchase,
          status: 'FINANCE_EXCEPTION',
          keyword: 'PO-001',
          page: 2,
        ),
      );
      final counts = await repository.counts(
        const ProcurementIqcRejectionFilter(
          receiptType: ProcurementIqcReceiptType.purchase,
          status: 'TERMINAL',
          keyword: 'PO-001',
        ),
      );
      final detail = await repository.detail('case-1');
      await repository.recordReturn(
        'case-1',
        const ProcurementIqcRecordReturnCommand(
          expectedVersion: 3,
          commandId: '11111111-1111-4111-8111-111111111111',
          returnReference: 'RET-001',
          returnDate: '2026-08-31',
          returnNote: '供应商签收',
        ),
      );
      await repository.confirmCredit(
        'case-1',
        const ProcurementIqcConfirmCreditCommand(
          expectedVersion: 4,
          commandId: '22222222-2222-4222-8222-222222222222',
          creditReference: 'CR-001',
          creditDate: '2026-08-31',
          reason: '红字贷项确认',
        ),
      );
      await repository.closeNoCredit(
        'case-1',
        const ProcurementIqcReasonCommand(
          expectedVersion: 4,
          commandId: '33333333-3333-4333-8333-333333333333',
          reason: '服务器冻结金额为零',
        ),
      );
      await repository.reverse(
        'case-1',
        const ProcurementIqcReasonCommand(
          expectedVersion: 5,
          commandId: '44444444-4444-4444-8444-444444444444',
          reason: '供应商凭证撤销',
        ),
      );
      await repository.retryFinanceProjection(
        'case-1',
        const ProcurementIqcReasonCommand(
          expectedVersion: 5,
          commandId: '55555555-5555-4555-8555-555555555555',
          reason: '科目配置已修复',
        ),
      );

      expect(page.items.single.id, 'case-1');
      expect(counts.financeException, 1);
      expect(detail.events.single.eventType, 'FAIL_RECORDED');

      final listRequest = requests[0];
      expect(listRequest.path, '/procurement/iqc-rejections');
      expect(listRequest.queryParameters, {
        'receiptType': 'PURCHASE',
        'status': 'FINANCE_EXCEPTION',
        'keyword': 'PO-001',
        'page': 2,
        'size': 50,
      });
      final countRequest = requests[1];
      expect(countRequest.path, '/procurement/iqc-rejections/counts');
      expect(countRequest.queryParameters, {
        'receiptType': 'PURCHASE',
        'keyword': 'PO-001',
      });

      expect(
        requests.map((request) => request.path),
        containsAllInOrder([
          '/procurement/iqc-rejections/case-1/record-return',
          '/procurement/iqc-rejections/case-1/confirm-credit',
          '/procurement/iqc-rejections/case-1/close-no-credit',
          '/procurement/iqc-rejections/case-1/reverse',
          '/procurement/iqc-rejections/case-1/retry-finance-projection',
        ]),
      );
      final recordBody = (requests[3].data as Map).cast<String, dynamic>();
      expect(recordBody['expectedVersion'], 3);
      expect(recordBody['commandId'], isNotEmpty);
      expect(recordBody['returnReference'], 'RET-001');
      expect(recordBody['returnDate'], '2026-08-31');
    },
  );
}

ApiClient _api(List<RequestOptions> requests) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        final dynamic data;
        if (request.path.endsWith('/counts')) {
          data = {
            'total': 4,
            'pendingReturn': 1,
            'returnRecorded': 1,
            'creditConfirmed': 0,
            'closedNoCredit': 0,
            'financeException': 1,
            'reversed': 1,
          };
        } else if (request.method == 'GET' &&
            request.path.endsWith('/case-1')) {
          data = _detailJson;
        } else if (request.method == 'GET') {
          data = {
            'items': [_caseJson],
            'page': 2,
            'size': 50,
            'total': 1,
            'totalPages': 1,
          };
        } else {
          data = _detailJson;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

const _caseJson = <String, dynamic>{
  'id': 'case-1',
  'receiptType': 'PURCHASE',
  'receiptBillNo': 'PR-001',
  'orderBillNo': 'PO-001',
  'supplierName': '供应商A',
  'goodsCode': 'G-001',
  'goodsName': '轴套',
  'failedQty': '5',
  'unitName': '件',
  'status': 'FINANCE_EXCEPTION',
  'version': 3,
  'allowedActions': ['RETRY_FINANCE_PROJECTION'],
  'priceMasked': true,
};

const _detailJson = <String, dynamic>{
  'caseItem': _caseJson,
  'events': [
    {'id': 'event-1', 'eventType': 'FAIL_RECORDED'},
  ],
  'replacementAllocations': <dynamic>[],
};
