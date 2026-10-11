import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/formatters/money_display.dart';
import 'package:uten_imp/shared/models/party_open_balance.dart';

/// ADR-128 → 2026-10-10 用户口径：往来余额只显示服务端算好的数，按单据币种
/// 写成「金额 币种」后缀式（人民币显示为「元」）。
void main() {
  group('financeMoneyWithUnitSuffix', () {
    test('币种名优先做后缀，旧数字编号不显示，金额按原文至少两位小数', () {
      expect(
        financeMoneyWithUnitSuffix('158400.0000', currencyName: '美金'),
        '158400.00 美金',
      );
      // 旧数字编号（002）认不出币种 → 不猜，只显金额。
      expect(financeMoneyWithUnitSuffix('12.3456', currencyCode: '002'),
          '12.3456');
      expect(
        financeMoneyWithUnitSuffix('5', currencyCode: 'USD'),
        '5.00 USD',
      );
      // 本位币后缀短名「元」。
      expect(financeMoneyWithUnitSuffix('0.5', currencyName: '人民币'), '0.50 元');
      expect(financeLocalMoneyWithUnitSuffix('1500'), '1500.00 元');
    });

    test('没有金额时只显示横线，不单挂币种名；非数字哨兵原文不拼单位', () {
      expect(financeMoneyWithUnitSuffix(null, currencyName: '美金'), '—');
      expect(financeMoneyWithUnitSuffix('  ', currencyName: '美金'), '—');
      expect(financeMoneyWithUnitSuffix('***', currencyName: '美金'), '***');
      expect(financeMoneyText('-0.5'), '-0.50');
    });
  });

  group('PartyOpenBalance', () {
    Map<String, dynamic> json({
      String net = '400',
      List<Map<String, dynamic>> others = const [],
      String unverified = '0',
    }) => {
      'currencyId': 'usd',
      'currencyName': '美金',
      'baseCurrency': false,
      'openOriginal': '500.0000',
      'creditOriginal': '100',
      'netOriginal': net,
      'creditBookLocal': '680',
      'otherCurrencies': others,
      'baseCurrencyName': '人民币',
      'openBookLocal': '3500',
      'unverifiedLocal': unverified,
      'unverifiedCount': unverified == '0' ? 0 : 2,
      'creditLimitLocal': '3000',
      'overLimitLocal': '500',
      'overCredit': true,
    };

    test('解析服务端视图，单据币种一档写成「金额 币种」', () {
      final balance = PartyOpenBalance.fromJson(json())!;
      expect(balance.openText, '500.00 美金');
      expect(balance.creditText, '100.00 美金');
      expect(balance.headline(PartyBalanceSide.customer), '400.00 美金');
      expect(balance.baseMoneyText(balance.openBookLocal), '3500.00 元');
      expect(balance.creditLimitLocal, '3000');
      expect(balance.overLimitLocal, '500');
      expect(balance.overCredit, isTrue);
      expect(balance.footnote(PartyBalanceSide.customer), isNull);
    });

    test('还差多少为负时客户写预收有余、供应商写可抵有余', () {
      final balance = PartyOpenBalance.fromJson(json(net: '-200.0000'))!;
      expect(balance.headline(PartyBalanceSide.customer), '预收有余 200.00 美金');
      expect(balance.headline(PartyBalanceSide.supplier), '可抵有余 200.00 美金');
      expect(
        PartyOpenBalance.fromJson(
          json(net: '0'),
        )!.headline(PartyBalanceSide.customer),
        '0.00 美金',
      );
    });

    test('其它币种各用自己的币种、不换算，原币未核实按本币单列', () {
      final balance = PartyOpenBalance.fromJson(
        json(
          others: [
            {
              'currencyId': 'cny',
              'currencyName': '人民币',
              'baseCurrency': true,
              'openOriginal': '30000',
              'creditOriginal': '0',
              'netOriginal': '30000',
            },
            {
              'currencyId': 'hkd',
              'currencyName': '港币',
              'openOriginal': '0',
              'creditOriginal': '500',
              'netOriginal': '-500',
            },
          ],
          unverified: '1200.5',
        ),
      )!;
      expect(
        balance.footnote(PartyBalanceSide.customer),
        '另有 30000.00 元、预收有余 500.00 港币；'
            '另有历史应收 1200.50 元 原币未核实',
      );
      expect(
        balance.unverifiedText(PartyBalanceSide.supplier),
        '另有历史应付 1200.50 元 原币未核实',
      );
    });

    test('服务端没给或不是对象时为 null，不猜 0', () {
      expect(PartyOpenBalance.fromJson(null), isNull);
      expect(PartyOpenBalance.fromJson('12000'), isNull);
      final sparse = PartyOpenBalance.fromJson({'currencyName': '美金'})!;
      expect(sparse.headline(PartyBalanceSide.customer), '0.00 美金');
      expect(sparse.creditLimitLocal, isNull);
      // 本位币名缺失 → 不猜币种，只显金额。
      expect(sparse.baseMoneyText('10'), '10.00');
    });
  });
}
