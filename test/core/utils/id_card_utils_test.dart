// 身份证号「具体哪里不对」：客户端 IdCardUtils.problemOf 与后端 IdCardUtil.check
// 同一检查顺序、同一句话(只说位置和长度，不回显号码)。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/security/input_validators.dart';
import 'package:uten_imp/core/utils/id_card_utils.dart';

const _valid = '11010519491231002X';

const _checkDigitMessage = '身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对';

/// (输入, 期望文案)。除被测那一项外其余位都合法(校验位已按 GB11643 算好)，
/// 用来锁住检查顺序。
const _cases = <(String?, String?)>[
  (_valid, null),
  ('11010519491231002x', null),
  ('  11010519491231002X  ', null),
  ('１１０１０５１９４９１２３１００２Ｘ', null),
  ('440304200002291236', null),
  (null, '身份证号不能为空'),
  ('', '身份证号不能为空'),
  ('   ', '身份证号不能为空'),
  ('11010519491231002', '身份证号应为18位，当前为17位'),
  ('11010519491231002X1', '身份证号应为18位，当前为19位'),
  ('A1010519491231002X', '身份证号第1位不是数字(只有第18位可以是X)'),
  ('1101051949123100XX', '身份证号第17位不是数字(只有第18位可以是X)'),
  ('11010519491231002Y', '身份证号第18位只能是数字或X'),
  // 码点计数：emoji 在 UTF-16 里占 2 个单位，但只算 1 位(与后端一致)。
  ('11010519491231002😀', '身份证号第18位只能是数字或X'),
  ('110105194902300020', '身份证号第7-14位不是有效的出生日期'),
  ('110105190002291239', '身份证号第7-14位不是有效的出生日期'),
  ('110105179912310024', '身份证号第7-14位的出生日期早于1800年'),
  ('110105299912310020', '身份证号第7-14位的出生日期晚于今天'),
  ('000000194912310027', '身份证号前6位地区码不能全为0'),
  ('110105194912310003', '身份证号第15-17位顺序码不能全为0'),
  ('110105194912310021', _checkDigitMessage),
];

void main() {
  group('IdCardUtils.problemOf', () {
    for (final (input, expected) in _cases) {
      test('${input ?? 'null'} -> ${expected ?? '合法'}', () {
        expect(IdCardUtils.problemOf(input), expected);
        expect(IdCardUtils.isValid(input), expected == null);
      });
    }

    test('文案只说位置和长度，不回显号码', () {
      for (final (input, expected) in _cases) {
        if (input == null || expected == null) continue;
        final trimmed = input.trim();
        if (trimmed.length < 6) continue;
        final tail = trimmed.substring(trimmed.length - 6);
        expect(
          expected.contains(tail),
          isFalse,
          reason: '第 ${_cases.indexOf((input, expected))} 条用例的文案带出了号码片段',
        );
      }
    });

    test('normalize 与后端同口径：全角折半角、去空白、校验位大写', () {
      expect(IdCardUtils.normalize(' １１０１０５１９４９１２３１００２ｘ '), _valid);
      expect(IdCardUtils.normalize('   '), isNull);
      expect(IdCardUtils.normalize(null), isNull);
    });
  });

  test('InputValidators.idNumber 身份证给具体原因，其他证件只要求非空', () {
    expect(InputValidators.idNumber(_valid), isNull);
    expect(InputValidators.idNumber('11010519491231002'), '身份证号应为18位，当前为17位');
    expect(InputValidators.idNumber('E1234', type: '护照'), isNull);
    expect(InputValidators.idNumber('', type: '护照'), '证件号码不能为空');
  });

  test('客户端文案与后端 IdCardProblem 逐字一致', () {
    final server = File(
      'server/src/main/java/com/uten/imp/common/util/IdCardProblem.java',
    ).readAsStringSync();
    // 固定文案逐字出现在后端；带数字的两句按固定片段比对。
    const fixed = [
      '身份证号不能为空',
      '身份证号第18位只能是数字或X',
      '身份证号第7-14位不是有效的出生日期',
      '身份证号第7-14位的出生日期早于1800年',
      '身份证号第7-14位的出生日期晚于今天',
      '身份证号前6位地区码不能全为0',
      '身份证号第15-17位顺序码不能全为0',
      _checkDigitMessage,
    ];
    for (final message in fixed) {
      expect(server, contains('"$message"'), reason: message);
    }
    expect(server, contains('"身份证号应为18位，当前为"'));
    expect(server, contains('"位不是数字(只有第18位可以是X)"'));
  });

  group('IdCardProblem 问题码', () {
    // (输入, 期望问题码)：问题码就是员工档案里存的证件号校验结果。
    const codes = <(String?, String)>[
      (null, 'empty'),
      ('11010519491231002', 'length:17'),
      ('11010519491231002X1', 'length:19'),
      ('A1010519491231002X', 'character:1'),
      ('1101051949123100XX', 'character:17'),
      ('11010519491231002Y', 'character:18'),
      ('110105194902300020', 'birth_date'),
      ('110105179912310024', 'birth_too_early'),
      ('110105299912310020', 'birth_future'),
      ('000000194912310027', 'region_code'),
      ('110105194912310003', 'sequence_code'),
      ('110105194912310021', 'check_digit'),
    ];

    test('check 给出与后端相同的问题码，problemOf 就是它的说明', () {
      for (final (input, code) in codes) {
        final problem = IdCardUtils.check(input);
        expect(problem?.code, code, reason: input);
        expect(IdCardUtils.problemOf(input), problem?.message, reason: input);
      }
      expect(IdCardUtils.check(_valid), isNull);
    });

    test('存下来的问题码还原成录入时同一句话', () {
      for (final (input, expected) in _cases) {
        final problem = IdCardUtils.check(input);
        if (problem == null) continue;
        expect(IdCardProblem.fromCode(problem.code)?.message, expected);
      }
    });

    test('不认识的问题码返回 null', () {
      for (final code in [
        null,
        '',
        'valid',
        'unchecked',
        'unreadable',
        'length:18',
        'length:',
        'length:1234',
        'length:-1',
        'length:1a',
        'character:0',
        'character:19',
        'character:123',
        'Check_Digit',
      ]) {
        expect(IdCardProblem.fromCode(code), isNull, reason: code);
      }
    });

    test('问题码与后端 IdCardProblem 常量逐字一致', () {
      final server = File(
        'server/src/main/java/com/uten/imp/common/util/IdCardProblem.java',
      ).readAsStringSync();
      for (final code in [
        'empty',
        'length:',
        'character:',
        'birth_date',
        'birth_too_early',
        'birth_future',
        'region_code',
        'sequence_code',
        'check_digit',
      ]) {
        expect(server, contains(' = "$code";'), reason: code);
      }
    });
  });
}
