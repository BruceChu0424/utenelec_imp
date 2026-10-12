import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/repositories/finance_procurement_workflow_repository.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  String? path;
  Object? body;
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.body = body;
    return {};
  }
}

void main() {
  const decision = FinanceProcurementDecisionItem(
    caseId: 'case',
    expectedVersion: 3,
    expectedClaimId: 'claim',
  );
  test(
    'real API body preserves every digit of a legal twelve plus six digit rate as JSON text',
    () async {
      final api = _Api();
      final FinanceProcurementWorkflowRepository repo =
          DioFinanceProcurementWorkflowRepository(api);
      await repo.approveOrdersWithExactRate(
        [decision],
        exchangeRate: '999999999999.123456',
        remark: ' 审核 ',
      );
      expect(api.path, ApiEndpoints.financeProcurementApprovalBatchApprove);
      expect(api.body, {
        'items': [decision.toJson()],
        'remark': '审核',
        'exchangeRate': '999999999999.123456',
      });
      expect((api.body as Map)['exchangeRate'], isA<String>());
    },
  );
  test(
    'zero, negative, excess fraction and integer overflow are rejected before an API call',
    () async {
      final api = _Api();
      final FinanceProcurementWorkflowRepository repo =
          DioFinanceProcurementWorkflowRepository(api);
      for (final rate in [
        '0',
        '-1',
        '0.0000001',
        '1.1234567',
        '1000000000000',
        'NaN',
      ]) {
        await expectLater(
          repo.approveOrdersWithExactRate([decision], exchangeRate: rate),
          throwsFormatException,
        );
      }
      expect(api.path, isNull);
    },
  );
}
