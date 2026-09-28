// AI 程序截图审查用的业务假数据与假接口: 识别结果夹具(去标识的真实识别结果)、
// 销售编辑页/报价详情的接口替身、报价核价仓储、客户货品对照仓储。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/client_goods_alias.dart';
import 'package:uten_imp/features/basic_data/repositories/client_goods_alias_repository.dart';
import 'package:uten_imp/features/finance/models/quote_finance_pricing.dart';
import 'package:uten_imp/features/finance/models/sales_quote_finance_review.dart';
import 'package:uten_imp/features/finance/repositories/sales_quote_finance_review_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

// ---------------------------------------------------------------- 识别结果

/// 一次真实识别(客户订货表, 38 行)的结果, 客户身份信息已替换为假值。
Map<String, dynamic> sampleIntakeResult() =>
    jsonDecode(
          File(
            'test/fixtures/sales_intake_result_sample.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

/// 同一份结果, 但客户没对上: 两个近似候选 + 可用文件信息新建。
Map<String, dynamic> sampleIntakeResultClientUnmatched() {
  final json = sampleIntakeResult();
  json['client'] = {
    'status': 'UNMATCHED',
    'selectedClientId': null,
    'candidates': [
      {
        'clientId': 'client-a',
        'code': 'WM901',
        'name': '尼日利亚ALPHA贸易',
        'score': 61,
        'reasons': ['名称相似'],
      },
      {
        'clientId': 'client-b',
        'code': 'WM902',
        'name': '拉各斯ALPHA电气',
        'score': 55,
        'reasons': ['名称相似', '邮箱域名不同'],
      },
    ],
    'enrichment': const <Object>[],
    'mismatchWarning': null,
    'newClientProposal': {
      'name': 'ALPHA ELECTRICAL RESOURCE LTD',
      'fullName': 'ALPHA ELECTRICAL RESOURCE LTD',
      'nameEn': 'ALPHA ELECTRICAL RESOURCE LTD',
      'linkman': 'JOHN SAMPLE',
      'email': 'buyer@example.com',
    },
  };
  return json;
}

// ---------------------------------------------------------------- 会话

class VisualSession extends SessionNotifier {
  VisualSession({this.name = '张销售'});

  final String name;

  @override
  SessionState build() => SessionState(
    user: AppUser(id: 'user-1', code: 'S001', name: name),
  );
}

// ---------------------------------------------------------------- 销售编辑页

/// 销售编辑页的接口替身: 新建单据; 币种/颜色/单位字典取自识别结果夹具(名称能解析出来),
/// 其它读取为空。
class IntakeEditApi extends ApiClient {
  IntakeEditApi() : super(Dio()) {
    final result = sampleIntakeResult();
    final currency = result['currency'] as Map<String, dynamic>;
    _currencies = [
      {'id': currency['baseCurrencyId'], 'name': currency['baseCurrencyName']},
    ];
    final colors = <String, String>{};
    final units = <String, String>{};
    for (final line in (result['lines'] as List).cast<Map<String, dynamic>>()) {
      for (final c
          in (line['candidates'] as List).cast<Map<String, dynamic>>()) {
        if (c['colorId'] case final String id) {
          colors[id] = '${c['colorName'] ?? ''}';
        }
        if (c['unitId'] case final String id) {
          units[id] = '${c['unitName'] ?? ''}';
        }
      }
    }
    _colors = [
      for (final e in colors.entries) {'id': e.key, 'name': e.value},
    ];
    _units = [
      for (final e in units.entries) {'id': e.key, 'name': e.value},
    ];
  }

  late final List<Map<String, dynamic>> _currencies;
  late final List<Map<String, dynamic>> _colors;
  late final List<Map<String, dynamic>> _units;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {
    'items': <Map<String, dynamic>>[],
    'page': 1,
    'size': 1,
    'total': 0,
    'totalPages': 0,
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('currencies')) return _currencies;
    if (path.contains('colors')) return _colors;
    if (path.contains('units')) return _units;
    if (path.contains('settlement')) {
      return [
        {'id': 'settle-1', 'name': '款到发货'},
      ];
    }
    return const [];
  }
}

// ---------------------------------------------------------------- 报价详情

class QuoteDetailApi extends ApiClient {
  QuoteDetailApi(this.detail) : super(Dio());

  final Map<String, dynamic> detail;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => detail;

  /// 客户/币种/颜色/单位字典与货品名称查询(详情页按 id 解析名称)。
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => switch (path) {
    '/master/goods/lookup' => const [
      {'id': 'goods-1', 'code': '280235165', 'name': 'Z9 146型二开多功能三孔(带灯)'},
      {'id': 'goods-2', 'code': '280235153', 'name': '尼日利亚6M 四联双控'},
    ],
    _ when path.startsWith('/master/clients') => const [
      {'id': 'client-1', 'code': 'WM900', 'name': '尼日利亚ALPHA'},
    ],
    _ when path.startsWith('/master/currencies') => const [
      {'id': 'cny', 'name': '人民币'},
    ],
    _ when path.startsWith('/master/colors') => const [
      {'id': 'color-white', 'name': '白色'},
    ],
    _ when path.startsWith('/master/units') => const [
      {'id': 'unit-pcs', 'name': '个'},
    ],
    _ => const [],
  };
}

Map<String, dynamic> quoteDetailJson({
  required int status,
  required List<String> actions,
  Map<String, dynamic> extra = const {},
}) => {
  'id': 'quote-1',
  'billNo': 'XB-20260927-001',
  'billDate': '2026-09-27',
  'clientId': 'client-1',
  'currencyId': 'cny',
  'validUntil': '2026-10-31',
  'status': status,
  'writable': true,
  'reviewRevision': 4,
  'allowedActions': actions,
  'clientFileCurrency': 'CNY',
  'items': <Map<String, dynamic>>[
    {
      'id': 'line-1',
      'goodsId': 'goods-1',
      'colorId': 'color-white',
      'unitId': 'unit-pcs',
      'qty': 1800,
      'price': 21,
      'discount': 1,
      'amountOriginal': 37800,
      'clientModel': 'GZ23/D',
      'clientGoodsName': '2 GANG 2 WAY SWITCH + 3 PIN SOCKET',
      'clientPrice': 21,
    },
    {
      'id': 'line-2',
      'goodsId': 'goods-2',
      'colorId': 'color-white',
      'unitId': 'unit-pcs',
      'qty': 1000,
      'price': 10.5,
      'discount': 1,
      'amountOriginal': 10500,
      'clientModel': 'GK11Z12Z13/D',
      'clientPrice': 10.5,
    },
  ],
  ...extra,
};

// ---------------------------------------------------------------- 报价核价

/// 财务核价页的字典接口(结账方式)。
class FinanceDictApi extends ApiClient {
  FinanceDictApi() : super(Dio());

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [
    {'id': 'settle-1', 'name': '款到发货'},
    {'id': 'settle-2', 'name': '月结30天'},
  ];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {};
}

Map<String, dynamic> _reviewLine(
  int no,
  String id, {
  required String code,
  required String name,
  String? color,
  required String qty,
  String? stored,
  String? currentMaster,
  String priceSource = 'MASTER',
  String discount = '1',
  String? clientPrice,
  String? clientModel,
  String? clientGoodsName,
  String? financeBy,
  String? lastConfirmed,
  bool changed = false,
  String? blocking,
}) {
  final rate = priceSource == 'FINANCE' ? '1' : discount;
  return {
    'itemId': id,
    'lineNo': no,
    'goodsId': 'goods-$id',
    'goodsCode': code,
    'goodsName': name,
    'colorName': color,
    'unitName': '个',
    'qty': qty,
    'listPrice': stored,
    'priceSource': priceSource,
    'financePriceByName': financeBy,
    'financePriceAt': financeBy == null ? null : '2026-09-27T08:10:00Z',
    'currentMasterPrice': currentMaster ?? stored,
    'clientPrice': clientPrice,
    'clientPriceLocal': clientPrice,
    'dealPrice': quoteDealPriceFromDiscount(stored, rate),
    'discount': stored == null ? discount : rate,
    'amount': quoteLineAmountPreview(qty: qty, price: stored, discount: rate),
    'fileAmountLocal': null,
    'diffToFile': null,
    'salesProposedDiscount': discount,
    'lastFinanceConfirmedDiscount': lastConfirmed,
    'changedSinceLastConfirm': changed,
    'clientModel': clientModel,
    'clientGoodsName': clientGoodsName,
    'remark': null,
    'blockingReason': blocking,
  };
}

Map<String, dynamic> quoteReviewJson() => {
  'id': 'quote-1',
  'billNo': 'XB-20260927-001',
  'billDate': '2026-09-27',
  'clientName': '尼日利亚ALPHA',
  'clientCode': 'WM900',
  'sellerName': '张销售',
  'makerName': '张销售',
  'baseCurrency': true,
  'currencyName': '人民币',
  'clientFileCurrency': 'CNY',
  'settlementMethodId': 'settle-1',
  'settlementMethodName': '款到发货',
  'validUntil': '2026-10-31',
  'contractNo': 'ALPHA-260422',
  'status': 2,
  'statusBucket': 'PENDING_FINANCE',
  'reviewRevision': 5,
  'submittedAt': '2026-09-27T07:40:00Z',
  'submittedByName': '张销售',
  'financeRemark': null,
  'totalOriginal': '71935.00',
  'pricePendingCount': 2,
  'blockingLineCount': 1,
  'resubmitted': true,
  'canMaintainGoodsPrice': true,
  'financeActions': const ['edit', 'return', 'confirm'],
  'claimType': 'SALES_QUOTE_FINANCE_REVIEW',
  'lines': [
    _reviewLine(
      1,
      'a',
      code: '280235165',
      name: 'Z9 146型二开多功能三孔(带灯)',
      color: '白色',
      qty: '1800',
      stored: '21',
      clientPrice: '21',
      clientModel: 'GZ23/D',
      lastConfirmed: '1',
    ),
    _reviewLine(
      2,
      'b',
      code: '280235153',
      name: '尼日利亚6M 四联双控',
      color: '白色',
      qty: '1000',
      stored: '10.5',
      priceSource: 'FINANCE',
      financeBy: '王会计',
      clientPrice: '10.5',
      clientModel: 'GK11Z12Z13/D',
    ),
    _reviewLine(
      3,
      'c',
      code: '280235150',
      name: '尼日利亚6M 双联双控',
      color: '白色',
      qty: '700',
      stored: '0',
      currentMaster: '0',
      clientPrice: '14.18',
      clientModel: 'GK22',
      blocking: '标价为 0, 请填写成交单价或勾选赠品/0价',
    ),
    _reviewLine(
      4,
      'd',
      code: '280235162',
      name: '尼日利亚6M 空白面板',
      color: '白色',
      qty: '600',
      stored: '6.84',
      discount: '0.9503',
      clientPrice: '6.5',
      clientModel: 'G-M/D',
      lastConfirmed: '0.95',
      changed: true,
    ),
    _reviewLine(
      5,
      'e',
      code: '280235416',
      name: 'Z9 146型二开多功能三孔(带灯)',
      color: '金色',
      qty: '30',
      stored: '21',
      clientPrice: '22.11',
      clientModel: 'GZ23/D',
      clientGoodsName: '2 GANG SWITCH SOCKET GOLD',
    ),
  ],
  'revisions': [
    {
      'revision': 5,
      'action': 'SUBMIT',
      'actionLabel': '提交财务核价',
      'actorName': '张销售',
      'reason': null,
      'createdAt': '2026-09-27T07:40:00Z',
    },
    {
      'revision': 4,
      'action': 'RETURN',
      'actionLabel': '财务退回',
      'actorName': '王会计',
      'reason': '空白面板客户价低于标价太多, 请和客户确认',
      'createdAt': '2026-09-27T05:20:00Z',
    },
    {
      'revision': 3,
      'action': 'FINANCE_EDIT',
      'actionLabel': '财务修改',
      'actorName': '王会计',
      'reason': null,
      'createdAt': '2026-09-27T05:12:00Z',
    },
    {
      'revision': 2,
      'action': 'SUBMIT',
      'actionLabel': '提交财务核价',
      'actorName': '张销售',
      'reason': null,
      'createdAt': '2026-09-27T03:02:00Z',
    },
  ],
};

class QuoteReviewRepo implements SalesQuoteFinanceReviewRepository {
  @override
  Future<SalesQuoteFinanceReview> review(String quoteId) async =>
      SalesQuoteFinanceReview.fromJson(quoteReviewJson());

  static SalesQuoteFinanceListItem _item(
    String id, {
    required String client,
    String bucket = 'PENDING_FINANCE',
    int needsPrice = 0,
    bool resubmitted = false,
    String? claimedBy,
    bool claimedByMe = false,
    String? returnReason,
    String? confirmedBy,
    String? orderNo,
    String total = '71935.00',
    int lines = 38,
  }) => SalesQuoteFinanceListItem.fromJson({
    'id': id,
    'billNo': 'XB-20260927-$id',
    'billDate': '2026-09-27',
    'clientName': client,
    'sellerName': '张销售',
    'makerName': '张销售',
    'submittedAt': '2026-09-27T07:40:00Z',
    'lineCount': lines,
    'pricePendingCount': needsPrice,
    'totalOriginal': total,
    'clientFileCurrency': 'CNY',
    'statusBucket': bucket,
    'reviewRevision': 2,
    'resubmitted': resubmitted,
    'financeReturnReason': returnReason,
    'financeReturnedAt': returnReason == null ? null : '2026-09-27T05:20:00Z',
    'financeConfirmedAt': confirmedBy == null ? null : '2026-09-27T08:00:00Z',
    'financeConfirmedByName': confirmedBy,
    'convertedOrderNo': orderNo,
    'claimedByName': claimedBy,
    'claimedByMe': claimedByMe,
  });

  @override
  Future<PagedResult<SalesQuoteFinanceListItem>> list({
    required SalesQuoteFinanceState state,
    int page = 1,
    int size = 20,
    String? keyword,
  }) async {
    final items = switch (state) {
      SalesQuoteFinanceState.pending => [
        _item(
          '001',
          client: '尼日利亚ALPHA',
          needsPrice: 7,
          resubmitted: true,
          claimedByMe: true,
        ),
        _item(
          '002',
          client: '约旦BETA建材',
          claimedBy: '王会计',
          total: '12880.50',
          lines: 6,
        ),
        _item(
          '003',
          client: '迪拜GAMMA照明',
          needsPrice: 2,
          total: '5320.00',
          lines: 3,
        ),
      ],
      SalesQuoteFinanceState.confirmed => [
        _item(
          '004',
          client: '迪拜GAMMA照明',
          bucket: 'APPROVED',
          confirmedBy: '王会计',
          orderNo: 'XD-20260927-002',
        ),
      ],
      SalesQuoteFinanceState.returned => [
        _item(
          '005',
          client: '约旦BETA建材',
          bucket: 'FINANCE_REJECTED',
          returnReason: '空白面板客户价低于标价太多, 请和客户确认',
        ),
      ],
    };
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: items.length,
      totalPages: 1,
    );
  }

  @override
  Future<SalesQuoteFinanceReview> saveEdits(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
    required SalesQuoteFinanceHeader header,
    List<SalesQuoteFinanceLineEdit> lines = const [],
  }) => review(quoteId);

  @override
  Future<void> returnToSales(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
    required String reason,
  }) async {}

  @override
  Future<void> confirm(
    String quoteId, {
    required int expectedRevision,
    required String expectedClaimId,
  }) async {}

  @override
  Future<SalesQuoteFinanceReview> reopen(
    String quoteId, {
    required int expectedRevision,
  }) => review(quoteId);
}

// ---------------------------------------------------------------- 客户货品对照

ClientGoodsAlias _alias(
  String id, {
  required String text,
  String kind = ClientGoodsAliasKind.partNo,
  String? context,
  required String goodsCode,
  required String goodsName,
  String color = '白色',
  int confirm = 1,
  int explicit = 0,
  bool canDelete = true,
}) => ClientGoodsAlias(
  id: id,
  scope: ClientGoodsAliasScope.client,
  aliasKind: kind,
  aliasText: text,
  contextText: context,
  goods: ClientGoodsAliasGoods(
    id: 'goods-$id',
    code: goodsCode,
    name: goodsName,
    colorName: color,
  ),
  confirmCount: confirm,
  explicitCount: explicit,
  lastConfirmedAt: '2026-09-27T02:30:00Z',
  lastConfirmedByName: '张销售',
  canDelete: canDelete,
);

class AliasRepo implements ClientGoodsAliasRepository {
  AliasRepo({this.empty = false});

  final bool empty;

  List<ClientGoodsAlias> get _rows => empty
      ? const []
      : [
          _alias(
            '1',
            text: 'GZ23/D',
            context: 'Z9 | WHITE',
            goodsCode: '280235165',
            goodsName: 'Z9 146型二开多功能三孔(带灯)',
            confirm: 3,
            explicit: 1,
          ),
          _alias(
            '2',
            text: 'GZ23/D',
            context: 'Z9 | GOLD',
            goodsCode: '280235416',
            goodsName: 'Z9 146型二开多功能三孔(带灯)',
            color: '金色',
          ),
          _alias(
            '3',
            text: '2 GANG 2 WAY SWITCH',
            kind: ClientGoodsAliasKind.description,
            goodsCode: '280235150',
            goodsName: '尼日利亚6M 双联双控',
            confirm: 2,
          ),
          _alias(
            '4',
            text: 'GK11Z12Z13/D',
            goodsCode: '280235153',
            goodsName: '尼日利亚6M 四联双控',
            canDelete: false,
          ),
        ];

  @override
  Future<PagedResult<ClientGoodsAlias>> list(
    String clientId, {
    int page = 1,
    int size = 20,
    String? keyword,
  }) async => PagedResult(
    items: _rows,
    page: 1,
    size: size,
    total: _rows.length,
    totalPages: 1,
  );

  @override
  Future<void> delete(String clientId, String aliasId) async {}
}
