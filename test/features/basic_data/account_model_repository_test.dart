import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/account_node.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';

void main() {
  test('account model prioritizes exact decimal text for NUMERIC(18,4)', () {
    final account = AccountListItem.fromJson({
      'id': 'account-1',
      'currencyId': 'currency-cny',
      'exchangeRate': 1,
      'exchangeRateText': '1.000000',
      'baseCurrency': true,
      'balanceCurrent': 99999999999999.12,
      'balanceCurrentText': '99999999999999.1234',
      'initBalance': 99999999999999.12,
      'initBalanceText': '99999999999999.1234',
      'adjustmentsTotal': 0.0001,
      'adjustmentsTotalText': '0.0001',
    });

    expect(account.balanceCurrentText, '99999999999999.1234');
    expect(account.initBalanceText, '99999999999999.1234');
    expect(account.adjustmentsTotalText, '0.0001');
    expect(account.exchangeRateText, '1.000000');
    expect(account.baseCurrency, isTrue);
  });

  test(
    'balance batch repository sends exact strings without double round-trip',
    () async {
      late RequestOptions captured;
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            captured = request;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'id': 'batch-1',
                  'batchNo': 'AB260001',
                  'scope': 'SELECTED',
                  'effectiveDate': '2026-08-27',
                  'reason': '上线核对',
                  'itemCount': 1,
                  'changedCount': 1,
                  'items': <Object?>[],
                },
              ),
            );
          },
        ),
      );
      final repository = DioAccountRepository(ApiClient(dio));

      await repository.adjustBalances(
        scope: AccountBalanceAdjustmentScope.selected,
        effectiveDate: '2026-08-27',
        reason: '上线核对',
        idempotencyKey: '00000000-0000-4000-8000-000000000001',
        items: const [
          AccountBalanceAdjustmentInput(
            accountId: 'account-1',
            expectedBalance: '99999999999999.1234',
            targetBalance: '99999999999999.1235',
            localDelta: '0.0001',
          ),
        ],
      );

      expect(captured.path, '/finance/account-balance-adjustments/batch');
      final body = captured.data as Map<String, dynamic>;
      final item =
          (body['items'] as List<dynamic>).single as Map<String, dynamic>;
      expect(item['expectedBalance'], '99999999999999.1234');
      expect(item['targetBalance'], '99999999999999.1235');
      expect(item['localDelta'], '0.0001');
      expect(body['scope'], 'SELECTED');
    },
  );

  test('account update returns the server detail response', () async {
    late RequestOptions captured;
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          captured = request;
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: const {
                'id': 'account-1',
                'code': 'ZH000001',
                'name': '修改后账户',
                'accountType': 'BANK',
                'currencyId': 'currency-cny',
                'currencyCode': 'CNY',
                'currencyName': '人民币',
                'status': '使用',
              },
            ),
          );
        },
      ),
    );
    final repository = DioAccountRepository(ApiClient(dio));

    final detail = await repository.update('account-1', const {
      'name': '修改后账户',
    });

    expect(captured.method, 'PUT');
    expect(captured.path, '/master/accounts/account-1');
    expect(detail.id, 'account-1');
    expect(detail.name, '修改后账户');
    expect(detail.currencyName, '人民币');
  });

  test('balance adjustment result keeps the local amount basis', () {
    final item = AccountBalanceAdjustmentResultItem.fromJson(const {
      'id': 'item-1',
      'accountId': 'account-1',
      'deltaLocal': '720.0000',
      'deltaLocalText': '720.0000',
      'localAmountBasis': 'FINANCE_EXPLICIT_LOCAL',
      'verified': true,
    });

    expect(item.deltaLocalText, '720.0000');
    expect(item.localAmountBasis, 'FINANCE_EXPLICIT_LOCAL');
  });
}
