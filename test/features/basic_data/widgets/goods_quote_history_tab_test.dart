import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_quote_history_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_quote_history_tab.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
  void replaceIdentity() =>
      state = const SessionState(status: AuthStatus.mustChangePassword);
}

class _History implements GoodsQuoteHistoryRepository {
  final requests = <String>[];
  final pending = <String, Completer<PagedResult<GoodsQuoteHistoryRow>>>{};
  @override
  Future<PagedResult<GoodsQuoteHistoryRow>> list(
    String goodsId, {
    int page = 1,
  }) {
    requests.add(goodsId);
    return (pending[goodsId] ??= Completer()).future;
  }
}

PagedResult<GoodsQuoteHistoryRow> _page(String client, {String? order}) =>
    PagedResult(
      items: [
        GoodsQuoteHistoryRow({
          'id': client,
          'quoteId': 'quote-1',
          'billNo': 'XB-001',
          'clientName': client,
          'sellerName': '业务员甲',
          'occurredAt': '2026-10-02T00:00:00Z',
          'qty': '10',
          'price': '12.3456',
          'discount': '0.9',
          'amount': '111.11',
          'revision': 3,
          'action': 'CONFIRM',
          'orderId': order,
          'orderNo': order == null ? null : 'XD-001',
        }),
      ],
      page: 1,
      size: 20,
      total: 1,
      totalPages: 1,
    );

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pump(
    WidgetTester tester,
    _History history,
    GoRouter router,
    Set<String> permissions,
  ) async {
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          goodsQuoteHistoryRepositoryProvider.overrideWithValue(history),
          sessionProvider.overrideWith(_Session.new),
          currentPermissionsProvider.overrideWithValue(permissions),
          isSuperAdminProvider.overrideWithValue(false),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pump();
  }

  GoRouter routes() => GoRouter(
    initialLocation: '/goods/a',
    routes: [
      GoRoute(
        path: '/goods/:id',
        builder: (_, state) => Scaffold(
          body: GoodsQuoteHistoryTab(goodsId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/sales/orders/:id',
        builder: (_, _) => const Scaffold(body: Text('订货单详情')),
      ),
      GoRoute(
        path: '/finance/quote-review/:id',
        builder: (_, _) => const Scaffold(body: Text('报价核价详情')),
      ),
      GoRoute(
        path: '/finance/sales-order-confirmations/:id',
        builder: (_, _) => const Scaffold(body: Text('订货财务详情')),
      ),
    ],
  );

  testWidgets(
    'goods price permission does not expose client quotation history',
    (tester) async {
      final history = _History();
      final router = routes();
      addTearDown(router.dispose);
      await pump(tester, history, router, {
        Perm.goodsView,
        Perm.goodsPriceView,
      });
      await tester.pumpAndSettle();
      expect(history.requests, isEmpty);
      expect(
        find.byType(MasterDataTableView<GoodsQuoteHistoryRow>),
        findsNothing,
      );
    },
  );

  testWidgets('exact historical price and order navigation use the saved row', (
    tester,
  ) async {
    final history = _History();
    final router = routes();
    addTearDown(router.dispose);
    await pump(tester, history, router, {
      Perm.goodsView,
      Perm.salesQuoteFinanceView,
      Perm.salesOrderView,
    });
    history.pending['a']!.complete(_page('历史客户', order: 'order-1'));
    await tester.pumpAndSettle();
    expect(find.text('历史客户'), findsWidgets);
    expect(find.text('12.3456'), findsWidgets);
    final table = tester.widget<MasterDataTableView<GoodsQuoteHistoryRow>>(
      find.byType(MasterDataTableView<GoodsQuoteHistoryRow>),
    );
    table.onRowTap!(table.items.single);
    await tester.pumpAndSettle();
    expect(find.text('订货单详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a slow previous goods response cannot replace the new goods history',
    (tester) async {
      final history = _History();
      final router = routes();
      addTearDown(router.dispose);
      await pump(tester, history, router, {
        Perm.goodsView,
        Perm.salesQuoteFinanceView,
      });
      router.go('/goods/b');
      await tester.pump();
      await tester.pump();
      history.pending['b']!.complete(_page('新货品客户'));
      await tester.pumpAndSettle();
      history.pending['a']!.complete(_page('旧货品客户'));
      await tester.pumpAndSettle();
      expect(find.text('新货品客户'), findsWidgets);
      expect(find.text('旧货品客户'), findsNothing);
      final table = tester.widget<MasterDataTableView<GoodsQuoteHistoryRow>>(
        find.byType(MasterDataTableView<GoodsQuoteHistoryRow>),
      );
      table.onRowTap!(table.items.single);
      await tester.pumpAndSettle();
      expect(find.text('本次报价历史快照'), findsOneWidget);
    },
  );

  testWidgets(
    'finance readers use their cross-salesperson order review route',
    (tester) async {
      final history = _History();
      final router = routes();
      addTearDown(router.dispose);
      await pump(tester, history, router, {
        Perm.goodsView,
        Perm.salesQuoteFinanceView,
        Perm.salesOrderView,
        Perm.salesOrderFinanceView,
      });
      history.pending['a']!.complete(_page('财务可见客户', order: 'order-1'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<GoodsQuoteHistoryRow>>(
        find.byType(MasterDataTableView<GoodsQuoteHistoryRow>),
      );
      table.onRowTap!(table.items.single);
      await tester.pumpAndSettle();
      expect(find.text('订货财务详情'), findsOneWidget);
    },
  );

  testWidgets(
    'an open historical snapshot hides private values after identity changes',
    (tester) async {
      final history = _History();
      final router = routes();
      addTearDown(router.dispose);
      await pump(tester, history, router, {
        Perm.goodsView,
        Perm.salesQuoteFinanceView,
      });
      history.pending['a']!.complete(_page('旧身份客户'));
      await tester.pumpAndSettle();
      final tableFinder = find.byType(
        MasterDataTableView<GoodsQuoteHistoryRow>,
      );
      final container = ProviderScope.containerOf(tester.element(tableFinder));
      final table = tester.widget<MasterDataTableView<GoodsQuoteHistoryRow>>(
        tableFinder,
      );
      table.onRowTap!(table.items.single);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('旧身份客户'),
        ),
        findsOneWidget,
      );
      (container.read(sessionProvider.notifier) as _Session).replaceIdentity();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('旧身份客户'),
        ),
        findsNothing,
      );
      expect(find.text('当前身份或权限已变化'), findsOneWidget);
    },
  );
}
