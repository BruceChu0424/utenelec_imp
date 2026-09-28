// AI 程序业务界面截图: 识别核对面板 / 编辑页导入后 / 报价核价队列与详情 / 报价详情状态 /
// 客户货品对照 / 货品英文名称。由 ai_program_visual_review_test.dart 调用。
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/client_goods_alias_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/client_goods_alias_tab.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_name_en_field.dart';
import 'package:uten_imp/features/finance/pages/finance_quote_review_list_page.dart';
import 'package:uten_imp/features/finance/pages/finance_quote_review_page.dart';
import 'package:uten_imp/features/finance/repositories/sales_quote_finance_review_repository.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_launcher.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_models.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_repository.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_review_panel.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_detail_page.dart';
import 'package:uten_imp/features/sales/pages/sales_doc_edit_page.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/ai/ai_status_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../helpers/finance_claim_fixture.dart';
import '../sales/intake/sales_intake_test_support.dart';
import 'ai_visual_business_fakes.dart';
import 'ai_visual_support.dart';

// ---------------------------------------------------------------- 识别核对面板

Future<void> _pumpPanel(
  WidgetTester tester, {
  required SalesDocType docType,
  Map<String, dynamic>? json,
  Size size = kDesktop,
  bool dark = false,
  bool canHandoffToQuote = true,
}) async {
  await setCaptureView(tester, size);
  final result = SalesIntakeResult.fromJson(json ?? sampleIntakeResult());
  final actions = SalesIntakeReviewActions(
    pickClient: (_) async => null,
    pickGoods: (_) async => null,
    createClient: (_, _) async => null,
    canHandoffToQuote: canHandoffToQuote,
  );
  await tester.pumpWidget(
    captureApp(
      dark: dark,
      overrides: await baseOverrides(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showSalesIntakeReviewPanel(
                context,
                result: result,
                docType: docType,
                actions: actions,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _scrollPanel(WidgetTester tester, double dy) async {
  await tester.drag(
    find.byKey(const ValueKey('sales-intake-review-scroll')),
    Offset(0, -dy),
  );
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------- 编辑页

Future<void> _pumpEditAfterIntake(
  WidgetTester tester, {
  required SalesDocType docType,
  Size size = const Size(1440, 900),
}) async {
  await setCaptureView(tester, size);
  final api = IntakeEditApi();
  final runner = FakeAiJobRunner(result: sampleIntakeResult());
  await tester.pumpWidget(
    captureRouterApp(
      overrides: [
        ...await baseOverrides(),
        apiClientProvider.overrideWithValue(api),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(api),
        ),
        sessionProvider.overrideWith(VisualSession.new),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.salesQuoteView,
          Perm.salesQuoteCreate,
          Perm.salesQuoteEdit,
          Perm.salesOrderView,
          Perm.salesOrderCreate,
          Perm.salesOrderEdit,
          Perm.salesOrderPriceView,
        }),
        aiJobRunnerProvider.overrideWithValue(runner),
        salesIntakeProgressPresenterProvider.overrideWithValue(
          presenterOf(FakeProgressPresenter()),
        ),
        aiStatusProvider.overrideWith((ref) async => AiStatus.unavailable),
        salesIntakeRepositoryProvider.overrideWithValue(
          FakeSalesIntakeRepository(),
        ),
        salesGridGoodsPickerProvider.overrideWithValue((_, _) async => []),
      ],
      router: GoRouter(
        initialLocation: '/edit',
        routes: [
          GoRoute(
            path: '/edit',
            builder: (_, _) => SalesDocEditPage(docType: docType),
          ),
          GoRoute(
            path: '/:rest(.*)',
            builder: (_, _) => const SizedBox.shrink(),
          ),
        ],
      ),
      builder: (context, child) => Stack(
        children: [
          Positioned.fill(child: child!),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AppNotificationHost(),
          ),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 把页面里所有横向滚动的表格滚到最右。
void _scrollGridsToEnd(WidgetTester tester) {
  for (final element
      in find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
          )
          .evaluate()) {
    final scrollable = (element as StatefulElement).state as ScrollableState;
    if (scrollable.position.maxScrollExtent > 0) {
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    }
  }
}

// ---------------------------------------------------------------- 报价核价

List<Override> _financeOverrides(FinanceClaimFixture claims) => [
  isSuperAdminProvider.overrideWithValue(false),
  currentPermissionsProvider.overrideWithValue(const {
    Perm.salesQuoteFinanceView,
    Perm.salesQuoteFinanceConfirm,
  }),
  sessionProvider.overrideWith(() => VisualSession(name: '王会计')),
  salesQuoteFinanceReviewRepositoryProvider.overrideWithValue(
    QuoteReviewRepo(),
  ),
  taskClaimRepositoryProvider.overrideWithValue(claims),
  salesMasterNameServiceProvider.overrideWithValue(
    SalesMasterNameService(FinanceDictApi()),
  ),
];

void businessScreenTests() {
  group('识别核对面板', () {
    testWidgets('order: blocked guidance + step 1 + step 2 header', (
      tester,
    ) async {
      await _pumpPanel(tester, docType: SalesDocType.order);
      await capture(tester, 'intake-order-top-1440-light');
      await _scrollPanel(tester, 420);
      await capture(tester, 'intake-order-goods-1440-light');
    }, skip: !kCaptureUi);

    testWidgets('quote: step 1 client + goods needing review', (tester) async {
      await _pumpPanel(tester, docType: SalesDocType.quote);
      await capture(tester, 'intake-quote-top-1440-light');
      await _scrollPanel(tester, 500);
      await capture(tester, 'intake-quote-goods-1440-light');
    }, skip: !kCaptureUi);

    testWidgets('quote: expand auto-matched rows', (tester) async {
      await _pumpPanel(tester, docType: SalesDocType.quote);
      final toggle = find.byKey(const ValueKey('sales-intake-matched-toggle'));
      await tester.scrollUntilVisible(
        toggle,
        400,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('sales-intake-review-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await _scrollPanel(tester, 300);
      await capture(tester, 'intake-quote-matched-expanded-1440-light');
    }, skip: !kCaptureUi);

    testWidgets('quote: filter all', (tester) async {
      await _pumpPanel(tester, docType: SalesDocType.quote);
      final l10n = lookupAppLocalizations(const Locale('zh'));
      await tester.tap(find.text(l10n.salesIntakeFilterAll(38)));
      await tester.pumpAndSettle();
      await _scrollPanel(tester, 380);
      await capture(tester, 'intake-quote-filter-all-1440-light');
    }, skip: !kCaptureUi);

    testWidgets('client not matched', (tester) async {
      await _pumpPanel(
        tester,
        docType: SalesDocType.quote,
        json: sampleIntakeResultClientUnmatched(),
      );
      await capture(tester, 'intake-client-unmatched-1440-light');
    }, skip: !kCaptureUi);

    testWidgets('dark', (tester) async {
      await _pumpPanel(tester, docType: SalesDocType.order, dark: true);
      await capture(tester, 'intake-order-top-1440-dark');
      await _scrollPanel(tester, 420);
      await capture(tester, 'intake-order-goods-1440-dark');
    }, skip: !kCaptureUi);

    testWidgets('mobile', (tester) async {
      await _pumpPanel(tester, docType: SalesDocType.order, size: kMobile);
      await capture(tester, 'intake-order-top-390-light');
      await _scrollPanel(tester, 700);
      await capture(tester, 'intake-order-goods-390-light');
    }, skip: !kCaptureUi);
  });

  group('编辑页导入后', () {
    testWidgets('quote edit page after intake', (tester) async {
      await _pumpEditAfterIntake(tester, docType: SalesDocType.quote);
      await capture(tester, 'edit-quote-before-intake-1440-light');
      FilePicker.platform = FakeFilePicker(
        fakeFile('ALPHA(2026-1-19+2026-2-24)260422.xlsx'),
      );
      await tester.tap(find.byKey(const ValueKey('sales-intake-entry-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
      await tester.pumpAndSettle();
      // 通知条自动消失后再截。
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      await capture(tester, 'edit-quote-after-intake-1440-light');
      final grid = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'sales-goods-ai-review-',
            ),
      );
      if (grid.evaluate().isNotEmpty) {
        await tester.ensureVisible(grid.first);
        await tester.pumpAndSettle();
      } else {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -420));
        await tester.pumpAndSettle();
      }
      await capture(tester, 'edit-quote-grid-1440-light');
      // 表格横向滚到最右, 看文件单价/单价/折扣几列。
      _scrollGridsToEnd(tester);
      await tester.pumpAndSettle();
      await capture(tester, 'edit-quote-grid-right-1440-light');
    }, skip: !kCaptureUi);
  });

  group('报价核价', () {
    testWidgets('queue', (tester) async {
      await setCaptureView(tester, kDesktop);
      final router = GoRouter(
        initialLocation: '/finance/quote-review',
        routes: [
          GoRoute(
            path: '/finance/quote-review',
            builder: (_, _) => const FinanceQuoteReviewListPage(),
          ),
          GoRoute(
            path: '/finance/quote-review/:id',
            builder: (_, _) => const Scaffold(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        captureRouterApp(
          router: router,
          overrides: [
            ...await baseOverrides(),
            ..._financeOverrides(FinanceClaimFixture()),
            fixedBadgeSummaryOverride(
              badgeSummaryFixture(
                entries: {BadgeEntry.financeQuoteReview: (3, 0)},
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await capture(tester, 'finance-quote-queue-1440-light');
    }, skip: !kCaptureUi);

    for (final (size, dark, name) in [
      (kDesktop, false, 'finance-quote-review-1440-light'),
      (kDesktop, true, 'finance-quote-review-1440-dark'),
      (kMobile, false, 'finance-quote-review-390-light'),
    ]) {
      testWidgets(name, (tester) async {
        await setCaptureView(tester, size);
        final router = GoRouter(
          initialLocation: '/finance/quote-review/quote-1',
          routes: [
            GoRoute(
              path: '/finance/quote-review',
              builder: (_, _) => const Scaffold(),
            ),
            GoRoute(
              path: '/finance/quote-review/:id',
              builder: (_, state) =>
                  FinanceQuoteReviewPage(id: state.pathParameters['id']!),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          captureRouterApp(
            dark: dark,
            router: router,
            overrides: [
              ...await baseOverrides(),
              ..._financeOverrides(FinanceClaimFixture()),
              fixedBadgeSummaryOverride(),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await capture(tester, name);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
        await tester.pumpAndSettle();
        await capture(tester, '$name-scrolled');
        if (size == kDesktop && !dark) {
          _scrollGridsToEnd(tester);
          await tester.pumpAndSettle();
          await capture(tester, '$name-right');
        }
      }, skip: !kCaptureUi);
    }
  });

  group('报价详情状态', () {
    for (final (label, status, actions, extra) in [
      (
        'pending',
        2,
        const ['withdraw'],
        const <String, dynamic>{
          'submittedByName': '张销售',
          'submittedAt': '2026-09-27T07:40:00Z',
        },
      ),
      (
        'returned',
        0,
        const ['edit', 'submit', 'delete'],
        const <String, dynamic>{
          'financeReturnReason': '空白面板客户价低于标价太多, 请和客户确认',
          'financeReturnedByName': '王会计',
          'financeReturnedAt': '2026-09-27T05:20:00Z',
        },
      ),
      (
        'confirmed',
        1,
        const ['convert', 'reopen', 'reverse'],
        const <String, dynamic>{
          'financeConfirmedByName': '王会计',
          'financeConfirmedAt': '2026-09-27T08:00:00Z',
          'revisions': [
            {
              'revision': 5,
              'action': 'CONFIRM',
              'actorName': '王会计',
              'createdAt': '2026-09-27T08:00:00Z',
            },
            {
              'revision': 4,
              'action': 'SUBMIT',
              'actorName': '张销售',
              'createdAt': '2026-09-27T07:40:00Z',
            },
            {
              'revision': 3,
              'action': 'RETURN',
              'actorName': '王会计',
              'reason': '空白面板客户价低于标价太多, 请和客户确认',
              'createdAt': '2026-09-27T05:20:00Z',
            },
          ],
        },
      ),
    ]) {
      testWidgets('quote detail $label', (tester) async {
        await setCaptureView(tester, kDesktop);
        final api = QuoteDetailApi(
          quoteDetailJson(status: status, actions: actions, extra: extra),
        );
        final router = GoRouter(
          initialLocation: '/sales/quotes/quote-1',
          routes: [
            GoRoute(path: '/sales/quotes', builder: (_, _) => const Scaffold()),
            GoRoute(
              path: '/sales/quotes/:id',
              builder: (_, state) => SalesDocDetailPage(
                docType: SalesDocType.quote,
                id: state.pathParameters['id']!,
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          captureRouterApp(
            router: router,
            overrides: [
              ...await baseOverrides(),
              apiClientProvider.overrideWithValue(api),
              salesMasterNameServiceProvider.overrideWithValue(
                SalesMasterNameService(api),
              ),
              currentPermissionsProvider.overrideWithValue(const {
                Perm.salesQuoteView,
              }),
              isSuperAdminProvider.overrideWithValue(false),
              fixedBadgeSummaryOverride(),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await capture(tester, 'quote-detail-$label-1440-light');
      }, skip: !kCaptureUi);
    }
  });

  group('客户货品对照 / 货品英文名称', () {
    for (final (empty, name) in [
      (false, 'client-goods-alias-1440-light'),
      (true, 'client-goods-alias-empty-1440-light'),
    ]) {
      testWidgets(name, (tester) async {
        await setCaptureView(tester, kDesktop);
        await tester.pumpWidget(
          captureApp(
            overrides: [
              ...await baseOverrides(),
              clientGoodsAliasRepositoryProvider.overrideWithValue(
                AliasRepo(empty: empty),
              ),
            ],
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(24),
                child: ClientGoodsAliasTab(clientId: 'client-1'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await capture(tester, name);
      }, skip: !kCaptureUi);
    }

    testWidgets('goods English name cell + dialog', (tester) async {
      await setCaptureView(tester, kDesktop);
      final detail = GoodsDetail.fromJson(const {
        'id': 'goods-1',
        'code': '280235165',
        'name': 'Z9 146型二开多功能三孔(带灯)',
        'colorName': '白色',
        'nameEn': '2 GANG 2 WAY SWITCH + 3 PIN SOCKET',
        'nameEnSource': 'LEARNED',
        'version': 3,
        'canEditNameEn': true,
      });
      await tester.pumpWidget(
        captureApp(
          overrides: await baseOverrides(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 520,
                      child: GoodsNameEnViewCell(
                        nameEn: detail.nameEn,
                        learned: true,
                        onEdit: () =>
                            showGoodsNameEnDialog(context, detail: detail),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const SizedBox(
                      width: 520,
                      child: GoodsNameEnViewCell(nameEn: null, learned: false),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await capture(tester, 'goods-name-en-cell-1440-light');
      await tester.tap(find.byKey(const ValueKey('goods-name-en-edit')));
      await tester.pumpAndSettle();
      await capture(tester, 'goods-name-en-dialog-1440-light');
    }, skip: !kCaptureUi);
  });
}
