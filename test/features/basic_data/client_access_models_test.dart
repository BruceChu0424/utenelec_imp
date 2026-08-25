import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/client_access_models.dart';

void main() {
  test('client access parses authoritative owner and viewer identities', () {
    final settings = ClientAccessSettings.fromJson({
      'clientId': 'client-1',
      'ownerEmployeeId': 'employee-owner',
      'ownerEmployeeName': '负责人甲',
      'accessVersion': 7,
      'viewers': [
        {
          'employeeId': 'employee-viewer',
          'name': '协同人乙',
          'code': 'E002',
          'departmentName': '销售二组',
        },
        {'employeeId': '', 'name': '无效候选'},
      ],
    });

    expect(settings.clientId, 'client-1');
    expect(settings.ownerEmployeeId, 'employee-owner');
    expect(settings.ownerEmployeeName, '负责人甲');
    expect(settings.accessVersion, 7);
    expect(settings.viewers, hasLength(1));
    expect(settings.viewers.single.employeeId, 'employee-viewer');
    expect(settings.viewers.single.code, 'E002');
    expect(settings.viewers.single.departmentName, '销售二组');
  });

  test('client access update emits exact CAS and audit body', () {
    const update = ClientAccessUpdate(
      ownerEmployeeId: 'employee-owner',
      viewerEmployeeIds: ['employee-a', 'employee-b'],
      expectedAccessVersion: 9,
      reason: '  客户交接  ',
    );

    expect(update.toJson(), {
      'ownerEmployeeId': 'employee-owner',
      'viewerEmployeeIds': ['employee-a', 'employee-b'],
      'expectedAccessVersion': 9,
      'reason': '客户交接',
    });
  });

  test('missing optional access fields fail closed to empty values', () {
    final settings = ClientAccessSettings.fromJson(const {});

    expect(settings.clientId, isEmpty);
    expect(settings.ownerEmployeeId, isNull);
    expect(settings.accessVersion, 0);
    expect(settings.viewers, isEmpty);
  });
}
