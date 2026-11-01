import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'dart:convert';
import 'dart:io';
import 'package:uten_imp/features/finance/models/sales_order_finance_confirmation.dart';
import 'package:uten_imp/features/finance/models/sales_quote_finance_review.dart';
import 'package:flutter/foundation.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/features/finance/pages/finance_quote_review_page.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_order_review_page.dart';
import 'package:uten_imp/features/sales/pages/sales_manager_review_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';
import '../../helpers/badge_summary_fixture.dart';
import '../../helpers/finance_claim_fixture.dart';

const _capture = bool.fromEnvironment('UTEN_MANAGER_CAPTURE');
bool _fontsLoaded = false;
final _captureKey = GlobalKey();

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'manager',
      employeeId: 'manager-employee',
      code: 'M001',
      name: '销售负责人',
    ),
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <String>[];
  final writes = <({String path, Map<String, dynamic> body})>[];
  bool reverseAvailable = false;
  bool loseReverseResponse = false;
  String? reversalEvidenceMismatch;
  int orderRevision = 7;
  Map<String, dynamic>? reversalDecision;
  bool loseBatchResponse = false;
  bool multiPage = false;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    if (path == '/sales/manager-review') {
      final page = multiPage ? (query?['page'] as int? ?? 1) : 1;
      return {
        'page': page,
        'size': 30,
        'total': multiPage ? 2 : 1,
        'totalPages': multiPage ? 2 : 1,
        'items': [
          {
            'id': 'order-$page',
            'billNo': 'XS-20261031-00$page',
            'billDate': '2026-10-31',
            'clientName': '优腾测试客户',
            'sellerName': '销售员',
            'currencyName': '人民币',
            'totalOriginal': '123456.7891',
            'revision': 6 + page,
            'state': 'PENDING',
          },
        ],
      };
    }
    if (path.endsWith('/quotes/quote-1')) {
      return {
        'id': 'quote-1',
        'billNo': 'BJ-20261031-001',
        'baseCurrency': true,
        'currencyName': '人民币',
        'reviewStage': 'SALES_MANAGER',
        'reviewStatus': 2,
        'reviewStatusBucket': 'PENDING',
        'reviewRevision': 4,
        'totalOriginal': '90',
        'reviewActions': ['edit', 'confirm', 'return'],
        'claimType': 'SALES_QUOTE_MANAGER_REVIEW',
        'pricePendingCount': 0,
        'blockingLineCount': 0,
        'lines': [
          {
            'itemId': 'line-1',
            'lineNo': 1,
            'goodsId': 'goods-1',
            'goodsCode': 'UT-001',
            'goodsName': '测试产品',
            'qty': '10',
            'unitName': '个',
            'listPrice': '10',
            'currentMasterPrice': '10',
            'priceSource': 'MASTER',
            'dealPrice': '9',
            'discount': '0.9',
            'amount': '90',
          },
        ],
        'revisions': <Map<String, dynamic>>[],
      };
    }
    if (path.endsWith('/orders/order-1')) {
      return {
        'orderId': 'order-1',
        'billNo': 'XS-20261031-001',
        'clientName': '测试客户',
        'currencyName': '人民币',
        'totalOriginal': '90',
        'reviewStage': 'SALES_MANAGER',
        'reviewRevision': orderRevision,
        'reviewApproved': reverseAvailable,
        'reviewRejected': false,
        'managerReversible': reverseAvailable,
        'managerDecisions': [if (reversalDecision != null) reversalDecision],
        'items': <Map<String, dynamic>>[],
        'qtyChanges': <Map<String, dynamic>>[],
        'commercialChanges': <Map<String, dynamic>>[],
      };
    }
    return {
      'items': <Map<String, dynamic>>[],
      'total': 0,
      'totalPages': 1,
      'page': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add((
      path: path,
      body: Map<String, dynamic>.from(body as Map? ?? {}),
    ));
    if (loseBatchResponse && path.endsWith('/orders/batch')) {
      throw NetworkTimeoutException();
    }
    if (path.endsWith('/orders/order-1/reverse')) {
      final request = writes.last.body;
      reverseAvailable = false;
      orderRevision++;
      reversalDecision = {
        'decisionId': request['decisionId'],
        'revision': orderRevision,
        'action': 'REVERSED',
        'actorId': 'manager-employee',
        'reason': request['reason'],
      };
      switch (reversalEvidenceMismatch) {
        case 'decisionId':
          reversalDecision!['decisionId'] = 'different-decision';
        case 'revision':
          reversalDecision!['revision'] = orderRevision + 1;
        case 'currentRevision':
          orderRevision -= 2;
        case 'laterRevision':
          orderRevision++;
          reverseAvailable = true;
        case 'actor':
          reversalDecision!['actorId'] = 'other-employee';
        case 'reason':
          reversalDecision!['reason'] = '另一个反审核原因';
        case 'action':
          reversalDecision!['action'] = 'APPROVED';
        case 'absent':
          reversalDecision = null;
      }
      if (loseReverseResponse) throw NetworkTimeoutException();
    }
    return {};
  }
}

Future<FinanceClaimFixture> _pump(
  WidgetTester tester,
  _Api api,
  String route,
  Set<String> permissions, {
  Size size = const Size(1440, 1000),
  bool dark = false,
  double textScale = 1,
}) async {
  if (_capture && !_fontsLoaded) {
    await loadAuditScreenshotFonts(tester);
    _fontsLoaded = true;
  }
  debugDefaultTargetPlatformOverride = size.width >= 800
      ? TargetPlatform.windows
      : TargetPlatform.android;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final claims = FinanceClaimFixture();
  final router = GoRouter(
    initialLocation: route,
    routes: [
      GoRoute(
        path: '/sales/manager-review',
        builder: (_, state) => SalesManagerReviewPage(
          initialKind: state.uri.queryParameters['kind'] ?? 'quote',
        ),
      ),
      GoRoute(
        path: '/sales/manager-review/quotes/:id',
        builder: (_, state) => FinanceQuoteReviewPage(
          id: state.pathParameters['id']!,
          managerReview: true,
        ),
      ),
      GoRoute(
        path: '/sales/manager-review/orders/:id',
        builder: (_, state) => FinanceSalesOrderReviewPage(
          id: state.pathParameters['id']!,
          managerReview: true,
          returnTo: '/sales/manager-review?kind=order',
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('http://localhost:8080/api'),
        sessionProvider.overrideWith(_Session.new),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(),
        taskClaimRepositoryProvider.overrideWithValue(claims),
      ],
      child: RepaintBoundary(
        key: _captureKey,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: _capture
              ? auditScreenshotTheme(buildLightTheme())
              : buildLightTheme(),
          darkTheme: _capture
              ? auditScreenshotTheme(buildDarkTheme())
              : buildDarkTheme(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          routerConfig: router,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return claims;
}

void main() {
  test(
    'shared management contract preserves stage and exact price provenance',
    () {
      final fixture =
          jsonDecode(
                File(
                  'contracts/sales-manager-review/v1.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final quoteJson = Map<String, dynamic>.from(fixture['quote'] as Map);
      final quote = SalesQuoteFinanceReview.fromJson(quoteJson);
      expect(quote.claimType, 'SALES_QUOTE_MANAGER_REVIEW');
      expect(quote.reviewRevision, 4);
      expect(quote.lines.single.priceSource, QuotePriceSource.manager);
      expect(quote.lines.single.isReviewerPriced, isTrue);
      expect(quote.lines.single.isFinancePriced, isFalse);
      expect(quote.lines.single.storedPrice, '12.1234');
      expect(quoteJson.containsKey('financeConfirmedAt'), isFalse);
      final orderJson = Map<String, dynamic>.from(fixture['order'] as Map);
      final order = SalesOrderFinanceReview.fromJson(orderJson);
      expect(
        order.financeConfirmed,
        isTrue,
      ); // Shared renderer decision; transport explicitly names management approval.
      expect(order.financeReviewRevision, 8);
      expect(order.managerDecisionClaimId, isNotNull);
      expect(orderJson.containsKey('financeConfirmed'), isFalse);
    },
  );
  test('management routes require their own permissions', () {
    expect(requiredAnyPermFor('/sales/manager-review'), [
      Perm.salesQuoteManagerView,
      Perm.salesOrderManagerView,
    ]);
    expect(requiredAnyPermFor('/sales/manager-review/quotes/one'), [
      Perm.salesQuoteManagerView,
    ]);
    expect(requiredAnyPermFor('/sales/manager-review/orders/one'), [
      Perm.salesOrderManagerView,
    ]);
  });
  testWidgets(
    'quote manager uses independent lease and does not require finance permissions',
    (tester) async {
      final api = _Api();
      final claims =
          await _pump(tester, api, '/sales/manager-review/quotes/quote-1', {
            Perm.salesQuoteManagerView,
            Perm.salesQuoteManagerConfirm,
            Perm.salesQuoteManagerReject,
          });
      expect(find.text('销售负责人报价审核'), findsOneWidget);
      expect(
        claims.leases['quote-1']?.targetType,
        'SALES_QUOTE_MANAGER_REVIEW',
      );
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('quote-finance-confirm')))
            .onPressed,
        isNotNull,
      );
      expect(
        api.reads.where((path) => path.contains('finance-review')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      if (_capture) {
        await saveAuditScreenshot(tester, _captureKey, 'manager-quote-review');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets('reject-only order reviewer can reject but cannot approve', (
    tester,
  ) async {
    final api = _Api();
    final claims = await _pump(
      tester,
      api,
      '/sales/manager-review/orders/order-1',
      {Perm.salesOrderManagerView, Perm.salesOrderManagerReject},
    );
    expect(claims.leases['order-1']?.targetType, 'SALES_ORDER_MANAGER_REVIEW');
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('finance-review-reject')))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('finance-review-confirm')))
          .onPressed,
      isNull,
    );
    expect(find.text('销售负责人订货审核'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
    'manager reversal is a separate action from sales document unapproval',
    (tester) async {
      final api = _Api()..reverseAvailable = true;
      await _pump(tester, api, '/sales/manager-review/orders/order-1', {
        Perm.salesOrderManagerView,
        Perm.salesOrderManagerReverse,
      });
      expect(
        find.byKey(const Key('sales-manager-order-reverse')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('finance-sales-order-unapprove')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  for (final mismatch in <String?>[
    null,
    'decisionId',
    'revision',
    'currentRevision',
    'laterRevision',
    'actor',
    'reason',
    'action',
    'absent',
  ]) {
    testWidgets(
      'lost reversal response requires the exact immutable decision: $mismatch',
      (tester) async {
        final api = _Api()
          ..reverseAvailable = true
          ..loseReverseResponse = true
          ..reversalEvidenceMismatch = mismatch;
        await _pump(tester, api, '/sales/manager-review/orders/order-1', {
          Perm.salesOrderManagerView,
          Perm.salesOrderManagerReverse,
        });
        await tester.tap(find.byKey(const Key('sales-manager-order-reverse')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, '反审核原因'),
          '重新核对交期',
        );
        await tester.tap(find.text('确认反审核'));
        await tester.pumpAndSettle();
        expect(
          api.writes.single.path,
          '/sales/manager-review/orders/order-1/reverse',
        );
        expect(api.writes.single.body, containsPair('expectedRevision', 7));
        expect(
          api.writes.single.body['decisionId'],
          matches(RegExp(r'^[0-9a-f-]{36}$')),
        );
        expect(find.textContaining('结果尚未确认'), findsWidgets);
        await tester.tap(
          find.byKey(const Key('review-task-draft-read-recovery')),
        );
        await tester.pumpAndSettle();
        if (mismatch == null || mismatch == 'laterRevision') {
          expect(find.text('订单审核'), findsOneWidget);
          expect(find.textContaining('结果尚未确认'), findsNothing);
        } else {
          expect(find.textContaining('结果尚未确认'), findsWidgets);
          await tester.tap(
            find.byKey(const Key('review-task-draft-read-recovery')),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('结果尚未确认'), findsWidgets);
        }
        expect(api.writes, hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
  testWidgets(
    'quote approval submits the manager version and lease to the manager endpoint',
    (tester) async {
      final api = _Api();
      final claims = await _pump(
        tester,
        api,
        '/sales/manager-review/quotes/quote-1',
        {Perm.salesQuoteManagerView, Perm.salesQuoteManagerConfirm},
      );
      final lease = claims.leases['quote-1']!.claimId;
      await tester.tap(find.byKey(const Key('quote-finance-confirm')));
      await tester.pumpAndSettle();
      expect(find.textContaining('批准后转交财务核价'), findsOneWidget);
      await tester.tap(find.byKey(const Key('quote-finance-confirm-submit')));
      await tester.pumpAndSettle();
      expect(
        api.writes.single.path,
        '/sales/manager-review/quotes/quote-1/confirm',
      );
      expect(api.writes.single.body, {
        'expectedRevision': 4,
        'expectedClaimId': lease,
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets('reject-only manager submits a reason with the order lease', (
    tester,
  ) async {
    final api = _Api();
    final claims = await _pump(
      tester,
      api,
      '/sales/manager-review/orders/order-1',
      {Perm.salesOrderManagerView, Perm.salesOrderManagerReject},
    );
    final lease = claims.leases['order-1']!.claimId;
    await tester.tap(find.byKey(const Key('finance-review-reject')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('finance-review-reject-reason')),
      '数量需核对',
    );
    await tester.tap(find.byKey(const Key('finance-review-reject-submit')));
    await tester.pumpAndSettle();
    expect(
      api.writes.single.path,
      '/sales/manager-review/orders/order-1/reject',
    );
    expect(api.writes.single.body, {
      'expectedRevision': 7,
      'expectedClaimId': lease,
      'reason': '数量需核对',
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
    'batch review includes selected orders on previous pages and their shown versions',
    (tester) async {
      final api = _Api()..multiPage = true;
      await _pump(tester, api, '/sales/manager-review?kind=order', {
        Perm.salesOrderManagerView,
        Perm.salesOrderManagerConfirm,
      });
      MasterDataTableView<SalesManagerReviewTask> table() =>
          tester.widget<MasterDataTableView<SalesManagerReviewTask>>(
            find.byType(MasterDataTableView<SalesManagerReviewTask>),
          );
      table().onSelectedIdsChanged!({'order-1'});
      await tester.pump();
      table().onPageChange!(2);
      await tester.pumpAndSettle();
      expect(table().selectedIds, contains('order-1'));
      table().onSelectedIdsChanged!({'order-1', 'order-2'});
      await tester.pump();
      await tester.tap(find.text('批量批准 (2)'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('manager-batch-remark')),
        '两页订单已核对',
      );
      await tester.tap(find.text('批准并转交财务'));
      await tester.pumpAndSettle();
      expect(api.writes.single.body['orderIds'], ['order-1', 'order-2']);
      expect(api.writes.single.body['expectedRevisions'], {
        'order-1': 7,
        'order-2': 8,
      });
      expect(api.writes.single.body['remark'], '两页订单已核对');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'unknown batch result stays fenced after refresh and is not replayed',
    (tester) async {
      final api = _Api()..loseBatchResponse = true;
      await _pump(tester, api, '/sales/manager-review?kind=order', {
        Perm.salesOrderManagerView,
        Perm.salesOrderManagerConfirm,
      });
      final table = tester.widget<MasterDataTableView<SalesManagerReviewTask>>(
        find.byType(MasterDataTableView<SalesManagerReviewTask>),
      );
      table.onSelectedIdsChanged!({'order-1'});
      await tester.pump();
      await tester.tap(find.text('批量批准 (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批准并转交财务'));
      await tester.pumpAndSettle();
      expect(api.writes.single.path, '/sales/manager-review/orders/batch');
      expect(api.writes.single.body['expectedRevisions'], {'order-1': 7});
      expect(find.textContaining('提交结果尚未确认'), findsWidgets);
      await tester.tap(
        find.byKey(const Key('review-task-draft-read-recovery')),
      );
      await tester.pumpAndSettle();
      expect(api.reads, contains('/sales/manager-review/orders/order-1'));
      final refreshed = tester
          .widget<MasterDataTableView<SalesManagerReviewTask>>(
            find.byType(MasterDataTableView<SalesManagerReviewTask>),
          );
      refreshed.onSelectedIdsChanged!({'order-1'});
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '批量批准 (1)'))
            .onPressed,
        isNull,
      );
      expect(api.writes, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  for (final setting in [
    (size: const Size(1440, 1000), dark: false, scale: 1.0),
    (size: const Size(1440, 1000), dark: true, scale: 1.0),
    (size: const Size(430, 900), dark: false, scale: 1.3),
  ]) {
    final size = setting.size;
    testWidgets(
      'queue retains exact amounts and visible stage at $size dark=${setting.dark}',
      (tester) async {
        await _pump(
          tester,
          _Api(),
          '/sales/manager-review?kind=order',
          {Perm.salesOrderManagerView},
          size: size,
          dark: setting.dark,
          textScale: setting.scale,
        );
        expect(find.text('订单审核'), findsOneWidget);
        expect(find.textContaining('123456.7891'), findsWidgets);
        expect(find.text('报价单'), findsNothing);
        expect(tester.takeException(), isNull);
        if (_capture) {
          await saveAuditScreenshot(
            tester,
            _captureKey,
            'manager-queue-${size.width.toInt()}-${setting.dark ? 'dark' : 'light'}',
          );
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
