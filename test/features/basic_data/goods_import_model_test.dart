import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_import.dart';

void main() {
  test(
    'preview preserves clean rows, raw cells and resolved category segments',
    () {
      final report = GoodsImportReport.fromJson({
        'previewRows': [
          {
            'rowNum': 2,
            'code': '0001',
            'name': '开关',
            'categoryPath': '成品-20A/45A',
            'categorySegments': ['成品', '20A/45A'],
            'cells': {'code': '0001', 'price': '1.23000001'},
          },
        ],
        'readyRowNums': [2],
      });
      expect(report.previewRows.single.code, '0001');
      expect(report.previewRows.single.cells['price'], '1.23000001');
      expect(report.previewRows.single.categorySegments, ['成品', '20A/45A']);
      expect(report.readyRowNums, [2]);
    },
  );
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

  test(
    'review preserves numeric text, fills and stable selection identities',
    () {
      final report = GoodsImportReport.fromJson({
        'reviewRows': [
          {
            'rowKey': 'goods:5',
            'rowNum': 5,
            'code': 'A001',
            'name': '配件',
            'categoryPath': '成品-配件',
            'matchType': 'CODE',
            'changes': [
              {
                'field': 'cNumber',
                'label': '客户型号',
                'oldValue': '00111',
                'newValue': '00222',
                'kind': 'CONFLICT',
              },
              {
                'field': 'paper',
                'label': '备注',
                'oldValue': null,
                'newValue': '新增备注',
                'kind': 'FILL',
              },
            ],
          },
        ],
        'addedRows': 1,
        'fillRows': 1,
        'conflictRows': 1,
        'unchangedRows': 2,
      });
      final row = report.reviewRows.single;
      expect(row.rowKey, 'goods:5');
      expect(row.hasConflicts, isTrue);
      expect(row.changes.first.oldValue, '00111');
      expect(row.changes.first.newValue, '00222');
      expect(row.changes.last.isConflict, isFalse);
      expect(row.changes.last.oldValue, isNull);
      expect(report.unchangedRows, 2);
    },
  );
}
