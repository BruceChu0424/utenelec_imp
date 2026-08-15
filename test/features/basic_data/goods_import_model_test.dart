import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_import.dart';

void main() {
  test('detect report keeps the short-lived commit plan id', () {
    final report = GoodsImportReport.fromJson({
      'totalRows': 1,
      'dataRows': 1,
      'errors': <Object?>[],
      'willCreateCategories': <Object?>[],
      'willCreateColors': <Object?>[],
      'willCreateUnits': <Object?>[],
      'readyToImport': 1,
      'planId': '6d81ea14-947b-4f1b-a4fc-8130ca6546ab',
    });

    expect(report.planId, '6d81ea14-947b-4f1b-a4fc-8130ca6546ab');
    expect(report.hasErrors, isFalse);
  });

  test('invalid detect report has no commit capability', () {
    final report = GoodsImportReport.fromJson({
      'totalRows': 1,
      'dataRows': 1,
      'errors': [
        {'rowNum': 2, 'column': '主颜色', 'message': '名称存在多个主档记录'},
      ],
      'readyToImport': 0,
    });

    expect(report.planId, isNull);
    expect(report.hasErrors, isTrue);
  });
}
