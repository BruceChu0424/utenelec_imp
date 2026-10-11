// 单据旁边显示的往来余额(ADR-128)：服务端 PartyOpenBalanceView 的前端镜像。
//
// 服务端按「往来单位 × 币种」一次算好：单据币种一档(应收/应付未结、可用预收/可抵、还差多少)
// 按原币余额精确相加、不用汇率；其它币种各列各的，不换算、不相加；原币无法核实的历史余额
// 只给本币单列；信用额度/铺底额只和全部币种正式应收(应付)的账面本币毛额比，是否超额也由
// 服务端判定。本文件只做显示，不重算任何金额。
import '../formatters/exact_decimal.dart';
import '../formatters/money_display.dart';

/// 往来单位是哪一边：客户(应收、预收)还是供应商(应付、可抵预付与贷项)。
enum PartyBalanceSide { customer, supplier }

/// 同一往来单位在另一个币种下的余额(各用自己的币种原币)。
class PartyCurrencyBalance {
  const PartyCurrencyBalance({
    this.currencyId,
    this.currencyName,
    this.baseCurrency = false,
    this.openOriginal = '0',
    this.creditOriginal = '0',
    this.netOriginal = '0',
  });

  final String? currencyId;
  final String? currencyName;
  final bool baseCurrency;
  final String openOriginal;
  final String creditOriginal;
  final String netOriginal;

  factory PartyCurrencyBalance.fromJson(Map<String, dynamic> json) =>
      PartyCurrencyBalance(
        currencyId: _text(json['currencyId']),
        currencyName: _text(json['currencyName']),
        baseCurrency: json['baseCurrency'] == true,
        openOriginal: _money(json['openOriginal']),
        creditOriginal: _money(json['creditOriginal']),
        netOriginal: _money(json['netOriginal']),
      );

  /// 本币种「还差多少」：「人民币 30000.00」或「预收有余 港币 500.00」。
  String netText(PartyBalanceSide side) =>
      partyNetText(netOriginal, currencyName: currencyName, side: side);
}

/// 一张单据旁边的往来余额。
class PartyOpenBalance {
  const PartyOpenBalance({
    this.currencyId,
    this.currencyName,
    this.baseCurrency = false,
    this.openOriginal = '0',
    this.creditOriginal = '0',
    this.netOriginal = '0',
    this.creditBookLocal = '0',
    this.otherCurrencies = const [],
    this.baseCurrencyName,
    this.openBookLocal = '0',
    this.unverifiedLocal = '0',
    this.unverifiedCount = 0,
    this.creditLimitLocal,
    this.overLimitLocal,
    this.overCredit = false,
  });

  /// 单据币种。
  final String? currencyId;
  final String? currencyName;
  final bool baseCurrency;

  /// 单据币种下应收(应付)未结原币，含退货红字。
  final String openOriginal;

  /// 单据币种下可用预收(客户) / 可抵的预付与贷项(供应商)原币，正数。
  final String creditOriginal;

  /// 还差多少 = open − credit：正数 = 还欠，负数 = 预收(可抵)有余。
  final String netOriginal;

  /// [creditOriginal] 的账面本币(出货放行事件冻结它)。
  final String creditBookLocal;

  /// 同一往来单位其它币种的余额，各用自己的币种。
  final List<PartyCurrencyBalance> otherCurrencies;

  /// 本位币名称(信用口径与原币未核实金额都按本币显示)。
  final String? baseCurrencyName;

  /// 全部币种正式应收(应付)的账面本币毛额，不扣预收；信用额度/铺底额只和它比。
  final String openBookLocal;

  /// 原币无法核实的历史余额(只有本币可信)。
  final String unverifiedLocal;
  final int unverifiedCount;

  /// 比较用的本币额度(信用额度或铺底额)；null = 未设置，不判超额。
  final String? creditLimitLocal;

  /// [openBookLocal] − 额度，可为负；未设置额度时为 null。
  final String? overLimitLocal;

  /// 是否超额(服务端判定)。
  final bool overCredit;

  /// 服务端没有下发(或不是对象)时返回 null，页面显示「—」而不是猜 0。
  static PartyOpenBalance? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, dynamic>();
    return PartyOpenBalance(
      currencyId: _text(map['currencyId']),
      currencyName: _text(map['currencyName']),
      baseCurrency: map['baseCurrency'] == true,
      openOriginal: _money(map['openOriginal']),
      creditOriginal: _money(map['creditOriginal']),
      netOriginal: _money(map['netOriginal']),
      creditBookLocal: _money(map['creditBookLocal']),
      otherCurrencies: [
        for (final item in map['otherCurrencies'] as List? ?? const [])
          if (item is Map)
            PartyCurrencyBalance.fromJson(item.cast<String, dynamic>()),
      ],
      baseCurrencyName: _text(map['baseCurrencyName']),
      openBookLocal: _money(map['openBookLocal']),
      unverifiedLocal: _money(map['unverifiedLocal']),
      unverifiedCount: _int(map['unverifiedCount']),
      creditLimitLocal: financeExactDecimal(map['creditLimitLocal']),
      overLimitLocal: financeExactDecimal(map['overLimitLocal']),
      overCredit: map['overCredit'] == true,
    );
  }

  /// 单据币种一档的「还差多少」：「12000.00 美金」或「预收有余 200.00 美金」。
  String headline(PartyBalanceSide side) =>
      partyNetText(netOriginal, currencyName: currencyName, side: side);

  /// 单据币种下的应收(应付)未结，「500.00 美金」。
  String get openText => _documentMoney(openOriginal);

  /// 单据币种下的可用预收(可抵)，「100.00 美金」。
  String get creditText => _documentMoney(creditOriginal);

  /// 按本位币显示一笔本币金额，「3500.00 元」。
  String baseMoneyText(String? amount) =>
      financeMoneyWithUnitSuffix(amount, currencyName: baseCurrencyName);

  /// 其它币种：「另有 30000.00 元、预收有余 500.00 港币」；没有时为 null。
  String? otherCurrenciesText(PartyBalanceSide side) => otherCurrencies.isEmpty
      ? null
      : '另有 ${otherCurrencies.map((other) => other.netText(side)).join('、')}';

  /// 原币未核实：「另有历史应收 1200.00 元 原币未核实」；没有时为 null。
  String? unverifiedText(PartyBalanceSide side) => _sign(unverifiedLocal) == 0
      ? null
      : '另有历史${side == PartyBalanceSide.customer ? '应收' : '应付'} '
            '${baseMoneyText(unverifiedLocal)} 原币未核实';

  /// 主数字之外要补充说明的部分(其它币种 + 原币未核实)；都没有时为 null。
  String? footnote(PartyBalanceSide side) {
    final parts = [
      otherCurrenciesText(side),
      unverifiedText(side),
    ].whereType<String>();
    return parts.isEmpty ? null : parts.join('；');
  }

  String _documentMoney(String amount) =>
      financeMoneyWithUnitSuffix(amount, currencyName: currencyName);
}

/// 一个币种的「还差多少」：正数(还欠)写「金额 币种」；负数写「预收有余 金额 币种」
/// (供应商写「可抵有余」，因为里面可能是预付，也可能是退货或索赔贷项)。
String partyNetText(
  String? netOriginal, {
  String? currencyName,
  required PartyBalanceSide side,
}) {
  final net = financeExactDecimal(netOriginal);
  if (net == null) return '—';
  if (_sign(net) >= 0) {
    return financeMoneyWithUnitSuffix(net, currencyName: currencyName);
  }
  final surplus = side == PartyBalanceSide.customer ? '预收有余' : '可抵有余';
  return '$surplus ${financeMoneyWithUnitSuffix(net.substring(1), currencyName: currencyName)}';
}

int _sign(String? decimal) => financeAmountUnits(decimal)?.sign ?? 0;

String _money(Object? value) => financeExactDecimal(value) ?? '0';

String? _text(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

int _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse(value?.toString() ?? '') ?? 0;
