import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';

void main() {
  test('模具系列以真实分类名称回显且保持分类 UUID', () {
    final item = MouldListItem.fromJson({
      'id': 'mould-1',
      'name': 'Q7双联开关模具',
      'categoryId': 'category-1',
      'categoryName': 'Q7系列',
    });
    expect(item.categoryName, 'Q7系列');
    expect(item.categoryId, 'category-1');
    expect(item.name, 'Q7双联开关模具');
  });

  test('旧服务端或无分类名称时不捏造系列值', () {
    final item = MouldListItem.fromJson({'id': 'mould-1', 'name': '历史模具'});
    expect(item.categoryName, isNull);
    expect(item.categoryId, isNull);
  });
}
