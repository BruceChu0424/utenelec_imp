import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _FixedSession extends SessionNotifier {
  _FixedSession(this._state);
  final SessionState _state;

  @override
  SessionState build() => _state;
}

/// 前端权限集合只认服务端下发的那一份(ADR-109 / permissions-11)：
/// 超级管理员也不再由前端补一份本地码表——服务端签发令牌时已按目录给出全部码，
/// 前端再拼一份只会和目录漂移(停用码、改名码在前端「复活」)。
void main() {
  ProviderContainer container(AppUser user) {
    final c = ProviderContainer(
      overrides: [
        sessionProvider.overrideWith(
          () => _FixedSession(
            SessionState(status: AuthStatus.authenticated, user: user),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('super admin permissions are exactly the server-issued set', () {
    final c = container(
      const AppUser(
        id: 'root',
        code: 'ADMIN',
        name: '超级管理员',
        superAdmin: true,
        permissions: ['stock:view', 'authorization:manage'],
      ),
    );
    expect(c.read(currentPermissionsProvider), {
      'stock:view',
      'authorization:manage',
    });
    expect(c.read(isSuperAdminProvider), isTrue);
  });

  test('ordinary employee permissions are the server-issued set', () {
    final c = container(
      const AppUser(
        id: 'u1',
        code: 'E001',
        name: '员工',
        permissions: ['stock:view'],
      ),
    );
    expect(c.read(currentPermissionsProvider), {'stock:view'});
    expect(c.read(isSuperAdminProvider), isFalse);
  });

  test('role model and frontend-only code lists are gone', () {
    expect(File('lib/shared/models/role.dart').existsSync(), isFalse);
    final source = File('lib/shared/auth/permissions.dart').readAsStringSync();
    expect(source, isNot(contains('currentRolesProvider')));
    expect(source, isNot(contains('buttonActionCodes')));
  });
}
