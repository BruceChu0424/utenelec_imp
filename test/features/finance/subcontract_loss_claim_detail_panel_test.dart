import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/payables/repositories/subcontract_loss_claim_repository.dart';
import 'package:uten_imp/features/finance/payables/widgets/subcontract_loss_claim_detail_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'cash and physical plans are actionable while service reduction stays dedicated',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pump(
        tester,
        detail: _awaitingDetail,
        permissions: const {
          Perm.subcontractLossClaimView,
          Perm.subcontractLossClaimFulfill,
          Perm.subcontractLossClaimReverse,
        },
      );

      expect(find.text('等待专用资金到账，不可手工完成'), findsNothing);
      expect(find.text('等待红字发票或供应商贷项凭证，不可手工完成'), findsOneWidget);
      expect(find.text('登记履约'), findsNWidgets(2));
      expect(find.text('反转责任决定'), findsOneWidget);
      expect(find.text('责任决定'), findsNothing);
    },
  );

  testWidgets('action buttons are hidden without action permissions', (
    tester,
  ) async {
    await _pump(
      tester,
      detail: _awaitingDetail,
      permissions: const {Perm.subcontractLossClaimView},
    );

    expect(find.text('等待专用资金到账，不可手工完成'), findsNothing);
    expect(find.text('等待红字发票或供应商贷项凭证，不可手工完成'), findsOneWidget);
    expect(find.text('登记履约'), findsNothing);
    expect(find.text('反转责任决定'), findsNothing);
  });

  testWidgets('fulfilled cash and material resolutions expose reverse action', (
    tester,
  ) async {
    await _pump(
      tester,
      detail: _fulfilledDetail,
      permissions: const {
        Perm.subcontractLossClaimView,
        Perm.subcontractLossClaimFulfill,
        Perm.subcontractLossClaimReverse,
      },
    );

    expect(find.text('反转履约'), findsWidgets);
  });

  testWidgets('open case exposes review action only with review permission', (
    tester,
  ) async {
    await _pump(
      tester,
      detail: _openDetail,
      permissions: const {
        Perm.subcontractLossClaimView,
        Perm.subcontractLossClaimReview,
      },
    );

    expect(find.text('责任决定'), findsOneWidget);
    expect(find.text('反转责任决定'), findsNothing);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required Map<String, dynamic> detail,
  required Set<String> permissions,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        subcontractLossClaimRepositoryProvider.overrideWithValue(
          SubcontractLossClaimRepository(_DetailApi(detail)),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: const MaterialApp(
        home: SubcontractLossClaimDetailPanel(caseId: 'case-1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _summaryBase = <String, dynamic>{
  'id': 'case-1',
  'wasteId': 'waste-1',
  'wasteBillNo': 'SW-001',
  'supplierId': 'supplier-1',
  'supplierName': '精密加工厂',
  'actualLossQty': '10.0000',
  'allowedLossQty': '3.0000',
  'excessLossQty': '7.0000',
  'lossBookValueLocal': '70.0000',
  'claimAmountLocal': '100.0000',
  'version': 4,
};

const _line = <String, dynamic>{
  'id': 'line-1',
  'goodsCode': 'G-01',
  'goodsName': '铜料',
  'actualLossQty': '10.0000',
  'allowedLossQty': '3.0000',
  'excessLossQty': '7.0000',
  'unitBookValueLocal': '10.0000',
  'lossBookValueLocal': '70.0000',
  'valuationStatus': 'VALUED',
};

const _awaitingDetail = <String, dynamic>{
  'summary': <String, dynamic>{
    ..._summaryBase,
    'status': 'AWAITING_FULFILLMENT',
  },
  'lines': [_line],
  'resolutions': <Map<String, dynamic>>[
    {
      'id': 'cash-1',
      'caseLineId': 'line-1',
      'type': 'CASH_COMPENSATION',
      'quantity': '3.0000',
      'amountLocal': '30.0000',
      'status': 'PENDING',
    },
    {
      'id': 'service-1',
      'caseLineId': 'line-1',
      'type': 'SERVICE_PRICE_REDUCTION',
      'quantity': '1.0000',
      'amountLocal': '10.0000',
      'status': 'PENDING',
    },
    {
      'id': 'material-1',
      'caseLineId': 'line-1',
      'type': 'MATERIAL_REPLACEMENT',
      'quantity': '4.0000',
      'amountLocal': '0.0000',
      'status': 'PENDING',
    },
  ],
  'events': <Map<String, dynamic>>[],
};

const _fulfilledDetail = <String, dynamic>{
  'summary': <String, dynamic>{..._summaryBase, 'status': 'RESOLVED'},
  'lines': [_line],
  'resolutions': <Map<String, dynamic>>[
    {
      'id': 'cash-fulfilled',
      'caseLineId': 'line-1',
      'type': 'CASH_COMPENSATION',
      'quantity': '1.0000',
      'amountLocal': '10.0000',
      'status': 'FULFILLED',
    },
    {
      'id': 'material-fulfilled',
      'caseLineId': 'line-1',
      'type': 'MATERIAL_REPLACEMENT',
      'quantity': '1.0000',
      'amountLocal': '0.0000',
      'status': 'FULFILLED',
    },
    {
      'id': 'output-fulfilled',
      'caseLineId': 'line-1',
      'type': 'OUTPUT_REPLACEMENT',
      'quantity': '1.0000',
      'amountLocal': '0.0000',
      'status': 'FULFILLED',
      'fulfillmentDocType': 'SUBCONTRACT_RECEIPT',
      'fulfillmentDocId': '11111111-1111-4111-8111-111111111111',
      'fulfillmentDocNo': 'SRI-001',
    },
  ],
  'events': <Map<String, dynamic>>[],
};

const _openDetail = <String, dynamic>{
  'summary': <String, dynamic>{..._summaryBase, 'status': 'OPEN'},
  'lines': [_line],
  'resolutions': <Map<String, dynamic>>[],
  'events': <Map<String, dynamic>>[],
};

class _DetailApi extends ApiClient {
  _DetailApi(this.detail) : super(Dio());

  final Map<String, dynamic> detail;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => detail;
}
