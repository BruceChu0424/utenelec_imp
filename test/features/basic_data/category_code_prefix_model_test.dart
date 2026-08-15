import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';

void main() {
  test(
    'category detail parses editable remark prefix and optimistic version',
    () {
      final detail = ProductCategoryDetail.fromJson(const {
        'id': 'category-uuid',
        'code': 'MC000001',
        'name': '阀体',
        'level': 2,
        'path': '成品 > 阀体',
        'childCount': 3,
        'remark': '旧编码 A-06',
        'legacyCodeSnapshot': 'A-06',
        'codePrefix': 'V6',
        'effectivePrefix': 'V6',
        'version': 7,
      });

      expect(detail.code, 'MC000001');
      expect(detail.remark, '旧编码 A-06');
      expect(detail.legacyCodeSnapshot, 'A-06');
      expect(detail.codePrefix, 'V6');
      expect(detail.effectivePrefix, 'V6');
      expect(detail.version, 7);
    },
  );

  test(
    'category update explicitly sends empty prefix to inherit from parent',
    () {
      const input = ProductCategoryUpdateInput(
        name: '子分类',
        codePrefix: '',
        remark: '备注',
        version: 4,
      );

      expect(input.toJson(), {
        'name': '子分类',
        'codePrefix': '',
        'remark': '备注',
        'version': 4,
      });
    },
  );

  test('prefix preview parses conflicts and descendant overrides', () {
    final preview = CategoryPrefixPreview.fromJson(const {
      'categoryId': 'category-uuid',
      'currentPrefix': 'HP',
      'requestedPrefix': 'V6',
      'resultingEffectivePrefix': 'V6',
      'affectedRecords': 18,
      'customOrLegacyRecords': 2,
      'descendantOverrides': 1,
      'conflicts': 1,
      'conflictSamples': ['V6000012'],
    });

    expect(preview.affectedRecords, 18);
    expect(preview.customOrLegacyRecords, 2);
    expect(preview.descendantOverrides, 1);
    expect(preview.conflictSamples, ['V6000012']);
  });
}
