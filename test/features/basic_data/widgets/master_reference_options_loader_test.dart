import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/reference_method_option.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/client_master_edit.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_owner.dart';
import 'package:uten_imp/features/basic_data/widgets/supplier_master_edit.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _Methods extends ReferenceMethodRepository {
  _Methods() : super(ApiClient(Dio()));
  final pending = Completer<List<ReferenceMethodOption>>();
  int calls = 0;
  @override
  Future<List<ReferenceMethodOption>> settlementMethods() {
    calls++;
    return pending.future;
  }
}

class _Currencies extends Fake implements CurrencyRepository {
  final pending = Completer<List<CurrencyListItem>>();
  int calls = 0;
  @override
  Future<List<CurrencyListItem>> dict() {
    calls++;
    return pending.future;
  }
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

void main() {
  for (final kind in ['客户结账方式', '供应商结算方式', '币种']) {
    for (final stale in [false, true]) {
      testWidgets('$kind 的共用等待保留编辑所有权，${stale ? '旧范围结果与错误不再发布' : '完成后正常回填'}', (
        tester,
      ) async {
        final methods = _Methods();
        final currencies = _Currencies();
        late WidgetRef pageRef;
        Object? result = 'pending';
        var ownerStayedCurrent = false;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(ApiClient(Dio())),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'editor'),
              ),
              sessionProvider.overrideWith(_Session.new),
              currentPermissionsProvider.overrideWithValue({'master:view'}),
              referenceMethodRepositoryProvider.overrideWithValue(methods),
              currencyRepositoryProvider.overrideWithValue(currencies),
            ],
            child: MaterialApp(
              home: Consumer(
                builder: (context, ref, _) {
                  pageRef = ref;
                  return Scaffold(
                    body: TextButton(
                      onPressed: () async {
                        final owner = MasterEditOwner(
                          context,
                          ref,
                          permissions: {'master:view'},
                          requireWrite: false,
                        );
                        try {
                          if (!await owner.bindRequests()) return;
                          final pending = switch (kind) {
                            '客户结账方式' => loadClientSettlementMethods(
                              context,
                              ref,
                              owner: owner,
                            ),
                            '供应商结算方式' => loadSupplierSettlementMethods(
                              context,
                              ref,
                              owner: owner,
                            ),
                            _ => loadClientCurrencies(
                              context,
                              ref,
                              owner: owner,
                            ),
                          };
                          ownerStayedCurrent = owner.isCurrent;
                          result = await pending;
                        } finally {
                          owner.dispose();
                        }
                      },
                      child: const Text('打开资料'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开资料'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(ownerStayedCurrent, isTrue);
        expect(kind == '币种' ? currencies.calls : methods.calls, 1);
        if (stale) {
          pageRef.read(readScopeRevisionProvider.notifier).state++;
          await tester.pumpAndSettle();
          expect(find.byType(CircularProgressIndicator), findsNothing);
        }
        if (kind == '币种') {
          currencies.pending.complete(const [
            CurrencyListItem(id: 'cny', code: 'CNY', name: '人民币'),
          ]);
        } else {
          methods.pending.complete(const [
            ReferenceMethodOption(id: 'cash', code: 'CASH', name: '现结'),
          ]);
        }
        await tester.pumpAndSettle();
        expect(result, stale ? isNull : isA<List<Object?>>());
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(pageRef.read(appNotificationProvider), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
