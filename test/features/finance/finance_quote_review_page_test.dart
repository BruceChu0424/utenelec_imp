// 报价核价详情(ADR-134)：认领闸门(撤销确认不认领)、成交单价 ↔ 折扣联动、高于标价自动转财务定价、
// 没有标价的财务定价与赠品/0价、按最新标价刷新、勾选行批量设折扣、保存请求(表头整体状态 + 行四选一)、
// 填错的行挡保存/确认、退回原因(服务端字段 text)、确认前的未定价拦截、去货品资料回来后重读。
// 夹具 JSON 与服务端 QuoteFinanceReviewDto / QuoteFinanceEditRequest 等 record 字段逐字一致；
// 假仓库记录的是真实请求体(quoteFinanceEditBody / quoteFinanceDecisionBody)。
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/finance/models/quote_finance_pricing.dart';
import 'package:uten_imp/features/finance/models/sales_quote_finance_review.dart';
import 'package:uten_imp/features/finance/pages/finance_quote_review_page.dart';
import 'package:uten_imp/features/finance/repositories/sales_quote_finance_review_repository.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/task_claim_view.dart';
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

class _DictApi extends ApiClient {
  _DictApi() : super(Dio());

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [
    {'id': 'settle-1', 'name': '月结30天'},
    {'id': 'settle-2', 'name': '款到发货'},
  ];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {};
}

/// 服务端 QuoteFinanceReviewDto.Line：listPrice = 本行已存单价(财务定价行是财务价)，
/// dealPrice = 单价 × 折扣，amount = 数量 × 单价 × 折扣。
Map<String, dynamic> _line(
  String id, {
  String? stored = '100',
  String? currentMaster = '100',
  String priceSource = 'MASTER',
  String discount = '1',
  String qty = '2',
  String? clientPrice,
  String? lastConfirmed,
}) {
  final rate = priceSource == 'FINANCE' ? '1' : discount;
  return {
    'itemId': id,
    'lineNo': 1,
    'goodsId': 'goods-$id',
    'goodsCode': 'G-$id',
    'goodsName': '货品$id',
    'colorName': null,
    'unitName': '个',
    'qty': qty,
    'listPrice': stored,
    'priceSource': priceSource,
    'financePriceByName': null,
    'financePriceAt': null,
    'currentMasterPrice': currentMaster,
    'clientPrice': clientPrice,
    'clientPriceLocal': clientPrice,
    'dealPrice': quoteDealPriceFromDiscount(stored, rate),
    'discount': stored == null ? discount : rate,
    'amount': quoteLineAmountPreview(qty: qty, price: stored, discount: rate),
    'fileAmountLocal': null,
    'diffToFile': null,
    'salesProposedDiscount': discount,
    'lastFinanceConfirmedDiscount': lastConfirmed,
    'changedSinceLastConfirm': false,
    'clientModel': null,
    'clientGoodsName': null,
    'remark': null,
    'blockingReason': null,
  };
}

Map<String, dynamic> _review({
  int status = 2,
  List<String>? actions,
  List<Map<String, dynamic>>? lines,
  Map<String, dynamic> extra = const {},
}) => {
  'id': 'quote-1',
  'billNo': 'XB-001',
  'billDate': '2026-09-26',
  'clientName': '尼日利亚SUNAS',
  'sellerName': '张销售',
  'baseCurrency': true,
  'settlementMethodId': 'settle-1',
  'settlementMethodName': '月结30天',
  'validUntil': '2026-10-31',
  'status': status,
  'statusBucket': switch (status) {
    2 => 'PENDING_FINANCE',
    1 => 'APPROVED',
    _ => 'DRAFT',
  },
  'reviewRevision': 5,
  'financeRemark': '老客户价',
  'totalOriginal': '400',
  'pricePendingCount': 0,
  'blockingLineCount': 0,
  'resubmitted': false,
  'canMaintainGoodsPrice': true,
  'financeActions':
      actions ??
      switch (status) {
        2 => const ['edit', 'return', 'confirm'],
        1 => const ['reopen'],
        _ => const <String>[],
      },
  'claimType': 'SALES_QUOTE_FINANCE_REVIEW',
  'lines': lines ?? [_line('a'), _line('b')],
  'revisions': [
    {
      'revision': 5,
      'action': 'SUBMIT',
      'actionLabel': '提交财务核价',
      'actorName': '张销售',
      'reason': null,
      'createdAt': '2026-09-27T01:00:00Z',
    },
  ],
  ...extra,
};

class _FakeRepo implements SalesQuoteFinanceReviewRepository {
  _FakeRepo(this.reviewJson);

  Map<String, dynamic> reviewJson;
  Map<String, dynamic>? afterSave;
  int reviewCalls = 0;
  final List<Map<String, dynamic>> saves = [];
  final List<Map<String, dynamic>> returns = [];
  final List<Map<String, dynamic>> confirms = [];
  final List<Map<String, dynamic>> reopens = [];

  int get status => reviewJson['status'] as int;

  @override
  Future<SalesQuoteFinanceReview> review(String quoteId) async {
    reviewCalls++;
    return SalesQuoteFinanceReview.fromJson(reviewJson);
  }

  @override
  Future<PagedResult<SalesQuoteFinanceListItem>> list({
    required SalesQuoteFinanceState state,
    int page = 1,
    int size = 20,
    String? keyword,
  }) async =>
      const PagedResult(items: [], page: 1, size: 20, total: 0, totalPages: 1);

  @override
  Future<SalesQuoteFinanceReview> saveEdits(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
    required SalesQuoteFinanceHeader header,
    List<SalesQuoteFinanceLineEdit> lines = const [],
  }) async {
    saves.add(
      quoteFinanceEditBody(
        expectedRevision: expectedRevision,
        expectedClaimId: expectedClaimId,
        header: header,
        lines: lines,
      ),
    );
    if (afterSave != null) reviewJson = afterSave!;
    return SalesQuoteFinanceReview.fromJson(reviewJson);
  }

  @override
  Future<void> returnToSales(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
    required String reason,
  }) async {
    returns.add(
      quoteFinanceDecisionBody(
        expectedRevision: expectedRevision,
        expectedClaimId: expectedClaimId,
        text: reason,
      ),
    );
  }

  @override
  Future<void> confirm(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
  }) async {
    confirms.add(
      quoteFinanceDecisionBody(
        expectedRevision: expectedRevision,
        expectedClaimId: expectedClaimId,
      ),
    );
  }

  @override
  Future<SalesQuoteFinanceReview> reopen(
    String quoteId, {
    required int expectedRevision,
  }) async {
    reopens.add(quoteFinanceReopenBody(expectedRevision: expectedRevision));
    reviewJson = _review(extra: const {'reviewRevision': 6});
    return SalesQuoteFinanceReview.fromJson(reviewJson);
  }
}

/// 与服务端 SalesQuoteFinanceClaimTargetLocks 同口径：只有待核价(status 2)的报价能认领，
/// 其它状态 409「报价已不在待财务核价状态」。
class _StatusGatedClaims extends FinanceClaimFixture {
  _StatusGatedClaims(this.statusOf);

  final int Function() statusOf;
  final List<String> refused = [];

  @override
  Future<TaskClaimView?> claimRequired(String type, String key) async {
    if (statusOf() != 2) {
      refused.add(key);
      throw ApiException('CONFLICT', '报价已不在待财务核价状态，请刷新', httpStatus: 409);
    }
    return super.claimRequired(type, key);
  }
}

Future<(_FakeRepo, FinanceClaimFixture)> _pump(
  WidgetTester tester,
  Map<String, dynamic> review, {
  FinanceClaimFixture Function(_FakeRepo repo)? claims,
}) async {
  tester.view.physicalSize = const Size(2400, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = _FakeRepo(review);
  final fixture = claims?.call(repo) ?? FinanceClaimFixture();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isSuperAdminProvider.overrideWithValue(false),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.salesQuoteFinanceView,
          Perm.salesQuoteFinanceConfirm,
        }),
        sessionProvider.overrideWith(_Session.new),
        fixedBadgeSummaryOverride(),
        salesQuoteFinanceReviewRepositoryProvider.overrideWithValue(repo),
        taskClaimRepositoryProvider.overrideWithValue(fixture),
        salesMasterNameServiceProvider.overrideWithValue(
          SalesMasterNameService(_DictApi()),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/finance/quote-review/quote-1',
          routes: [
            GoRoute(
              path: '/finance/quote-review',
              builder: (_, _) => const Scaffold(body: Text('quote-queue')),
            ),
            GoRoute(
              path: '/finance/quote-review/:id',
              builder: (_, state) =>
                  FinanceQuoteReviewPage(id: state.pathParameters['id']!),
            ),
            GoRoute(
              path: '/basicinfo/goods/:id',
              builder: (context, state) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text('goods-${state.pathParameters['id']}'),
                ),
              ),
            ),
          ],
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (repo, fixture);
}

Finder _deal(String id) => find.byKey(ValueKey('quote-finance-deal-$id'));
Finder _discount(String id) =>
    find.byKey(ValueKey('quote-finance-discount-$id'));

String _text(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

/// 顶部通知走 appNotificationProvider(不在页面树里)，从容器读出已发出的文案。
List<String> _notices(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(MaterialApp)),
  listen: false,
).read(appNotificationProvider).map((n) => n.message).toList();

/// 右键行(货品名称格)打开行菜单。
Future<void> _openRowMenu(WidgetTester tester, String goodsName) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text(goodsName)),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('quote-finance-save')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('claims the quote then allows editing; deal ↔ discount derive', (
    tester,
  ) async {
    final (repo, claims) = await _pump(tester, _review());
    expect(claims.acquired, ['quote-1']);
    expect(repo.reviewCalls, 2, reason: 're-read after the lease is held');
    expect(find.text('XB-001'), findsOneWidget);
    expect(find.text('待财务核价'), findsOneWidget);

    await tester.enterText(_deal('a'), '95');
    await tester.pump();
    expect(_text(tester, _discount('a')), '0.95');

    await tester.enterText(_discount('b'), '0.9');
    await tester.pump();
    expect(_text(tester, _deal('b')), '90');
  });

  testWidgets('save always sends the whole header state; lines are one of '
      'discount / dealPrice / giftZeroPrice', (tester) async {
    final (repo, claims) = await _pump(tester, _review());
    await tester.enterText(_deal('a'), '95');
    await tester.pump();
    repo.afterSave = _review(
      extra: const {'reviewRevision': 6},
      lines: [
        _line('a', discount: '0.95'),
        _line('b'),
      ],
    );
    await _save(tester);
    expect(repo.saves, hasLength(1));
    // 只改了行：有效期、结账方式、财务备注照样带当前值，服务端不会清空它们。
    expect(repo.saves.single, {
      'expectedRevision': 5,
      'expectedClaimId': claims.leases['quote-1']!.claimId,
      'validUntil': '2026-10-31',
      'settlementMethodId': 'settle-1',
      'financeRemark': '老客户价',
      'lines': [
        {'itemId': 'a', 'discount': '0.9500'},
      ],
    });
    expect(claims.renewed, contains('quote-1'));
    expect(_notices(tester), contains('修改已保存'));

    // 保存后以服务端新版本为准：下一次保存带回第 6 版。
    await tester.enterText(_deal('b'), '90');
    await tester.pump();
    await _save(tester);
    expect(repo.saves, hasLength(2));
    expect(repo.saves.last['expectedRevision'], 6);
    expect(repo.saves.last['financeRemark'], '老客户价');
    expect(repo.saves.last['lines'], [
      {'itemId': 'b', 'discount': '0.9000'},
    ]);
  });

  testWidgets('clearing the finance remark sends an explicit null', (
    tester,
  ) async {
    final (repo, _) = await _pump(tester, _review());
    await tester.enterText(find.byKey(const Key('quote-finance-remark')), '');
    await tester.pump();
    await _save(tester);
    expect(repo.saves, hasLength(1));
    final body = repo.saves.single;
    expect(body.containsKey('financeRemark'), isTrue);
    expect(body['financeRemark'], isNull);
    expect(body['validUntil'], '2026-10-31');
    expect(body['settlementMethodId'], 'settle-1');
    expect(body['lines'], isEmpty, reason: 'unchanged lines are not sent');
  });

  testWidgets('above list becomes a finance price; unpriced lines take a '
      'finance price or 赠品/0价 from the row menu', (tester) async {
    final (repo, _) = await _pump(
      tester,
      _review(
        lines: [
          _line('a', stored: null, currentMaster: null),
          _line('b', stored: '0', currentMaster: '0', clientPrice: '5'),
          _line('c'),
        ],
      ),
    );
    await _openRowMenu(tester, '货品b');
    await tester.tap(find.text('设为赠品/0价'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('赠品/0价'), findsOneWidget);

    await tester.enterText(_deal('c'), '120');
    await tester.pump();
    expect(find.byTooltip('高于标价, 按财务定价保存(折扣为 1)'), findsOneWidget);
    expect(_text(tester, _deal('c')), '120');

    await tester.enterText(_deal('a'), '12.5');
    await tester.pump();

    await _save(tester);
    expect(repo.saves.single['lines'], [
      {'itemId': 'a', 'dealPrice': '12.5'},
      {'itemId': 'b', 'giftZeroPrice': true},
      {'itemId': 'c', 'dealPrice': '120'},
    ]);

    // 有标价的行没有「财务直接定成交单价」：只有 高于标价 / 没有标价 才会是财务定价。
    await _openRowMenu(tester, '货品c');
    expect(find.text('设为赠品/0价'), findsOneWidget);
    expect(find.text('财务直接定成交单价'), findsNothing);
  });

  testWidgets('a row with an input error blocks save and confirm', (
    tester,
  ) async {
    final (repo, _) = await _pump(tester, _review());
    await tester.enterText(_discount('a'), '1.5');
    await tester.pump();
    await _save(tester);
    expect(repo.saves, isEmpty);
    expect(_notices(tester), contains(contains('有 1 行填写不对')));

    await tester.tap(find.byKey(const Key('quote-finance-confirm')));
    await tester.pumpAndSettle();
    expect(repo.confirms, isEmpty);
    expect(_notices(tester), contains('请先保存修改, 再确认报价'));
  });

  testWidgets('refresh from the latest list price sends useMasterPrice', (
    tester,
  ) async {
    final (repo, _) = await _pump(
      tester,
      _review(
        lines: [
          _line('a', currentMaster: '120', discount: '0.9'),
          _line('b'),
        ],
      ),
    );
    expect(find.text('100, 资料已改为 120'), findsOneWidget);
    await _openRowMenu(tester, '货品a');
    await tester.tap(find.text('按最新标价刷新'));
    await tester.pumpAndSettle();
    // 刷新后本行单价/折扣只读，显示按新标价的成交单价。
    expect(_deal('a'), findsNothing);
    expect(find.text('108.00'), findsOneWidget);
    await _save(tester);
    expect(repo.saves.single['lines'], [
      {'itemId': 'a', 'useMasterPrice': true},
    ]);
  });

  testWidgets('batch discount applies to checked lines and skips unpriced', (
    tester,
  ) async {
    await _pump(
      tester,
      _review(
        lines: [
          _line('a'),
          _line('b'),
          _line('c', stored: null, currentMaster: null),
        ],
      ),
    );
    final boxes = find.byType(Checkbox);
    // 第一个是表头全选。
    await tester.tap(boxes.first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quote-finance-batch-discount')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('quote-finance-batch-discount-input')),
      '0.8',
    );
    await tester.tap(
      find.byKey(const Key('quote-finance-batch-discount-apply')),
    );
    await tester.pumpAndSettle();
    expect(_text(tester, _discount('a')), '0.8');
    expect(_text(tester, _discount('b')), '0.8');
    expect(_text(tester, _deal('a')), '80');
    expect(_notices(tester), contains(contains('已给 2 行设好折扣')));
    expect(_notices(tester), contains(contains('1 行没有标价或由财务定价')));
  });

  testWidgets('editing a checked row discount updates every checked row', (
    tester,
  ) async {
    await _pump(tester, _review(lines: [_line('a'), _line('b'), _line('c')]));
    final boxes = find.byType(Checkbox);
    await tester.tap(boxes.at(1));
    await tester.tap(boxes.at(2));
    await tester.pumpAndSettle();
    await tester.enterText(_discount('a'), '0.9');
    await tester.pump();
    expect(_text(tester, _discount('b')), '0.9');
    expect(_text(tester, _discount('c')), '1', reason: 'unchecked row stays');
  });

  testWidgets('return requires a reason; chips fill it; posts text + lease', (
    tester,
  ) async {
    final (repo, claims) = await _pump(tester, _review());
    final claimId = claims.leases['quote-1']!.claimId;
    await tester.tap(find.byKey(const Key('quote-finance-return')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quote-finance-return-submit')));
    await tester.pump();
    expect(repo.returns, isEmpty);
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message?.contains('请填写退回原因') == true,
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('quote-finance-return-chip-0')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('quote-finance-return-chip-2')));
    await tester.pump();
    expect(
      _text(tester, find.byKey(const Key('quote-finance-return-reason'))),
      '客户要改数量; 价格需销售与客户确认',
    );
    await tester.tap(find.byKey(const Key('quote-finance-return-submit')));
    await tester.pumpAndSettle();
    expect(repo.returns, [
      {
        'expectedRevision': 5,
        'expectedClaimId': claimId,
        'text': '客户要改数量; 价格需销售与客户确认',
      },
    ]);
    expect(
      claims.released,
      isNotEmpty,
      reason: 'lease released after decision',
    );
  });

  testWidgets('confirm is blocked while a line has no price', (tester) async {
    final (repo, _) = await _pump(
      tester,
      _review(
        lines: [
          _line('a'),
          _line('b', stored: '0', currentMaster: '0', clientPrice: '5'),
        ],
      ),
    );
    expect(
      find.byKey(const Key('quote-finance-need-price-notice')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('quote-finance-maintain-price')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('quote-finance-confirm')));
    await tester.pumpAndSettle();
    expect(repo.confirms, isEmpty);
    expect(_notices(tester), contains(contains('还有 1 行没有价格')));
  });

  testWidgets('goods price link follows the server capability flag only', (
    tester,
  ) async {
    await _pump(
      tester,
      _review(
        lines: [_line('a', stored: null, currentMaster: null)],
        extra: const {'canMaintainGoodsPrice': false},
      ),
    );
    expect(
      find.byKey(const Key('quote-finance-need-price-notice')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('quote-finance-maintain-price')), findsNothing);
  });

  testWidgets('back from the goods page re-reads the quote and keeps edits', (
    tester,
  ) async {
    final (repo, claims) = await _pump(
      tester,
      _review(
        lines: [_line('a', stored: null, currentMaster: null), _line('b')],
      ),
    );
    await tester.enterText(_discount('b'), '0.9');
    await tester.pump();
    final callsBefore = repo.reviewCalls;
    await tester.tap(find.byKey(const Key('quote-finance-maintain-price')));
    await tester.pumpAndSettle();
    expect(find.text('goods-goods-a'), findsOneWidget);
    // 财务在货品资料里给 a 维护了标价 50。
    repo.reviewJson = _review(
      lines: [
        _line('a', stored: null, currentMaster: '50'),
        _line('b'),
      ],
    );
    await tester.tap(find.text('goods-goods-a'));
    await tester.pumpAndSettle();
    expect(repo.reviewCalls, callsBefore + 1);
    expect(claims.released, isEmpty, reason: 'the lease is kept');
    expect(_text(tester, _discount('b')), '0.9', reason: 'edit kept');
    // a 现在有标价，可以按标价打折(填折扣即可定价)。
    await tester.enterText(_discount('a'), '0.8');
    await tester.pump();
    expect(_text(tester, _deal('a')), '40');
    await _save(tester);
    expect(repo.saves.single['lines'], [
      {'itemId': 'a', 'dealPrice': '40'},
      {'itemId': 'b', 'discount': '0.9000'},
    ]);
  });

  testWidgets('confirm asks to save pending edits first', (tester) async {
    final (repo, _) = await _pump(tester, _review());
    await tester.enterText(_deal('a'), '95');
    await tester.pump();
    await tester.tap(find.byKey(const Key('quote-finance-confirm')));
    await tester.pumpAndSettle();
    expect(repo.confirms, isEmpty);
    expect(_notices(tester), contains('请先保存修改, 再确认报价'));
  });

  testWidgets('confirm with a live lease posts the shown revision', (
    tester,
  ) async {
    final (repo, claims) = await _pump(tester, _review());
    final claimId = claims.leases['quote-1']!.claimId;
    await tester.tap(find.byKey(const Key('quote-finance-confirm')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('quote-finance-confirm-total')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('quote-finance-confirm-submit')));
    await tester.pumpAndSettle();
    expect(repo.confirms.single, {
      'expectedRevision': 5,
      'expectedClaimId': claimId,
    });
    expect(_notices(tester), contains('报价已确认, 已通知销售转订货单'));
    expect(find.text('quote-queue'), findsOneWidget);
  });

  testWidgets('claim failure keeps the page read-only', (tester) async {
    final (repo, _) = await _pump(
      tester,
      _review(),
      claims: (_) => FinanceClaimFixture()..failClaim = true,
    );
    expect(find.text('重新认领并刷新'), findsOneWidget);
    expect(_deal('a'), findsNothing, reason: 'no editable fields');
    await tester.tap(find.byKey(const Key('quote-finance-confirm')));
    await tester.pumpAndSettle();
    expect(repo.confirms, isEmpty);
    expect(repo.reviewCalls, 1);
  });

  testWidgets('no finance actions: read-only notice and no claim', (
    tester,
  ) async {
    final (_, claims) = await _pump(
      tester,
      _review(
        status: 1,
        actions: const [],
        extra: const {'convertedOrderNo': 'XD-9'},
      ),
    );
    expect(claims.acquired, isEmpty);
    expect(find.textContaining('只能查看'), findsOneWidget);
    expect(find.textContaining('已转订货单 XD-9'), findsOneWidget);
    expect(find.byKey(const Key('quote-finance-back')), findsOneWidget);
  });

  testWidgets('finance reopen needs no claim (the server refuses claims on '
      'confirmed quotes), then the reloaded pending quote is claimed', (
    tester,
  ) async {
    late _StatusGatedClaims gated;
    final (repo, _) = await _pump(
      tester,
      _review(status: 1),
      claims: (repo) => gated = _StatusGatedClaims(() => repo.status),
    );
    expect(gated.acquired, isEmpty, reason: 'no claim for reopen only');
    expect(gated.refused, isEmpty);
    expect(find.text('重新认领并刷新'), findsNothing);
    expect(find.textContaining('只能查看'), findsNothing);

    await tester.tap(find.byKey(const Key('quote-finance-reopen')));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.text('撤销确认再修改'),
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(repo.reopens, [
      {'expectedRevision': 5},
    ]);
    expect(_notices(tester), contains('已撤销确认, 可以继续修改价格'));
    // 重载：报价回到待核价 → 认领成功 → 可改价/确认。
    expect(gated.refused, isEmpty);
    expect(gated.acquired, ['quote-1']);
    expect(find.text('重新认领并刷新'), findsNothing);
    expect(find.byKey(const Key('quote-finance-confirm')), findsOneWidget);
    expect(_deal('a'), findsOneWidget);
  });

  testWidgets('resubmitted lines with a changed discount are highlighted', (
    tester,
  ) async {
    await _pump(
      tester,
      _review(
        lines: [
          _line('a', discount: '0.9', lastConfirmed: '0.95'),
          _line('b', lastConfirmed: '1'),
        ],
      ),
    );
    expect(
      find.byKey(const Key('quote-finance-resubmit-notice')),
      findsOneWidget,
    );
    expect(find.text('上次确认折扣'), findsOneWidget);
  });
}
