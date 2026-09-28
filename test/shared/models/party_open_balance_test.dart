import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/formatters/money_display.dart';
import 'package:uten_imp/shared/models/party_open_balance.dart';

/// ADR-128：往来余额只显示服务端算好的数，按单据币种写成「币种 金额」。
void main() {
  group('financeMoneyWithCurrency', () {
    test('币种名优先，旧数字编号不显示，金额按原文至少两位小数', () {
      expect(
        financeMoneyWithCurrency('158400.0000', currencyName: '美金'),
        '美金 158400.00',
      );
      expect(
        financeMoneyWithCurrency('12.3456', currencyCode: '002'),
        '原币 12.3456',
      );
      expect(
        financeMoneyWithCurrency('5', currencyCode: 'USD', fallback: '订单币种'),
        'USD 5.00',
      );
    });

    test('没有金额时只显示横线，不单挂币种名；非数字原样', () {
      expect(financeMoneyWithCurrency(null, currencyName: '美金'), '—');
      expect(financeMoneyWithCurrency('  ', currencyName: '美金'), '—');
      expect(financeMoneyText('***'), '***');
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

    test('解析服务端视图，单据币种一档写成「币种 金额」', () {
      final balance = PartyOpenBalance.fromJson(json())!;
      expect(balance.openText, '美金 500.00');
      expect(balance.creditText, '美金 100.00');
      expect(balance.headline(PartyBalanceSide.customer), '美金 400.00');
      expect(balance.baseMoneyText(balance.openBookLocal), '人民币 3500.00');
      expect(balance.creditLimitLocal, '3000');
      expect(balance.overLimitLocal, '500');
      expect(balance.overCredit, isTrue);
      expect(balance.footnote(PartyBalanceSide.customer), isNull);
    });

    test('还差多少为负时客户写预收有余、供应商写可抵有余', () {
      final balance = PartyOpenBalance.fromJson(json(net: '-200.0000'))!;
      expect(balance.headline(PartyBalanceSide.customer), '预收有余 美金 200.00');
      expect(balance.headline(PartyBalanceSide.supplier), '可抵有余 美金 200.00');
      expect(
        PartyOpenBalance.fromJson(
          json(net: '0'),
        )!.headline(PartyBalanceSide.customer),
        '美金 0.00',
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
        '另有 人民币 30000.00、预收有余 港币 500.00；'
        '另有历史应收 人民币 1200.50 原币未核实',
      );
      expect(
        balance.unverifiedText(PartyBalanceSide.supplier),
        '另有历史应付 人民币 1200.50 原币未核实',
      );
    });

    test('服务端没给或不是对象时为 null，不猜 0', () {
      expect(PartyOpenBalance.fromJson(null), isNull);
      expect(PartyOpenBalance.fromJson('12000'), isNull);
      final sparse = PartyOpenBalance.fromJson({'currencyName': '美金'})!;
      expect(sparse.headline(PartyBalanceSide.customer), '美金 0.00');
      expect(sparse.creditLimitLocal, isNull);
      expect(sparse.baseMoneyText('10'), '本币 10.00');
    });
  });
}
