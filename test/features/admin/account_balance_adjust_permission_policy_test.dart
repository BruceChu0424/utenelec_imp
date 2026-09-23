import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

/// 账户余额调整等高风险码能否批量 / 能否配给部门，只看服务端目录下发的授权策略
/// (ADR-109)。前端不再维护本地排除名单：这里既验证按策略渲染，也锁住管理页里
/// 不能再出现按码写死的名单。
void main() {
  const permission = Perm.accountBalanceAdjust;

  test(
    'individual-only policy from the catalog blocks department and bulk',
    () {
      final item = AdminPermission.fromJson({
        'id': 'p1',
        'code': permission,
        'name': '账户余额调整',
        'category': '账户',
        'grantPolicy': ['INDIVIDUAL_ONLY'],
        'baseline': false,
      });

      expect(item.grantPolicy.departmentGrantable, isFalse);
      expect(item.grantPolicy.bulkEligible, isFalse);
      expect(item.grantPolicy.individuallyGrantable, isTrue);
      expect(item.grantPolicy.delegable, isFalse);
      expect(item.grantPolicy.labels, contains('只能逐人授予'));
    },
  );

  test('admin permission pages keep no hard-coded grant lists', () {
    for (final path in [
      'lib/features/admin/widgets/admin_department_perm_view.dart',
      'lib/features/admin/widgets/admin_user_detail_panel.dart',
      'lib/features/admin/widgets/permission_catalog_browser.dart',
      'lib/features/admin/widgets/admin_baseline_perm_view.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('Perm.')), reason: path);
      expect(source, isNot(contains('bulkAssignable')), reason: path);
    }
    expect(
      File('lib/features/admin/authorize_all_excluded.dart').existsSync(),
      isFalse,
    );
  });
}
