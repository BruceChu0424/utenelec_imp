import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/employee/pages/employee_offboarding_workflow_page.dart';

void main() {
  test('离职类型使用后端稳定码', () {
    expect(StableResignType.voluntary.code, 'VOLUNTARY');
    expect(StableResignType.dismissed.code, 'DISMISSED');
    expect(StableResignType.contractEnd.code, 'CONTRACT_END');
    expect(StableResignType.retire.code, 'RETIRE');
  });
}
