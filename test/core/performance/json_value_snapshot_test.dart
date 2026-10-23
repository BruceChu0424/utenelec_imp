import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/json_value_snapshot.dart';

void main() {
  test('detaches nested inputs and retains large immutable attachment', () {
    final attachment = base64Encode(List<int>.filled(10 * 1024 * 1024, 123));
    final rows = <Map<String, dynamic>>[
      {
        'qty': '0001.',
        'note': '未完成输入\n原文',
        'checks': <bool>[true, false],
      },
    ];
    final source = <String, dynamic>{'rows': rows, 'bytes': attachment};
    final snapshot = JsonValueSnapshot.capture(source);
    expect(identical(snapshot.data['bytes'], attachment), isTrue);
    expect(snapshot.matches(source), isTrue);
    rows.first['qty'] = '0001.2';
    expect(snapshot.matches(source), isFalse);
    expect(((snapshot.data['rows'] as List).first as Map)['qty'], '0001.');
    expect(
      () => (snapshot.data['rows'] as List).clear(),
      throwsUnsupportedError,
    );
  });

  test('detects nested changes, missing nulls, and numeric spellings', () {
    final source = <String, dynamic>{
      'value': null,
      'rows': <Object?>[1, 0.0, '1.0000000000000000001', false],
    };
    final snapshot = JsonValueSnapshot.capture(source);
    expect(
      snapshot.matches(jsonDecode(jsonEncode(source)) as Map<String, dynamic>),
      isTrue,
    );
    source.remove('value');
    expect(snapshot.matches(source), isFalse);
    source['value'] = null;
    (source['rows'] as List)[0] = 1.0;
    expect(snapshot.matches(source), isFalse);
    (source['rows'] as List)[0] = 1;
    (source['rows'] as List)[1] = -0.0;
    expect(snapshot.matches(source), isFalse);
  });
}
