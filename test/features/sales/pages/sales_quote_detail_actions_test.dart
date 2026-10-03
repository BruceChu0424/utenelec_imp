// 报价详情(ADR-134)：状态横幅 + 按服务端 allowedActions 显示的按钮
// (提交财务核价 / 撤回 / 重新修改 / 转订货单 / 作废 / 去核价)，不再有「审核」；
// 写操作都带 reviewRevision；本地权限码不参与报价按钮显隐。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';

import 'package:uten_imp/shared/providers/session_provider.dart';
import '../../../shared/drafts/memory_form_draft_storage.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
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
  final List<String> getPaths = [];
  Map<String, dynamic>? historyDetail;
  final List<String> postPaths = [];
  final Map<String, Object?> postBodies = {};
  final List<String> deleted = [];
  Map<String, dynamic>? afterPost;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    getPaths.add(path);
    if (path.endsWith('/history')) return historyDetail ?? detail;
    if (path == '/sales/quotes/quote-1' && detail['deleted'] == true) {
      throw ApiException('NOT_FOUND', '销售报价单不存在');
    }
    return detail;
  }

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
  SalesDocType docType = SalesDocType.quote,
  bool historyRead = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final api = _QuoteApi(detail);
  final router = GoRouter(
    initialLocation: '/sales/quotes/quote-1${historyRead ? '?history=1' : ''}',
    routes: [
      GoRoute(
        path: '/sales/quotes',
        builder: (_, _) => const Scaffold(body: Text('quote-list')),
      ),
      GoRoute(
        path: '/sales/quotes/:id',
        builder: (_, state) => SalesDocDetailPage(
          docType: docType,
          id: state.pathParameters['id']!,
          historyRead: state.uri.queryParameters['history'] == '1',
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
        sharedPreferencesProvider.overrideWithValue(preferences),
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
    'deleted first requotation opens through history endpoint and rejects every write capability',
    (tester) async {
      final api = await _pump(
        tester,
        _quote(
          status: 0,
          actions: const [
            'edit',
            'delete',
            'submit',
            'withdraw',
            'reopen',
            'convert',
            'customerConfirm',
            'cancel',
            'requote',
            'financeReview',
          ],
          extra: const {
            'deleted': true,
            'historyReadOnly': false,
            'writable': true,
          },
        ),
        historyRead: true,
        permissions: const {
          Perm.salesQuoteView,
          Perm.salesQuoteEdit,
          Perm.salesQuoteDelete,
          Perm.salesOrderCreate,
          Perm.salesQuoteConvert,
          Perm.salesQuoteFinanceView,
        },
      );
      expect(api.getPaths, contains('/sales/quotes/quote-1/history'));
      expect(api.getPaths, isNot(contains('/sales/quotes/quote-1')));
      expect(find.text('销售报价单历史（只读）'), findsOneWidget);
      expect(find.text('历史记录（只读）'), findsOneWidget);
      for (final key in [
        'sales-doc-edit',
        'sales-quote-delete',
        'sales-quote-submit',
        'sales-quote-withdraw',
        'sales-quote-reopen',
        'sales-quote-convert',
        'sales-quote-customer-confirm',
        'sales-quote-cancel',
        'sales-quote-requote',
        'sales-quote-finance-review',
        'sales-quote-template-download',
        'sales-learning-status',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(api.postPaths, isEmpty);
      expect(find.byKey(const ValueKey('sales-quote-back')), findsOneWidget);
    },
  );

  testWidgets(
    'finance-only permission cannot fetch a sales quotation history',
    (tester) async {
      final api = await _pump(
        tester,
        _quote(status: 0, actions: const ['edit']),
        historyRead: true,
        permissions: const {Perm.salesQuoteFinanceView},
      );
      expect(
        api.getPaths.where((p) => p.startsWith('/sales/quotes/')),
        isEmpty,
      );
      expect(find.text('没有销售报价查看权限，不能查看报价历史'), findsOneWidget);
      expect(find.byKey(const ValueKey('sales-doc-edit')), findsNothing);
    },
  );

  testWidgets(
    'changing the same route from live to history reloads and fences live actions',
    (tester) async {
      final api = await _pump(
        tester,
        _quote(status: 0, actions: const ['edit', 'submit']),
      );
      expect(find.byKey(const ValueKey('sales-doc-edit')), findsOneWidget);
      api.historyDetail = _quote(
        status: 0,
        actions: const ['edit', 'submit'],
        extra: const {'billNo': 'XB-HISTORY'},
      );
      final context = tester.element(find.byType(SalesDocDetailPage));
      GoRouter.of(context).go('/sales/quotes/quote-1?history=1');
      await tester.pumpAndSettle();
      expect(api.getPaths, contains('/sales/quotes/quote-1/history'));
      expect(find.text('XB-HISTORY'), findsWidgets);
      expect(find.byKey(const ValueKey('sales-doc-edit')), findsNothing);
      expect(api.postPaths, isEmpty);
    },
  );

  testWidgets(
    'requote-sealed order remains read-only even if a stale writable flag is true',
    (tester) async {
      await _pump(
        tester,
        _quote(
          status: 1,
          extra: const {
            'stopped': true,
            'requotedToId': 'q-new',
            'readOnlyReason': '原订单重新报价后永久只读',
          },
        ),
        docType: SalesDocType.order,
        permissions: const {
          Perm.salesOrderView,
          Perm.salesOrderEdit,
          Perm.salesOrderStop,
          Perm.salesQuoteView,
        },
      );
      expect(find.text('原订单重新报价后永久只读'), findsOneWidget);
      expect(find.byKey(const ValueKey('sales-doc-edit')), findsNothing);
      expect(find.text('恢复订单'), findsNothing);
      expect(
        find.byKey(const ValueKey('sales-order-view-requote')),
        findsOneWidget,
      );
    },
  );

  testWidgets('requote requires clear acceptance of permanent order sealing', (
    tester,
  ) async {
    final api = await _pump(
      tester,
      _quote(status: 1, actions: const ['requote']),
    );
    await tester.tap(find.byKey(const ValueKey('sales-quote-requote')));
    await tester.pumpAndSettle();
    expect(find.textContaining('永久只读'), findsOneWidget);
    expect(api.postPaths, isEmpty);
    await tester.tap(find.text('返回').last);
    await tester.pumpAndSettle();
    expect(api.postPaths, isEmpty);
  });

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
    // 2026-09-04 起表单错误进字段内 ⓘ 披露（UtenInputDecoration）：
    // 必填校验不再渲染底部错误文本，断言错误图标 + 完整语义标签。
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.bySemanticsLabel('请填写取消原因'), findsOneWidget);
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
