import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/features/basic_data/models/master_batch.dart';
import 'package:uten_imp/features/basic_data/widgets/master_reference_details.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Grants extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};
  void change(Set<String> value) => state = value;
}

final _grants = NotifierProvider<_Grants, Set<String>>(_Grants.new);

void main() {
  const order = MasterReference(
    kind: 'SALES_ORDER',
    id: 'server-id',
    label: 'XD-显示单号',
  );
  const item = MasterBatchItemResult(
    id: 'party-id',
    ok: false,
    label: '客户甲',
    reason: '仍有关联业务',
    references: [order],
  );

  Future<GoRouter> pump(
    WidgetTester tester, {
    required Set<String> grants,
    List<MasterBatchItemResult> items = const [item],
  }) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(
                  showMasterReferenceDetails(
                    context,
                    ref,
                    entityPath: '/master/clients',
                    items: items,
                  ),
                ),
                child: const Text('去查看'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/sales/orders/server-id',
          builder: (_, _) => const Scaffold(body: Text('订单详情')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_Session.new),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'test'),
          ),
          _grants.overrideWith(() => _Grants()),
          currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold)),
    );
    container.read(_grants.notifier).change({Perm.clientView, ...grants});
    await tester.pump();
    await tester.tap(find.text('去查看'));
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets(
    'opens the authorized server identity, never a label-derived ID',
    (tester) async {
      await pump(tester, grants: {Perm.salesOrderView});
      await tester.tap(find.text(order.label));
      await tester.pumpAndSettle();
      expect(find.text('订单详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keeps unauthorized references read-only', (tester) async {
    await pump(tester, grants: {});
    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, order.label),
    );
    expect(tile.onTap, isNull);
    await tester.tap(find.text(order.label));
    await tester.pumpAndSettle();
    expect(find.text('关联业务'), findsOneWidget);
    expect(find.text('订单详情'), findsNothing);
  });

  testWidgets('permission changes retire the open reference list permanently', (
    tester,
  ) async {
    await pump(tester, grants: {Perm.salesOrderView});
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    container.read(_grants.notifier).change({Perm.clientView});
    await tester.pumpAndSettle();
    container.read(_grants.notifier).change({
      Perm.clientView,
      Perm.salesOrderView,
    });
    await tester.pumpAndSettle();
    expect(find.text('关联业务'), findsNothing);
    expect(find.text(order.label), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('500 selected parties remain scrollable in a narrow window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(
      tester,
      grants: {Perm.salesOrderView},
      items: [
        for (var i = 0; i < 500; i++)
          MasterBatchItemResult(
            id: 'p-$i',
            ok: false,
            label: '客户$i',
            reason: '已有订单及往来保留',
            references: [order],
          ),
      ],
    );
    expect(find.text('客户0'), findsOneWidget);
    expect(find.text('客户499'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('客户0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('ledger routes preserve party identity and direction', () {
    for (final kind in ['RECEIVABLE', 'PAYABLE']) {
      final location = masterReferenceLocation(
        MasterReference(kind: kind, id: 'ledger-id', label: '往来'),
        partyId: 'hidden-party',
      )!;
      final uri = Uri.parse(location);
      expect(uri.path, '/finance/ar-ap');
      expect(uri.queryParameters['partyId'], 'hidden-party');
      expect(
        uri.queryParameters['direction'],
        kind == 'RECEIVABLE' ? 'AR' : 'AP',
      );
    }
    expect(
      masterReferenceLocation(
        const MasterReference(kind: 'UNKNOWN', id: 'x', label: 'x'),
        partyId: 'p',
      ),
      isNull,
    );
  });
}
