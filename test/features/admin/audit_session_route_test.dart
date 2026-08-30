import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test(
    'audit session route encodes id, carries snapshot and keeps audit view',
    () {
      final path = RoutePath.adminAuditSession(
        'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        snapshotAuditId: 9001,
      );

      expect(
        path,
        '/admin/audit-logs/sessions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        '?snapshotAuditId=9001',
      );
      expect(requiredAnyPermFor(path), const [Perm.auditLogView]);
      expect(
        requiredAnyPermFor(
          '/admin/audit-logs/sessions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        ),
        const [Perm.auditLogView],
      );
    },
  );
}
