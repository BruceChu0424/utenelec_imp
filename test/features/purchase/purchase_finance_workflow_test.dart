import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/shared/models/procurement_finance_approval.dart';

void main() {
  test(
    'business order detail keeps finance status but exposes no decision helper',
    () {
      final pending = PurchaseDocDetail.fromJson({
        'id': 'order-1',
        'financeApproval': {
          'caseId': 'case-1',
          'status': 'PENDING',
          'attempt': 1,
          'version': 3,
          'assigneeUserId': 'finance-user',
          'assigneeName': '财务张三',
          'allowedActions': ['APPROVE', 'REJECT'],
        },
      });
      expect(pending.financeApproval?.isPending, isTrue);
      expect(pending.financeApproval?.canSubmit, isFalse);
      expect(pending.financeApproval?.allowedActions, {'APPROVE', 'REJECT'});
    },
  );

  test('order display label follows finance projection before approval', () {
    ProcurementFinanceApproval approval(String status) =>
        ProcurementFinanceApproval.fromJson({'status': status});

    // 在审/退回：单据 status 仍为 0，展示以审批投影为准，不再误显「草稿」。
    expect(purchaseOrderDisplayLabel(0, approval('PENDING')), '等待财务审核');
    expect(purchaseOrderDisplayLabel(0, approval('REJECTED')), '财务退回');
    expect(purchaseOrderDisplayLabel(0, approval('DRAFT')), '待提交财务');
    expect(purchaseOrderDisplayLabel(1, approval('APPROVED')), '财务已通过');
    // 终态（红冲/已取消）优先于审批投影，红冲后的在案通过不再盖过「红冲」。
    expect(purchaseOrderDisplayLabel(-1, approval('APPROVED')), '红冲');
    expect(purchaseOrderDisplayLabel(2, approval('CANCELED')), '已取消');
    // 无投影（未建案）与历史/未知态回落单据状态文案。
    expect(purchaseOrderDisplayLabel(0, null), '草稿');
    expect(purchaseOrderDisplayLabel(1, approval('LEGACY_EFFECTIVE')), '已审');
    expect(purchaseOrderDisplayLabel(-1, approval('LEGACY_REVERSED')), '红冲');
  });

  test('business repository only sends the submit-finance command', () async {
    final requests = <RequestOptions>[];
    final repository = PurchaseRepository(
      _api((request) {
        requests.add(request);
        return <String, dynamic>{
          'id': 'order-1',
          'financeApproval': <String, dynamic>{
            'status': 'PENDING',
            'attempt': 1,
            'version': 4,
            'allowedActions': <String>[],
          },
        };
      }),
      PurchaseDocType.order,
    );

    await repository.submitFinance('order-1');

    expect(requests, hasLength(1));
    expect(requests.single.path, '/purchase/orders/order-1/submit-finance');
    expect(requests.single.data, isNull);
  });
}

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: responder(request),
        ),
      ),
    ),
  );
  return ApiClient(dio);
}
