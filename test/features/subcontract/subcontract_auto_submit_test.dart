import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_doc_edit_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/features/subcontract/services/subcontract_save_workflow.dart';

void main() {
  testWidgets('order save action submits finance while other docs only save', (
    tester,
  ) async {
    var orderPressed = 0;
    var receiptPressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SubcontractSaveActionButton(
                docType: SubcontractDocType.order,
                isLoading: false,
                enabled: true,
                onPressed: () => orderPressed++,
              ),
              SubcontractSaveActionButton(
                docType: SubcontractDocType.receipt,
                isLoading: false,
                enabled: true,
                onPressed: () => receiptPressed++,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('保存并提交财务'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.byIcon(Icons.send_outlined), findsOneWidget);
    expect(find.byIcon(Icons.save_outlined), findsOneWidget);

    await tester.tap(find.text('保存并提交财务'));
    await tester.tap(find.text('保存'));
    expect(orderPressed, 1);
    expect(receiptPressed, 1);
  });

  test('order price validation names the affected goods before save', () {
    expect(
      validateSubcontractOrderPrice(
        docType: SubcontractDocType.order,
        goodsName: '\u6210\u54c1A',
        priceText: '',
      ),
      '\u8bf7\u586b\u5199\u6210\u54c1A\u7684\u6709\u6548\u59d4\u5916\u5355\u4ef7',
    );
    expect(
      validateSubcontractOrderPrice(
        docType: SubcontractDocType.receipt,
        goodsName: '\u6210\u54c1A',
        priceText: '',
      ),
      isNull,
    );
  });

  test(
    'order save workflow submits finance immediately after create',
    () async {
      final repository = _RecordingSubcontractRepository();

      final outcome = await saveSubcontractDocument(
        repository: repository,
        docType: SubcontractDocType.order,
        body: const {'items': <Object>[]},
      );

      expect(repository.createCalls, 1);
      expect(repository.submitCalls, 1);
      expect(outcome.detail.id, 'order-1');
      expect(outcome.financeSubmitError, isNull);
    },
  );

  test('non-order save workflow does not submit finance', () async {
    final repository = _RecordingSubcontractRepository();

    final outcome = await saveSubcontractDocument(
      repository: repository,
      docType: SubcontractDocType.receipt,
      body: const {'items': <Object>[]},
    );

    expect(repository.createCalls, 1);
    expect(repository.submitCalls, 0);
    expect(outcome.detail.id, 'order-1');
    expect(outcome.financeSubmitError, isNull);
  });

  test(
    'finance submit failure preserves saved order for detail retry',
    () async {
      final repository = _RecordingSubcontractRepository(failSubmit: true);

      final outcome = await saveSubcontractDocument(
        repository: repository,
        docType: SubcontractDocType.order,
        body: const {'items': <Object>[]},
      );

      expect(repository.createCalls, 1);
      expect(repository.submitCalls, 1);
      expect(outcome.detail.id, 'order-1');
      expect(outcome.financeSubmitError, '服务暂不可用');
    },
  );

  test('repository endpoint used by the save workflow is stable', () async {
    final requests = <RequestOptions>[];
    final repository = SubcontractRepository(
      _api((request) {
        requests.add(request);
        return {
          'id': 'order-1',
          'billNo': 'SO-001',
          'status': 0,
          'items': <Object>[],
        };
      }),
      SubcontractDocType.order,
    );

    await repository.submitFinance('order-1');

    expect(requests.single.path, '/subcontract/orders/order-1/submit-finance');
    expect(requests.single.method, 'POST');
  });
}

class _RecordingSubcontractRepository extends SubcontractRepository {
  _RecordingSubcontractRepository({this.failSubmit = false})
    : super(_api((_) => const <String, dynamic>{}), SubcontractDocType.order);

  final bool failSubmit;
  int createCalls = 0;
  int submitCalls = 0;

  SubcontractDocDetail get _saved => SubcontractDocDetail.fromJson(const {
    'id': 'order-1',
    'billNo': 'SO-001',
    'status': 0,
    'items': <Object>[],
  });

  @override
  Future<SubcontractDocDetail> create(Map<String, dynamic> body) async {
    createCalls++;
    return _saved;
  }

  @override
  Future<SubcontractDocDetail> update(
    String id,
    Map<String, dynamic> body,
  ) async => _saved;

  @override
  Future<SubcontractDocDetail> submitFinance(String id) async {
    submitCalls++;
    if (failSubmit) throw StateError('finance unavailable');
    return SubcontractDocDetail.fromJson(const {
      'id': 'order-1',
      'billNo': 'SO-001',
      'status': 0,
      'financeApproval': {'status': 'PENDING', 'allowedActions': <Object>[]},
      'items': <Object>[],
    });
  }
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
