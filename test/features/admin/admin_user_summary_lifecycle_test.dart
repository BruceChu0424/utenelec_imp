import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';

void main() {
  test('parses server-authoritative employment capability', () {
    final user = AdminUserSummary.fromJson({
      'id': 'user-1',
      'loginAccount': '13800000000',
      'status': 'active',
      'roles': <String>[],
      'remoteAccess': false,
      'employeeStatus': 'probation',
      'currentEmployee': true,
    });

    expect(user.employeeStatus, 'probation');
    expect(user.employeeStatusLabel, '试用');
    expect(user.currentEmployee, isTrue);
    expect(user.authorizationGrantAllowed, isTrue);
    expect(user.passwordResetAllowed, isTrue);
  });

  test('missing capability fails closed', () {
    final user = AdminUserSummary.fromJson({
      'id': 'user-1',
      'loginAccount': '13800000000',
      'status': 'active',
      'roles': <String>[],
      'remoteAccess': false,
    });

    expect(user.currentEmployee, isFalse);
    expect(user.authorizationGrantAllowed, isFalse);
    expect(user.passwordResetAllowed, isFalse);
    expect(user.employeeStatusLabel, '任职状态未知');
    expect(user.lifecycleRestrictionReason, contains('无法确认'));
  });

  test('resigned disabled account only keeps allowed recovery direction', () {
    const disabled = AdminUserSummary(
      id: 'user-1',
      loginAccount: '13800000000',
      status: 'disabled',
      mustChangePassword: false,
      roles: [],
      remoteAccess: false,
      employeeStatus: 'resigned',
    );
    const locked = AdminUserSummary(
      id: 'user-1',
      loginAccount: '13800000000',
      status: 'locked',
      mustChangePassword: false,
      roles: [],
      remoteAccess: false,
      employeeStatus: 'resigned',
    );

    expect(disabled.authorizationGrantAllowed, isFalse);
    expect(disabled.passwordResetAllowed, isTrue);
    expect(disabled.lifecycleRestrictionReason, contains('先完成复职流程'));
    expect(locked.passwordResetAllowed, isFalse);
  });
}
