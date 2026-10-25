import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/finance/models/finance_procurement_workflow.dart';
import 'package:uten_imp/features/finance/repositories/finance_procurement_workflow_repository.dart';

void main() {
  for (final type in [
    FinanceProcurementOrderType.purchase,
    FinanceProcurementOrderType.subcontract,
  ]) {
    test(
      '${type.name} closure list, bill facets and counts carry the same server status',
      () async {
        final calls = <RequestOptions>[];
        final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              calls.add(request);
              final response =
                  request.path == ApiEndpoints.financeProcurementApprovalFacets
                  ? {
                      'billNo': [
                        {'value': 'ORDER-CLOSE', 'count': 1},
                      ],
                    }
                  : request.path ==
                        ApiEndpoints.financeProcurementApprovalTypeCounts
                  ? {type.name.toUpperCase(): 1}
                  : {
                      'items': [
                        {
                          'caseId': 'closure-1',
                          'orderId': 'order-1',
                          'orderType': type.name.toUpperCase(),
                          'billNo': 'ORDER-CLOSE',
                          'requestType': 'CLOSE_AND_REORDER',
                          'status': 'PENDING',
                          'version': 3,
                          'allowedActions': ['APPROVE', 'REJECT'],
                        },
                      ],
                      'page': 1,
                      'size': 20,
                      'total': 1,
                      'totalPages': 1,
                    };
              handler.resolve(
                Response<dynamic>(
                  requestOptions: request,
                  statusCode: 200,
                  data: response,
                ),
              );
            },
          ),
        );
        final repo = DioFinanceProcurementWorkflowRepository(ApiClient(dio));
        final page = await repo.approvalTasks(
          orderType: type,
          status: 'CLOSURE_PENDING',
          keyword: '  停止供货  ',
          billNo: 'ORDER-CLOSE',
        );
        final facets = await repo.approvalBillNoFacets(
          orderType: type,
          status: 'CLOSURE_PENDING',
          keyword: '  停止供货  ',
        );
        final counts = await repo.approvalTypeCounts(status: 'CLOSURE_PENDING');
        expect(page.items.single.isClosureRequest, isTrue);
        expect(page.items.single.allowedActions, {'APPROVE', 'REJECT'});
        expect(facets.single.value, page.items.single.billNo);
        expect(counts[type.name.toUpperCase()], page.total);
        expect(calls.map((request) => request.path), [
          ApiEndpoints.financeProcurementApprovalTasks,
          ApiEndpoints.financeProcurementApprovalFacets,
          ApiEndpoints.financeProcurementApprovalTypeCounts,
        ]);
        expect(
          calls.map((request) => request.queryParameters['status']),
          everyElement('CLOSURE_PENDING'),
        );
        expect(
          calls.take(2).map((request) => request.queryParameters['orderType']),
          everyElement(type.name.toUpperCase()),
        );
        expect(
          calls.take(2).map((request) => request.queryParameters['keyword']),
          everyElement('停止供货'),
        );
        expect(
          calls[1].queryParameters.containsKey('billNo'),
          isFalse,
          reason: 'A bill-number facet must not filter itself.',
        );
      },
    );
  }

  test(
    'closure approval uses the reviewed claim and version without replacing commercial tax or exchange rate',
    () async {
      RequestOptions? sent;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            sent = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: <String, dynamic>{},
              ),
            );
          },
        ),
      );
      final repo = DioFinanceProcurementWorkflowRepository(ApiClient(dio));
      const decision = FinanceProcurementDecisionItem(
        caseId: 'closure-1',
        expectedVersion: 7,
        expectedClaimId: 'live-claim',
      );
      await repo.approveOrdersWithExactRate([decision], remark: '  核定余量后结束  ');
      expect(sent!.path, ApiEndpoints.financeProcurementApprovalBatchApprove);
      expect(sent!.data, {
        'items': [
          {
            'caseId': 'closure-1',
            'expectedVersion': 7,
            'expectedClaimId': 'live-claim',
          },
        ],
        'remark': '核定余量后结束',
      });
      await repo.rejectOrdersBatch([decision], '  请先完成质检  ');
      expect(sent!.path, ApiEndpoints.financeProcurementApprovalBatchReject);
      expect(sent!.data, {
        'items': [decision.toJson()],
        'reason': '请先完成质检',
      });
    },
  );

  test(
    'decided closure rounds use history while ordinary pending stays compatible with old endpoint defaults',
    () async {
      final calls = <RequestOptions>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            calls.add(request);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'items': <Map<String, dynamic>>[],
                  'page': 1,
                  'size': 20,
                  'total': 0,
                  'totalPages': 1,
                },
              ),
            );
          },
        ),
      );
      final repo = DioFinanceProcurementWorkflowRepository(ApiClient(dio));
      for (final status in ['PENDING', 'REJECTED', 'APPROVED', 'ALL']) {
        await repo.approvalTasks(status: status);
      }
      expect(calls.first.path, ApiEndpoints.financeProcurementApprovalTasks);
      expect(calls.first.queryParameters.containsKey('status'), isFalse);
      for (var i = 1; i < calls.length; i++) {
        expect(calls[i].path, '/finance/procurement-approvals/history');
        expect(
          calls[i].queryParameters['status'],
          ['REJECTED', 'APPROVED', 'ALL'][i - 1],
        );
      }
    },
  );
}
