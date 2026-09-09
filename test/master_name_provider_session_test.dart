import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/role.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  test(
    'planning resolves actual ancestors without changing the leaf identity',
    () {
      const hierarchy = [
        WarehouseDictEntry(id: 'main', name: '主仓'),
        WarehouseDictEntry(id: 'area', name: '分区', parentId: 'main'),
        WarehouseDictEntry(id: 'leaf', name: '子仓', parentId: 'area'),
      ];
      expect(
        MasterDictionaryService.resolveMainWarehouse(hierarchy, 'leaf')?.id,
        'main',
      );
      expect(
        MasterDictionaryService.resolveMainWarehouse(hierarchy, 'main')?.id,
        'main',
      );
      expect(hierarchy.last.id, 'leaf');
    },
  );

  test('missing parents and cycles never become invented main warehouses', () {
    const hierarchy = [
      WarehouseDictEntry(id: 'orphan', name: '未知上级', parentId: 'missing'),
      WarehouseDictEntry(id: 'a', name: 'A', parentId: 'b'),
      WarehouseDictEntry(id: 'b', name: 'B', parentId: 'a'),
    ];
    expect(
      MasterDictionaryService.resolveMainWarehouse(hierarchy, 'orphan'),
      isNull,
    );
    expect(
      MasterDictionaryService.resolveMainWarehouse(hierarchy, 'a'),
      isNull,
    );
    expect(
      MasterDictionaryService.resolveMainWarehouse(hierarchy, 'unknown'),
      isNull,
    );
  });

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
