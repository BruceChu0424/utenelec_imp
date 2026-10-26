import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/export/master_export_job.dart';

void main() {
  test(
    'sets, booleans, exact decimals and column searches retain typed filter structure',
    () {
      final parameters = masterExportJobParameters('goods', {
        'categoryRootIds': {'one', 'two'},
        'nullFields': 'unitRef,colorRef',
        'excludeDisabled': 'false',
        'includeRelated': '1',
        'search.name': '=original input',
        'sort': 'code',
        'order': 'desc',
        'page': 9,
        'size': 100,
        'password': 'do-not-store',
      }, {});
      final filter = jsonDecode(parameters['filter'] as String) as Map;
      expect(filter['categoryRootIds'], ['one', 'two']);
      expect(filter['nullFields'], ['unitRef', 'colorRef']);
      expect(filter['excludeDisabled'], false);
      expect(filter['includeRelated'], true);
      expect(filter['columnSearch'], {'name': '=original input'});
      expect(filter, isNot(contains('password')));
      expect(filter, isNot(contains('page')));
      expect(parameters['sort'], 'code');
      final decimals = masterExportJobParameters('client', {
        'credit': '12345678901234567890.000100',
      }, {});
      expect(
        (jsonDecode(decimals['filter'] as String) as Map)['credit'],
        '12345678901234567890.000100',
      );
    },
  );
  test('contacts preserve body-only precedence and nested column search', () {
    final parameters = masterExportJobParameters(
      'client',
      {
        'keyword': 'ignored-query',
        'mobile': 'ignored-query',
        'search.name': '客户',
      },
      {
        'sensitiveFilter': {
          'keyword': '=raw',
          'mobile': '00123',
          'bankAccount': '00000001',
          'columnSearch': {'phone': '+0123'},
        },
      },
    );
    final filter = jsonDecode(parameters['filter'] as String) as Map;
    expect(filter['keyword'], '=raw');
    expect(filter['mobile'], '00123');
    expect(filter['bankAccount'], '00000001');
    expect(filter['columnSearch'], {'name': '客户', 'phone': '+0123'});
    expect(parameters.keys, ['filter']);
    expect(
      () => masterExportJobParameters('supplier', {
        'search.mobile': 'unsafe-url',
      }, {}),
      throwsFormatException,
    );
  });
}
