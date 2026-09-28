// 销售订单财务审核页的来源报价条带(ADR-134)：报价转入的订单显示「来源报价 · 报价已核价 ·
// 一致 / 有 N 行和报价不同」，明细多出报价单价/报价折扣/与报价，以及客户文件三列；
// 非报价转入的老订单不出现这些内容(也不要求本地化实例)。列表状态列在一致时加注。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/models/sales_order_finance_confirmation.dart';
import 'package:uten_imp/features/finance/pages/finance_sales_order_review_page.dart';
import 'package:uten_imp/features/finance/repositories/sales_order_finance_confirmation_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/repositories/task_claim_repository.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../helpers/finance_claim_fixture.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(id: 'finance-user', code: 'FIN001', name: '财务审核员'),
  );
}

class _Repo implements SalesOrderFinanceConfirmationRepository {
  _Repo(this.value);
  final SalesOrderFinanceReview value;

  @override
  Future<SalesOrderFinanceReview> review(String orderId) async => value;

  @override
  Future<SalesOrderFinancePendingPage> pending({
    int page = 1,
    int size = 20,
    bool? rejected,
    String? keyword,
    bool? changesOnly,
    String? sort,
    String? order,
    String? billNo,
  }) async => const SalesOrderFinancePendingPage(
    items: [],
    page: 1,
    size: 20,
    total: 0,
    totalPages: 1,
  );

  @override
  Future<List<MasterFacetBucket>> billNoFacets({
    bool? rejected,
    String? keyword,
    bool? changesOnly,
  }) async => const [];

  @override
  Future<int> pendingCount({bool? changesOnly}) async => 0;

  @override
  Future<void> confirm(
    String orderId, {
    String? remark,
    int? expectedRevision,
    String? expectedClaimId,
  }) async {}

  @override
  Future<void> confirmBatch(
    Iterable<String> orderIds, {
    String? remark,
    Map<String, int>? expectedRevisions,
    Map<String, String>? expectedClaimIds,
  }) async {}

  @override
  Future<void> reject(
    String orderId, {
    required String reason,
    int? expectedRevision,
    String? expectedClaimId,
  }) async {}
}

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> json, {
  bool localized = true,
}) async {
  tester.view.physicalSize = const Size(2400, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final review = SalesOrderFinanceReview.fromJson(json);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.salesOrderFinanceView,
          Perm.salesOrderFinanceConfirm,
        }),
        sessionProvider.overrideWith(_Session.new),
        fixedBadgeSummaryOverride(),
        salesOrderFinanceConfirmationRepositoryProvider.overrideWithValue(
          _Repo(review),
        ),
        taskClaimRepositoryProvider.overrideWithValue(FinanceClaimFixture()),
      ],
      child: localized
          ? MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('zh'),
              home: FinanceSalesOrderReviewPage(id: review.orderId),
            )
          : MaterialApp(home: FinanceSalesOrderReviewPage(id: review.orderId)),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> _order({
  Map<String, dynamic>? sourceQuote,
  bool? matchesQuote,
  List<Map<String, dynamic>>? items,
}) => {
  'orderId': 'order-1',
  'billNo': 'XD-001',
  'currencyName': '人民币',
  'totalOriginal': '380',
  'financeReviewRevision': 1,
  'sourceQuote': ?sourceQuote,
  'matchesQuote': ?matchesQuote,
  'clientFileCurrency': 'USD',
  'items':
      items ??
      [
        {
          'itemId': 'line-1',
          'goodsName': '台灯',
          'qty': '4',
          'price': '100',
          'discount': '0.95',
          'amountOriginal': '380',
        },
      ],
};

List<String> _columnKeys(WidgetTester tester) => tester
    .widget<MasterDataTableView<SalesOrderFinanceReviewLine>>(
      find.byWidgetPredicate(
        (w) => w is MasterDataTableView<SalesOrderFinanceReviewLine>,
      ),
    )
    .columns
    .map((c) => c.key)
    .toList();

void main() {
  testWidgets('quote-derived order shows the priced-quote strip and columns', (
    tester,
  ) async {
    await _pump(
      tester,
      _order(
        sourceQuote: const {
          'id': 'quote-1',
          'billNo': 'XB-001',
          'financeConfirmedByName': '王会计',
          'financeConfirmedAt': '2026-09-27T04:00:00Z',
        },
        matchesQuote: true,
        items: const [
          {
            'itemId': 'line-1',
            'goodsName': '台灯',
            'qty': '4',
            'price': '100',
            'discount': '0.95',
            'amountOriginal': '380',
            'quotePrice': '100',
            'quoteDiscount': '0.95',
            'matchesQuote': true,
            'clientPrice': '13.2',
            'clientModel': 'LX-1',
            'clientGoodsName': 'DESK LAMP',
          },
        ],
      ),
    );
    expect(
      find.byKey(const Key('finance-review-source-quote')),
      findsOneWidget,
    );
    expect(find.text('来源报价 XB-001'), findsOneWidget);
    expect(find.textContaining('报价已核价 · 王会计'), findsOneWidget);
    expect(find.text('报价已核价 · 一致'), findsOneWidget);
    expect(
      _columnKeys(tester),
      containsAll(<String>[
        'quotePrice',
        'quoteDiscount',
        'matchesQuote',
        'clientPrice',
        'clientModel',
        'clientGoodsName',
      ]),
    );
    expect(find.text('文件单价(USD)'), findsOneWidget);
    expect(find.text('LX-1'), findsOneWidget);
  });

  testWidgets('lines that differ from the quote are counted and flagged', (
    tester,
  ) async {
    await _pump(
      tester,
      _order(
        sourceQuote: const {'id': 'quote-1', 'billNo': 'XB-001'},
        items: const [
          {
            'itemId': 'line-1',
            'goodsName': '台灯',
            'qty': '4',
            'price': '100',
            'discount': '0.9',
            'quotePrice': '100',
            'quoteDiscount': '0.95',
            'matchesQuote': false,
          },
          {
            'itemId': 'line-2',
            'goodsName': '灯罩',
            'qty': '1',
            'price': '10',
            'discount': '1',
            'quotePrice': '10',
            'quoteDiscount': '1',
            'matchesQuote': true,
          },
        ],
      ),
    );
    expect(find.text('有 1 行和报价不同'), findsOneWidget);
    expect(find.text('不同'), findsOneWidget);
    expect(find.text('一致'), findsOneWidget);
  });

  testWidgets('legacy orders keep the original view without localization', (
    tester,
  ) async {
    await _pump(tester, _order(), localized: false);
    expect(find.byKey(const Key('finance-review-source-quote')), findsNothing);
    expect(_columnKeys(tester), isNot(contains('quotePrice')));
    expect(_columnKeys(tester), isNot(contains('clientPrice')));
    expect(tester.takeException(), isNull);
  });

  test('list item parses the source quote and its all-lines-match flag', () {
    // 契约：列表行与审核详情同一个 sourceQuote 形状(服务端 SalesOrderFinanceReviewDto.SourceQuote)。
    final item = SalesOrderFinancePendingItem.fromJson(const {
      'orderId': 'order-1',
      'billNo': 'XD-001',
      'sourceQuote': {
        'id': 'quote-1',
        'billNo': 'XB-001',
        'allLinesMatch': true,
      },
    });
    expect(item.sourceQuote?.billNo, 'XB-001');
    expect(item.matchesQuote, isTrue);
    final legacy = SalesOrderFinancePendingItem.fromJson(const {
      'orderId': 'order-2',
      'billNo': 'XD-002',
    });
    expect(legacy.sourceQuote, isNull);
    expect(legacy.matchesQuote, isNull);
  });

  test('top-level matchesQuote wins over sourceQuote.allLinesMatch', () {
    // 契约：服务端把「全部行一致」放在同级 matchesQuote(sourceQuote 只带
    // id/billNo/核价人/核价时间); 列表行与审核详情同口径。
    final item = SalesOrderFinancePendingItem.fromJson(const {
      'orderId': 'order-1',
      'billNo': 'XD-001',
      'sourceQuote': {
        'id': 'quote-1',
        'billNo': 'XB-001',
        'financeConfirmedByName': '王会计',
        'financeConfirmedAt': '2026-09-27T04:00:00Z',
      },
      'matchesQuote': true,
    });
    expect(item.sourceQuote?.financeConfirmedByName, '王会计');
    expect(item.matchesQuote, isTrue);
    final mixed = SalesOrderFinancePendingItem.fromJson(const {
      'orderId': 'order-2',
      'billNo': 'XD-002',
      'sourceQuote': {'id': 'quote-2', 'allLinesMatch': true},
      'matchesQuote': false,
    });
    expect(mixed.matchesQuote, isFalse);
    final review = SalesOrderFinanceReview.fromJson(
      _order(
        sourceQuote: const {'id': 'quote-1', 'billNo': 'XB-001'},
        matchesQuote: true,
      ),
    );
    expect(review.matchesQuote, isTrue);
    final orphan = SalesOrderFinancePendingItem.fromJson(const {
      'orderId': 'order-3',
      'billNo': 'XD-003',
      'matchesQuote': true,
    });
    expect(orphan.matchesQuote, isNull);
  });
}
