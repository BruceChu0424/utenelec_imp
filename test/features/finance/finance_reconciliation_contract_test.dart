import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test(
    'legacy account flow route requires all sensitive account permissions',
    () {
      expect(requiredAnyPermFor(RouteName.financeReconciliations), const [
        Perm.accountFlowView,
      ]);
      expect(requiredAllPermsFor(RouteName.financeReconciliations), const [
        Perm.accountView,
        Perm.accountBalanceView,
        Perm.accountFlowView,
      ]);
    },
  );

  test('reconciliation model preserves V408 reversal lineage', () {
    final item = ReconciliationItem.fromJson(const {
      'id': 'flow-reversal',
      'entryKind': 'REVERSAL',
      'reversalOfId': 'flow-posting',
      'inAmount': 0,
      'outAmount': 12.34,
    });

    expect(item.entryKind, 'REVERSAL');
    expect(item.reversalOfId, 'flow-posting');
  });

  test(
    'legacy account flow page renders V408 kind and source lineage columns',
    () {
      final source = File(
        'lib/features/finance/pages/finance_reconciliation_page.dart',
      ).readAsStringSync();

      expect(source, contains("key: 'entryKind'"));
      expect(source, contains("key: 'reversalOfId'"));
      expect(source, contains('反向冲销'));
      expect(source, contains('原流水 UUID'));
    },
  );
}
