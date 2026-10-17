import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';

void main() {
  test('keywords survive canonical aliases and discard unknown columns', () {
    final controller = PlatformTableController<String>();
    addTearDown(controller.dispose);
    controller.binding = PlatformTableBinding<String>(
      tableKey: 'test',
      scope: 'test',
      recordIdOf: (r) => r,
      columnAliases: const {'goodsName': 'name'},
    );
    controller.saveQuery(
      filters: {
        'search.goodsName': '开关',
        'goodsName': '单联开关',
        'search.removed': 'old',
      },
    );
    expect(controller.layout.filters['search.name'], '开关');
    final restored = controller.localLayout(['goodsName'], defaultHidden: {});
    expect(restored.filters, {'search.goodsName': '开关', 'goodsName': '单联开关'});
  });
}
