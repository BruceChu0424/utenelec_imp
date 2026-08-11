import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/role.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  AppUser user(String id, List<String> permissions) => AppUser(
    id: id,
    code: id,
    name: id,
    roles: const [Role.employee],
    permissions: permissions,
  );

  test('master name cache key changes across accounts', () {
    final accountA = masterDataSessionCacheKey(
      SessionState(status: AuthStatus.authenticated, user: user('A', const [])),
    );
    final accountB = masterDataSessionCacheKey(
      SessionState(status: AuthStatus.authenticated, user: user('B', const [])),
    );

    expect(accountA, isNot(accountB));
  });

  test('master name cache key changes when permissions change', () {
    final before = masterDataSessionCacheKey(
      SessionState(status: AuthStatus.authenticated, user: user('A', const [])),
    );
    final after = masterDataSessionCacheKey(
      SessionState(
        status: AuthStatus.authenticated,
        user: user('A', const ['client:view:all']),
      ),
    );

    expect(before, isNot(after));
  });
}
