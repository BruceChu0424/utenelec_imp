import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/finance/payables/pages/finance_payables_page.dart';
import 'package:uten_imp/features/finance/payables/repositories/subcontract_loss_claim_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('claim-only user opens the embedded excess-loss workspace', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          subcontractLossClaimRepositoryProvider.overrideWithValue(
            SubcontractLossClaimRepository(_ClaimListApi()),
          ),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.subcontractLossClaimView,
          }),
        ],
        child: const MaterialApp(home: FinancePayablesPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('委外超耗责任 (1)'), findsOneWidget);
    expect(find.text('SW-001'), findsOneWidget);
    expect(find.text('待处理'), findsWidgets);
    expect(find.text('生成付款单'), findsNothing);
  });
}

class _ClaimListApi extends ApiClient {
  _ClaimListApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => <String, dynamic>{
    'items': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'case-1',
        'wasteId': 'waste-1',
        'wasteBillNo': 'SW-001',
        'supplierId': 'supplier-1',
        'supplierName': '精密加工厂',
        'status': 'OPEN',
        'actualLossQty': '10.0000',
        'allowedLossQty': '3.0000',
        'excessLossQty': '7.0000',
        'lossBookValueLocal': '70.0000',
        'claimAmountLocal': '0.0000',
        'version': 0,
      },
    ],
    'page': 1,
    'size': 30,
    'total': 1,
    'totalPages': 1,
  };
}
