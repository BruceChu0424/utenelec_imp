// 人民币大写金额单测（银发〔1997〕393 号附一口径：
// 壹贰叁…拾佰仟万亿；前缀「人民币」；到元写整、有分不写整；零的补位规则）。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/utils/rmb_amount.dart';

void main() {
  test(
    'currency inputs preserve integer cents and reject rounding or exponents',
    () {
      expect(parseExpenseAmountCents('84.80'), 8480);
      expect(parseExpenseAmountCents('0.01'), 1);
      expect(parseExpenseAmountCents('9999999999.99'), 999999999999);
      expect(parseExpenseAmountCents('0'), isNull);
      expect(parseExpenseAmountCents('0', allowZero: true), 0);
      for (final invalid in [
        '1.005',
        '1e3',
        'NaN',
        '-2.00',
        '10000000000',
        '1,000',
      ]) {
        expect(parseExpenseAmountCents(invalid), isNull, reason: invalid);
      }
    },
  );

  test('整元写整', () {
    expect(rmbCapital(100), '人民币壹佰元整');
    expect(rmbCapital(0), '人民币零元整');
    expect(rmbCapital(100000000), '人民币壹亿元整');
  });

  test('角分读法', () {
    expect(rmbCapital(0.5), '人民币伍角');
    expect(rmbCapital(10.05), '人民币壹拾元零伍分');
    expect(rmbCapital(10203.5), '人民币壹万零贰佰零叁元伍角');
    expect(rmbCapital(2008.09), '人民币贰仟零捌元零玖分');
    expect(rmbCapital(0.05), '人民币伍分');
  });

  test('段间补零与跳零段', () {
    expect(rmbCapital(10001), '人民币壹万零壹元整');
    expect(rmbCapital(10100), '人民币壹万零壹佰元整');
    expect(rmbCapital(1000000), '人民币壹佰万元整');
    expect(rmbCapital(1000010), '人民币壹佰万零壹拾元整');
    expect(rmbCapital(100000001), '人民币壹亿零壹元整');
    expect(rmbCapital(11009), '人民币壹万壹仟零玖元整');
  });

  test('万亿段与四舍五入到分', () {
    expect(rmbCapital(1234567890.12), '人民币壹拾贰亿叁仟肆佰伍拾陆万柒仟捌佰玖拾元壹角贰分');
    expect(rmbCapital(0.005), '人民币壹分');
    expect(rmbCapital(1.004), '人民币壹元整');
  });

  test('非法输入返回空串', () {
    expect(rmbCapital(-1), '');
    expect(rmbCapital(double.nan), '');
    expect(rmbCapital(double.infinity), '');
  });
}
