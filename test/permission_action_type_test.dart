import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_models.dart';
import 'package:uten_imp/shared/auth/permission_action_type.dart';

void main() {
  test(
    'parses the authoritative action taxonomy and fails safe for unknowns',
    () {
      expect(PermissionActionType.fromJson('VIEW'), PermissionActionType.view);
      expect(
        PermissionActionType.fromJson('approve'),
        PermissionActionType.approve,
      );
      expect(
        PermissionActionType.fromJson('future_action'),
        PermissionActionType.other,
      );
      expect(PermissionActionType.fromJson(null), PermissionActionType.other);
    },
  );

  test(
    'admin and page permission models retain action type and description',
    () {
      final admin = AdminPermission.fromJson({
        'id': 'permission-1',
        'code': 'goods:delete',
        'name': '删除货品资料（保留历史）',
        'module': '基础资料',
        'category': '货品资料',
        'actionType': 'DELETE',
        'description': ' 删除货品主档并保留历史引用 ',
      });
      expect(admin.actionType, PermissionActionType.delete);
      expect(admin.description, '删除货品主档并保留历史引用');

      final page = PageStaffPermissionState.fromJson({
        'code': 'goods:delete',
        'name': '删除货品资料（保留历史）',
        'actionType': 'DELETE',
        'description': '删除货品主档并保留历史引用',
        'baseEffective': false,
        'delegationEnabled': true,
        'rowVersion': 3,
        'effective': true,
        'editable': true,
      });
      expect(page.actionType, PermissionActionType.delete);
      expect(page.description, '删除货品主档并保留历史引用');
    },
  );
}
