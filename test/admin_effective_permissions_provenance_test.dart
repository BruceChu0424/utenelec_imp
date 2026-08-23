import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';

void main() {
  test('effective permissions preserve manager and legacy provenance', () {
    final value = EffectivePermissions.fromJson({
      'departmentPermissions': ['sales_order:view'],
      'baselinePermissions': ['notice:read'],
      'grants': ['sales_order:edit', 'audit_log:view'],
      'confirmedGrants': ['sales_order:edit'],
      'legacyUnknownGrants': ['audit_log:view'],
      'legacyUnknownRevokes': ['stock:view'],
      'managerGrants': ['sales_quote:edit'],
      'revokes': ['stock:view'],
      'effective': [
        'sales_order:view',
        'notice:read',
        'sales_order:edit',
        'audit_log:view',
        'sales_quote:edit',
      ],
      'superAdmin': false,
    });

    expect(value.confirmedGrants, ['sales_order:edit']);
    expect(value.legacyUnknownGrants, ['audit_log:view']);
    expect(value.legacyUnknownRevokes, ['stock:view']);
    expect(value.managerGrants, ['sales_quote:edit']);
    expect(value.effective, isNot(contains('stock:view')));
  });
}
