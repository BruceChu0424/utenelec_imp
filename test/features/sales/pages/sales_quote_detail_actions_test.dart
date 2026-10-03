// 报价详情(ADR-134)：状态横幅 + 按服务端 allowedActions 显示的按钮
// (提交财务核价 / 撤回 / 重新修改 / 转订货单 / 作废 / 去核价)，不再有「审核」；
// 写操作都带 reviewRevision；本地权限码不参与报价按钮显隐。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';

import 'package:uten_imp/shared/providers/session_provider.dart';
import '../../../shared/drafts/memory_form_draft_storage.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

import '../../../helpers/badge_summary_fixture.dart';

class _AuthenticatedSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'reader', code: 'reader', name: '当前读者'),
  );
}

class _ConfirmedSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

Map<String, dynamic> _quote({
  required int status,
  List<String> actions = const [],
  Map<String, dynamic> extra = const {},
}) => {
  'id': 'quote-1',
  'billNo': 'XB-20260927-001',
  'billDate': '2026-09-27',
  'status': status,
  'writable': true,
  'reviewRevision': 4,
  'allowedActions': actions,
  'items': <Map<String, dynamic>>[
    {
      'id': 'line-1',
      'goodsId': 'goods-1',
      'qty': 2,
      'price': 100,
      'discount': 0.95,
      'amountOriginal': 190,
    },
  ],
  ...extra,
};

class _QuoteApi extends ApiClient {
  _QuoteApi(this.detail) : super(Dio());

  Map<String, dynamic> detail;
  final List<String> postPaths = [];
  final Map<String, Object?> postBodies = {};
  final List<String> deleted = [];
  Map<String, dynamic>? afterPost;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => detail;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    postPaths.add(path);
    postBodies[path] = body;
    if (path.endsWith('/convert')) {
      return {'id': 'order-9', 'billNo': 'XD-009', 'status': 0};
    }
    if (afterPost != null) detail = afterPost!;
    return detail;
  }

  @override
  Future<void> delete(String path, {Map<String, dynamic>? query}) async =>
      deleted.add(path);

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

Future<_QuoteApi> _pump(
  WidgetTester tester,
  Map<String, dynamic> detail, {
  Set<String> permissions = const {Perm.salesQuoteView},
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _QuoteApi(detail);
  final router = GoRouter(
    initialLocation: '/sales/quotes/quote-1',
    routes: [
      GoRoute(
        path: '/sales/quotes',
        builder: (_, _) => const Scaffold(body: Text('quote-list')),
      ),
      GoRoute(
        path: '/sales/quotes/:id',
        builder: (_, state) => SalesDocDetailPage(
          docType: SalesDocType.quote,
          id: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/sales/orders/:id/edit',
        builder: (_, state) =>
            Scaffold(body: Text('order-edit-${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/sales/orders/:id',
        builder: (_, state) =>
            Scaffold(body: Text('order-${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/finance/quote-review/:id',
        builder: (_, state) =>
            Scaffold(body: Text('finance-${state.pathParameters['id']}')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        sessionProvider.overrideWith(_TestSession.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'test-user'),
        ),
        sessionSnapshotProvider.overrideWith(_TestSnapshot.new),
        apiBaseUrlProvider.overrideWith((ref) => 'https://test-server/api'),
        sessionProvider.overrideWith(_AuthenticatedSession.new),
        sessionSnapshotProvider.overrideWith(_ConfirmedSnapshot.new),
        apiBaseUrlProvider.overrideWithValue('http://localhost:8080/api'),
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Future<void> _tapAndConfirm(WidgetTester tester, String buttonKey) async {
  await tester.tap(find.byKey(ValueKey(buttonKey)));
  await tester.pumpAndSettle();
  // UtenDialog：取消在前、确认在后。
  final dialog = find.byType(AlertDialog);
  expect(dialog, findsOneWidget);
  await tester.tap(
    find.descendant(of: dialog, matching: find.byType(UtenButton)).last,
  );
  await tester.pumpAndSettle();
}

class _TestSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'test-user', code: 'E001', name: '测试员工'),
  );
}

class _TestSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

void main() {
  testWidgets(
    'customer acceptance records the displayed revision before conversion',
    (tester) async {
      final api = await _pump(
        tester,
        _quote(
          status: 1,
          actions: const ['customerConfirm', 'reopen', 'cancel'],
        ),
      );
      expect(find.byKey(const ValueKey('sales-quote-convert')), findsNothing);
      api.afterPost = _quote(
        status: 1,
        actions: const ['convert', 'reopen', 'cancel'],
        extra: const {
          'customerAcceptedAt': '2026-10-02T10:00:00Z',
          'customerAcceptedRevision': 5,
          'reviewRevision': 5,
        },
      );
      await _tapAndConfirm(tester, 'sales-quote-customer-confirm');
      expect(api.postBodies['/sales/quotes/quote-1/customer-confirm'], {
        'expectedRevision': 4,
      });
      expect(
        find.byKey(const ValueKey('sales-quote-customer-confirm')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('sales-quote-convert')), findsOneWidget);
      expect(find.textContaining('已登记客户同意'), findsOneWidget);
    },
  );

  testWidgets('cancel requires a reason and keeps revision history', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _quote(status: 1, actions: const ['cancel']),
    );
    await tester.tap(find.byKey(const ValueKey('sales-quote-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sales-quote-cancel-submit')));
    await tester.pumpAndSettle();
    expect(api.postPaths, isEmpty);
    expect(find.textContaining('请填写取消原因'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('sales-quote-cancel-reason')),
      '客户未接受报价',
    );
    api.afterPost = _quote(
      status: -1,
      extra: const {'cancelReason': '客户未接受报价'},
    );
    await tester.tap(find.byKey(const ValueKey('sales-quote-cancel-submit')));
    await tester.pumpAndSettle();
    expect(api.postBodies['/sales/quotes/quote-1/cancel'], {
      'expectedRevision': 4,
      'reason': '客户未接受报价',
    });
    expect(find.textContaining('历史记录保留：客户未接受报价'), findsOneWidget);
  });

  testWidgets('draft quote: submit for finance pricing, no self-approval', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _quote(status: 0, actions: const ['edit', 'delete', 'submit']),
      // 本地持有旧的报价审核能力也不再出现「审核」按钮。
      permissions: const {
        Perm.salesQuoteView,
        Perm.salesQuoteEdit,
        Perm.salesQuoteDelete,
      },
    );
    expect(find.byKey(const Key('sales-quote-status-strip')), findsOneWidget);
    expect(find.textContaining('提交财务核价'), findsWidgets);
    expect(find.byKey(const ValueKey('sales-quote-submit')), findsOneWidget);
    expect(find.byKey(const ValueKey('sales-doc-edit')), findsOneWidget);
    expect(find.byKey(const ValueKey('sales-quote-delete')), findsOneWidget);
    expect(find.text('审核'), findsNothing);
    expect(find.byKey(const ValueKey('sales-quote-convert')), findsNothing);

    api.afterPost = _quote(status: 2, actions: const ['withdraw']);
    await _tapAndConfirm(tester, 'sales-quote-submit');
    expect(api.postPaths, contains('/sales/quotes/quote-1/submit'));
    expect(api.postBodies['/sales/quotes/quote-1/submit'], {
      'expectedRevision': 4,
    });
    // 重读后进入待财务核价：只剩撤回。
    expect(find.byKey(const ValueKey('sales-quote-withdraw')), findsOneWidget);
    expect(find.byKey(const ValueKey('sales-quote-submit')), findsNothing);
    expect(find.textContaining('正在等财务定价格'), findsOneWidget);
  });

  testWidgets('pending quote can only be withdrawn', (tester) async {
    final api = await _pump(
      tester,
      _quote(status: 2, actions: const ['withdraw']),
    );
    expect(find.text('待财务核价'), findsWidgets);
    expect(find.byKey(const ValueKey('sales-doc-edit')), findsNothing);
    api.afterPost = _quote(status: 0, actions: const ['edit', 'submit']);
    await _tapAndConfirm(tester, 'sales-quote-withdraw');
    expect(api.postPaths, contains('/sales/quotes/quote-1/withdraw'));
    expect(api.postBodies['/sales/quotes/quote-1/withdraw'], {
      'expectedRevision': 4,
    });
  });

  testWidgets('returned quote shows the finance reason in banner and header', (
    tester,
  ) async {
    await _pump(
      tester,
      _quote(
        status: 0,
        actions: const ['edit', 'submit', 'delete'],
        extra: const {
          'financeReturnReason': '客户要改数量',
          'financeReturnedByName': '王会计',
          'financeReturnedAt': '2026-09-27T03:00:00Z',
        },
      ),
    );
    expect(find.textContaining('财务退回: 客户要改数量'), findsOneWidget);
    expect(find.text('退回原因'), findsOneWidget);
    expect(find.text('财务退回'), findsWidgets);
    expect(find.byKey(const ValueKey('sales-quote-submit')), findsOneWidget);
  });

  testWidgets('confirmed quote converts to an order draft and reopens', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _quote(
        status: 1,
        actions: const ['convert', 'reopen', 'reverse'],
        extra: const {
          'financeConfirmedByName': '王会计',
          'financeConfirmedAt': '2026-09-27T04:00:00Z',
          'revisions': [
            {
              'revision': 3,
              'action': 'CONFIRM',
              'actorName': '王会计',
              'createdAt': '2026-09-27T04:00:00Z',
            },
          ],
        },
      ),
    );
    expect(find.textContaining('财务已核价，请与客户确认'), findsOneWidget);
    expect(find.text('核价人'), findsOneWidget);
    expect(
      find.byKey(const Key('sales-quote-revision-timeline')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('sales-quote-reopen')), findsOneWidget);
    expect(find.byKey(const ValueKey('sales-quote-reverse')), findsOneWidget);
    // 折扣列(报价与订货同口径)与服务端金额。
    expect(find.text('折扣'), findsOneWidget);
    expect(find.text('190.00'), findsWidgets);

    await _tapAndConfirm(tester, 'sales-quote-convert');
    expect(api.postPaths, contains('/sales/quotes/quote-1/convert'));
    expect(api.postBodies['/sales/quotes/quote-1/convert'], {
      'expectedRevision': 4,
    });
    expect(find.text('order-edit-order-9'), findsOneWidget);
  });

  testWidgets('reopen sends the revision and reloads as draft', (tester) async {
    final api = await _pump(
      tester,
      _quote(status: 1, actions: const ['convert', 'reopen']),
    );
    api.afterPost = _quote(status: 0, actions: const ['edit', 'submit']);
    await _tapAndConfirm(tester, 'sales-quote-reopen');
    expect(api.postPaths, contains('/sales/quotes/quote-1/reopen'));
    expect(api.postBodies['/sales/quotes/quote-1/reopen'], {
      'expectedRevision': 4,
    });
    expect(find.byKey(const ValueKey('sales-quote-submit')), findsOneWidget);
  });

  testWidgets('converted quote links to its order and is otherwise final', (
    tester,
  ) async {
    await _pump(
      tester,
      _quote(
        status: 1,
        extra: const {
          'convertedOrderId': 'order-7',
          'convertedOrderNo': 'XD-7',
        },
      ),
    );
    expect(find.textContaining('已转成订货单 XD-7'), findsOneWidget);
    expect(find.text('已转订货单'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('sales-quote-view-order')));
    await tester.pumpAndSettle();
    expect(find.text('order-order-7'), findsOneWidget);
  });

  testWidgets('finance viewer opens the pricing review from the quote', (
    tester,
  ) async {
    await _pump(
      tester,
      _quote(status: 2, actions: const ['financeReview']),
      permissions: const {Perm.salesQuoteFinanceView},
    );
    await tester.tap(find.byKey(const ValueKey('sales-quote-finance-review')));
    await tester.pumpAndSettle();
    expect(find.text('finance-quote-1'), findsOneWidget);
  });

  testWidgets('voided quote without actions only offers going back', (
    tester,
  ) async {
    await _pump(tester, _quote(status: -1));
    expect(find.textContaining('已作废'), findsOneWidget);
    expect(find.byKey(const ValueKey('sales-quote-back')), findsOneWidget);
    for (final key in [
      'sales-quote-submit',
      'sales-quote-withdraw',
      'sales-quote-convert',
      'sales-quote-reverse',
      'sales-doc-edit',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
  });

  testWidgets('delete asks first and returns to the list', (tester) async {
    final api = await _pump(
      tester,
      _quote(status: 0, actions: const ['edit', 'delete', 'submit']),
    );
    await _tapAndConfirm(tester, 'sales-quote-delete');
    expect(api.deleted, ['/sales/quotes/quote-1']);
    expect(find.text('quote-list'), findsOneWidget);
  });
}
