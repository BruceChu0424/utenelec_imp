import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/features/finance/payables/models/finance_payable.dart';
import 'package:uten_imp/features/finance/payables/repositories/finance_payables_repository.dart';
import 'package:uten_imp/features/finance/payables/widgets/supplier_credit_apply_panel.dart';
import '../../support/uten_test_actions.dart';

void main() {
  testWidgets(
    'credit candidates keep the complete typed snapshot, exact eligibility and entered amount without scroll reads',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      tester.view.devicePixelRatio = 1;
      await setUtenTestSurfaceSize(tester, const Size(1400, 1000));
      addTearDown(() => setUtenTestSurfaceSize(tester, null));
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _Api();
      var opened = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'finance-credit-fixture'),
            ),
            currentPermissionsProvider.overrideWithValue(const {}),
            isSuperAdminProvider.overrideWithValue(false),
            apiBaseUrlProvider.overrideWithValue('http://127.0.0.1:9'),
            sharedPreferencesProvider.overrideWithValue(preferences),
            financePayablesRepositoryProvider.overrideWithValue(
              FinancePayablesRepository(api),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () {
                    opened = true;
                    showSupplierCreditApplyPanel(
                      context: context,
                      source: const FinancePayableItem(
                        id: 'credit',
                        openItemKind: 'CREDIT',
                        supplierId: 'supplier',
                        currencyId: 'usd',
                        bookingRate: '7.123456',
                        outstandingOriginal: '-1.0001',
                      ),
                    );
                  },
                  child: const Text('打开贷项'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开贷项'));
      expect(
        opened,
        isTrue,
        reason:
            'The visible native action must dispatch before waiting for its read',
      );
      for (var frame = 0; frame < 150 && api.queries.length < 2; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(api.queries, [
        {
          'page': 1,
          'size': 200,
          'supplierId': 'supplier',
          'currencyId': 'usd',
          'status': 'OPEN',
        },
        {
          'page': 2,
          'size': 200,
          'supplierId': 'supplier',
          'currencyId': 'usd',
          'status': 'OPEN',
        },
      ]);
      expect(find.text('加载更多'), findsNothing);
      final list = find.byType(ListView).last;
      expect(tester.widget<ListView>(list).semanticChildCount, 206);
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      final last = find.byKey(
        const ValueKey('supplier-offset-target-target-204'),
      );
      await tester.scrollUntilVisible(last, 300, scrollable: scrollable);
      await tester.tap(last);
      await tester.pump();
      final amount = find.byKey(
        const ValueKey('supplier-offset-amount-target-204'),
      );
      expect(tester.widget<TextField>(amount).controller!.text, '100.0001');
      await tester.enterText(amount, '0.0001');
      position.jumpTo(0);
      await tester.pumpAndSettle();
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(last, 300, scrollable: scrollable);
      expect(tester.widget<TextField>(amount).controller!.text, '0.0001');
      expect(tester.widget<CheckboxListTile>(last).value, true);
      expect(
        find.byKey(const ValueKey('supplier-offset-target-incompatible')),
        findsNothing,
      );
      expect(api.queries, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final queries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expectSync(path, '/finance/payables');
    queries.add({...?query});
    final page = query!['page'] as int;
    final all = [
      for (var i = 0; i < 205; i++)
        {
          'id': 'target-$i',
          'sourceDocNo': 'PI-$i',
          'openItemKind': 'PAYABLE',
          'supplierId': 'supplier',
          'currencyId': 'usd',
          'bookingRate': '7.123456',
          'outstandingOriginal': '100.0001',
          'status': 'OPEN',
        },
      {
        'id': 'incompatible',
        'openItemKind': 'PAYABLE',
        'supplierId': 'supplier',
        'currencyId': 'usd',
        'bookingRate': '7.123457',
        'outstandingOriginal': '100.0001',
        'status': 'OPEN',
      },
    ];
    return {
      'items': all.skip((page - 1) * 200).take(200).toList(),
      'page': page,
      'size': 200,
      'total': all.length,
      'totalPages': 2,
      'summary': {'outstandingLocal': '999999.1234'},
    };
  }
}
