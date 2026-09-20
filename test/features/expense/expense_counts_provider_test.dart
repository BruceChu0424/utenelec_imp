import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/expense/providers/expense_counts_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _CountsApi extends ApiClient {
  _CountsApi() : super(Dio());
  final requests = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    final request = Completer<Map<String, dynamic>>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  test('no expense permission means no count request', () async {
    final api = _CountsApi();
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue({}),
        masterDataSessionKeyProvider.overrideWithValue('account-a'),
      ],
    );
    addTearDown(container.dispose);
    expect((await container.read(expenseCountsProvider.future)).mine, 0);
    expect(api.requests, isEmpty);
  });

  test(
    'one request supplies both badges and a new identity cannot inherit old counts',
    () async {
      final identity = StateProvider<String>((ref) => 'account-a');
      final api = _CountsApi();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWithValue({
            Perm.expenseApply,
            Perm.expenseApprove,
            Perm.expensePay,
          }),
          masterDataSessionKeyProvider.overrideWith(
            (ref) => ref.watch(identity),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(expenseMineTodoCountProvider, (_, _) {});
      container.listen(expenseFinanceTodoCountProvider, (_, _) {});
      api.requests.single.complete({
        'draftCount': 2,
        'rejectedCount': 1,
        'pendingApprovalCount': 4,
        'pendingPaymentCount': 3,
      });
      await container.read(expenseCountsProvider.future);
      expect(container.read(expenseMineTodoCountProvider), 3);
      expect(container.read(expenseFinanceTodoCountProvider), 7);
      expect(api.requests.length, 1);
      container.read(identity.notifier).state = 'account-b';
      expect(container.read(expenseMineTodoCountProvider), 0);
      expect(container.read(expenseFinanceTodoCountProvider), 0);
      api.requests.last.complete({'draftCount': 1});
      await container.read(expenseCountsProvider.future);
      expect(container.read(expenseMineTodoCountProvider), 1);
      expect(container.read(expenseFinanceTodoCountProvider), 0);
    },
  );
}
