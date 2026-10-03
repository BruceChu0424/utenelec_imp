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
        // 2026-10-02 初始密码改系统随机：provisionable 只看手机号。
        expect(candidate.provisionable, phone);
        expect(candidate.missingHint.contains('缺手机号'), !phone);
        // 证件号不再是开通条件，不再出现在缺失提示里。
      });
    }
  }
}
