import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';

void main() {
  for (final phone in [false, true]) {
    test('开户资料 phone=$phone', () {
      final candidate = AccountProvisionCandidate(
        employeeId: 'employee',
        name: '员工',
        code: 'UT0001',
        hasPhone: phone,
      );
      // 只有缺手机号会拦开号(手机号就是登录账号)；证件号码缺失或校验不通过
      // 都不拦，确认弹窗提前提醒、开通后人事任务中心跟进核对。
      expect(candidate.provisionable, phone);
      expect(candidate.missingHint.contains('缺手机号'), !phone);
    });
  }

  test('候选解析不再读取证件字段', () {
    final candidate = AccountProvisionCandidate.fromJson(const {
      'employeeId': 'employee',
      'name': '员工',
      'code': 'UT0001',
      'hasPhone': true,
      'hasIdCard': false,
    });
    expect(candidate.provisionable, isTrue);
    expect(candidate.missingHint, isEmpty);
  });
}
