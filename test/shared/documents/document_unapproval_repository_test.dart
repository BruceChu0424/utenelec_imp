import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/documents/document_unapproval.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/repositories/finance_repository.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/repositories/purchase_repository.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';

void main() {
  test(
    'standard unapproval sends only intent and returns the successor identity',
    () async {
      final api = _UnapprovalApi();
      final scenarios = <({String family, Future<String> Function() call})>[
        (
          family: 'purchaseOrder',
          call: () async => (await PurchaseRepository(
            api,
            PurchaseDocType.order,
          ).reverse('original')).id,
        ),
        (
          family: 'subcontractOrder',
          call: () async => (await SubcontractRepository(
            api,
            SubcontractDocType.order,
          ).reverse('original')).id,
        ),
        (
          family: 'salesOrder',
          call: () async => (await SalesRepository(
            api,
            SalesDocType.order,
          ).reverse('original')).id,
        ),
        (
          family: 'productionPlan',
          call: () async =>
              (await ProductionPlanRepository(api).reverse('original')).id,
        ),
        (
          family: 'productionDailyReport',
          call: () async => (await ProductionDailyReportRepository(
            api,
          ).reverse('original')).id,
        ),
        (
          family: 'stockDocument',
          call: () async => (await StockDocRepository(
            api,
            StockDocType.otherIn,
          ).reverse('original')).id,
        ),
        for (final type in FinanceDocType.values)
          (
            family: switch (type) {
              FinanceDocType.receipt => 'financeReceipt',
              FinanceDocType.payment => 'financePayment',
              FinanceDocType.expense => 'financeExpense',
              FinanceDocType.otherIncome => 'financeOtherIncome',
              FinanceDocType.bankTransfer => 'financeBankTransfer',
            },
            call: () async =>
                (await FinanceRepository(api, type).reverse('original')).id,
          ),
      ];
      final keys = <String>{};
      for (final scenario in scenarios) {
        expect(await scenario.call(), 'successor');
        expect(api.path, '/documents/${scenario.family}/original/unapprove');
        final body = Map<String, dynamic>.from(api.body! as Map);
        expect(body.keys.toSet(), {
          'idempotencyKey',
          'reason',
          'expectedSnapshot',
        });
        expect(body['expectedSnapshot'], 'a' * 64);
        expect(body['reason'], isNotEmpty);
        expect(keys.add(body['idempotencyKey'] as String), isTrue);
      }
    },
  );

  test(
    'successor evidence does not claim a reapproved document is a draft',
    () {
      final evidence = requireUnapprovalEvidence('original', {
        'id': 'successor',
        'unapprovalOriginalId': 'original',
        'status': 1,
      });
      expect(evidence.isDraft, isFalse);
      expect(evidence.message, contains('原审核已撤回'));
      expect(evidence.message, contains('后续单据已审核'));
      expect(evidence.message, isNot(contains('进入草稿')));
    },
  );

  test('original, foreign or missing-state responses cannot prove a draft', () {
    for (final response in <Map<String, dynamic>>[
      {'id': 'original', 'unapprovalOriginalId': 'original', 'status': 0},
      {
        'id': 'foreign-successor',
        'unapprovalOriginalId': 'foreign-original',
        'status': 0,
      },
      {'id': 'successor', 'unapprovalOriginalId': 'original'},
      {'id': 'successor', 'status': 0},
    ]) {
      expect(
        () => requireUnapprovalEvidence('original', response),
        throwsA(isA<ApiException>()),
      );
    }
  });

  test(
    'physical production return and finished receipt keep their dedicated guards',
    () async {
      final api = _UnapprovalApi();
      final repository = StockDocRepository(api, StockDocType.wdraw);
      await repository.reverseMaterialReturn('original');
      expect(api.path, '/stock/docs/original/reverse');
      await repository.reverseFinishedInbound('original');
      expect(api.path, '/stock/docs/original/finished-in/reverse');
    },
  );
}

class _UnapprovalApi extends ApiClient {
  _UnapprovalApi() : super(Dio());
  String? path;
  Object? body;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'supported': true,
    'permitted': true,
    'eligible': true,
    'nextAction': 'UNAPPROVE_TO_DRAFT',
    'factsSnapshot': 'a' * 64,
    'reasons': <Object>[],
  };
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.body = body;
    return {
      'id': 'successor',
      'unapprovalOriginalId': 'original',
      'status': 0,
      'items': <Object>[],
      'workerIds': <String>[],
      'materialUsages': <Object>[],
      'outputBatches': <Object>[],
      'docType': 'OTHER_IN',
    };
  }
}
