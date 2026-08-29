import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/authorize_all_excluded.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  const permission = Perm.accountBalanceAdjust;

  test('account balance adjustment is excluded from authorize-all', () {
    expect(kAuthorizeAllExcluded, contains(permission));
  });

  test('department permission UI excludes account balance adjustment', () {
    final source = File(
      'lib/features/admin/widgets/admin_department_perm_view.dart',
    ).readAsStringSync();

    expect(source, contains('Perm.accountBalanceAdjust'));
    expect(source, contains('只能在个人授权中点名配置'));
  });
}
