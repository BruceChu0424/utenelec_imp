import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/platform_settings_catalog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('configuration entries follow destination any/all permissions', () {
    final ids = platformSettingsEntriesFor(const {
      Perm.expenseSettings,
      Perm.accountSupport,
      Perm.goodsView,
      Perm.materialCategoryView,
    }, false).map((entry) => entry.id);
    expect(
      ids,
      containsAll(['expense', 'permissions', 'basic-data', 'personal']),
    );
    expect(ids, isNot(contains('security')));
    expect(ids, isNot(contains('ai')));
    expect(ids, isNot(contains('audit')));
    expect(ids, isNot(contains('workshop-material')));
    // A goods row grant alone does not include the list's category-tree grant.
    expect(
      platformSettingsEntriesFor(const {
        Perm.goodsView,
      }, false).map((entry) => entry.id),
      isNot(contains('basic-data')),
    );
  });

  test(
    'configuration catalog preserves audit and server status separation',
    () {
      expect(
        platformSettingsEntriesFor(const {
          Perm.auditLogView,
        }, false).map((entry) => entry.id),
        ['audit', 'personal'],
      );
      expect(
        platformSettingsEntriesFor(const {
          Perm.serverStatusView,
        }, false).map((entry) => entry.id),
        ['server-status', 'personal'],
      );
    },
  );
}
