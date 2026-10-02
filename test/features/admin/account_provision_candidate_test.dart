import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';

void main() {
  for (final phone in [false, true]) {
    for (final identity in [false, true]) {
      test('开户资料 phone=$phone identity=$identity', () {
        final candidate = AccountProvisionCandidate(
          employeeId: 'employee',
          name: '员工',
          code: 'UT0001',
          hasPhone: phone,
          hasIdCard: identity,
        );
        expect(candidate.provisionable, phone && identity);
        expect(candidate.missingHint.contains('缺手机号'), !phone);
        expect(candidate.missingHint.contains('缺证件号'), !identity);
      });
    }
  }
}
