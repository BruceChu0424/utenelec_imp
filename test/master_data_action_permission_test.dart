import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('master and organization action codes remain distinct', () {
    expect({
      Perm.goodsCreate,
      Perm.goodsEdit,
      Perm.goodsStatus,
      Perm.goodsDelete,
      Perm.goodsBomCreate,
      Perm.goodsBomEdit,
      Perm.goodsBomDelete,
    }, hasLength(7));
    expect({
      Perm.departmentCreate,
      Perm.departmentEdit,
      Perm.departmentMove,
      Perm.departmentManagerAssign,
      Perm.departmentDelete,
      Perm.positionCreate,
      Perm.positionEdit,
      Perm.positionDelete,
    }, hasLength(8));
  });

  test('category update serializes explicit move-to-root and order', () {
    final json = const ProductCategoryUpdateInput(
      name: '五金',
      codePrefix: 'WJ',
      remark: '',
      version: 3,
      sortOrder: 12,
      moveToRoot: true,
    ).toJson();

    expect(json['moveToRoot'], isTrue);
    expect(json['sortOrder'], 12);
    expect(json.containsKey('parentId'), isFalse);
  });

  test('pages use split action gates and narrow status command', () {
    final goods = File(
      'lib/features/basic_data/pages/product_category_page.dart',
    ).readAsStringSync();
    final payment = File(
      'lib/features/basic_data/pages/payment_style_page.dart',
    ).readAsStringSync();
    final department = File(
      'lib/features/department/pages/department_page.dart',
    ).readAsStringSync();

    expect(goods, contains('Perm.goodsCreate'));
    expect(goods, contains('Perm.goodsStatus'));
    expect(goods, contains('Perm.goodsDelete'));
    expect(goods, contains('masterStatusRepositoryProvider'));
    expect(payment, contains('Perm.paymentStyleMove'));
    expect(payment, contains('Perm.paymentStyleReorder'));
    expect(payment, isNot(contains('Perm.paymentStyleDelete')));
    expect(department, contains('Perm.departmentMove'));
    expect(department, contains('Perm.departmentManagerAssign'));
  });
}
