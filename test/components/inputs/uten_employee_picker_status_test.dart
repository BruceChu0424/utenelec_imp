import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/models/impersonation.dart';
import 'package:uten_imp/features/basic_data/models/client_access_models.dart';
import 'package:uten_imp/features/basic_data/repositories/warehouse_keeper_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/notice/models/notice_audience.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_models.dart';
import 'package:uten_imp/shared/formatters/employee_display.dart';
import 'package:uten_imp/shared/handover/data_handover_models.dart';

void main() {
  test('账号和在职状态独立，旧接口缺少字段不冒充未开通', () {
    expect(employeeAccountStatusLabel('notProvisioned'), '未开通');
    expect(employeeAccountStatusLabel('active'), '已开通');
    expect(employeeAccountStatusLabel('locked'), '锁定');
    expect(employeeAccountStatusLabel('disabled'), '停用');
    expect(employeeAccountStatusLabel('deleted'), '已删除');
    expect(employeeAccountStatusLabel(null), '未提供');
    expect(employeeEmploymentStatusLabel('active'), '在职');
    expect(employeeEmploymentStatusLabel('probation'), '试用');
    expect(employeeEmploymentStatusLabel('onLeave'), '休假');
    expect(employeeEmploymentStatusLabel('resigned'), '离职');
    expect(employeeEmploymentStatusLabel('notApplicable'), '不适用');
  });

  final parsers = <String, (String?, String?) Function(Map<String, dynamic>)>{
    '开通账号': (json) {
      final item = AccountProvisionCandidate.fromJson(json);
      return (item.accountStatus, item.employmentStatus);
    },
    '审计人员': (json) {
      final item = AuditActorOption.fromJson(json);
      return (item.accountStatus, item.employmentStatus);
    },
    '代操作': (json) {
      final item = ImpersonationTarget.fromJson(json);
      return (item.accountStatus, item.employmentStatus);
    },
    '客户授权': (json) {
      final item = ClientAccessCandidate.fromJson(json);
      return (item.accountStatus, item.employmentStatus);
    },
    '仓库负责人': (json) {
      final item = WarehouseKeeper.fromJson(json);
      return (item.accountStatus, item.employmentStatus);
    },
    '交接人员': (json) {
      final item = DataHandoverCandidate.fromJson(json);
      return (item.accountStatus, item.employmentStatus);
    },
    '通知人员': (json) {
      final item = NoticeAudienceEmployee.fromJson(json);
      return (item.accountStatus, item.employmentStatus);
    },
    '页面授权': (json) {
      final item = PagePermissionStaffSummary.fromJson(json);
      return (item.accountStatus, item.employmentStatus);
    },
    '数据归属': (json) {
      final item = DataScopeOwner.fromJson(json);
      return (item.accountStatus, item.employmentStatus);
    },
  };
  for (final entry in parsers.entries) {
    test('${entry.key}候选保留服务端独立状态且不推测缺失账号信息', () {
      final json = <String, dynamic>{
        'id': 'employee-1',
        'employeeId': 'employee-1',
        'actorId': 'account-1',
        'name': '测试员工',
        'code': 'TEST001',
        'accountStatus': 'locked',
        'employmentStatus': 'onLeave',
        'hasAccount': false,
        'activeAccount': false,
      };
      final candidate = entry.value(json);
      expect(candidate.$1, 'locked');
      expect(candidate.$2, 'onLeave');
      json.remove('accountStatus');
      expect(entry.value(json).$1, isNull);
    });
  }

  testWidgets('员工表格同时显示账号与在职状态，选中不改业务资格', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const candidates = [
      UtenEmployeePickerItem(
        id: 'locked',
        name: '锁定休假员工',
        employeeCode: 'T1',
        accountStatus: 'locked',
        employmentStatus: 'onLeave',
      ),
      UtenEmployeePickerItem(
        id: 'new',
        name: '未开通试用员工',
        employeeCode: 'T2',
        accountStatus: 'notProvisioned',
        employmentStatus: 'probation',
      ),
      UtenEmployeePickerItem(
        id: 'former',
        name: '历史离职员工',
        employeeCode: 'T3',
        accountStatus: 'disabled',
        employmentStatus: 'resigned',
        enabled: false,
        disabledReason: '本操作不可选离职员工',
      ),
    ];
    List<UtenEmployeePickerItem>? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenEmployeeSelectionPanel(
            loader: (_) async => candidates,
            departmentTreeLoader: () async => [],
            onConfirm: (items) => selected = items,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<UtenEmployeePickerItem>>(
      find.byType(MasterDataTableView<UtenEmployeePickerItem>),
    );
    expect(table.columns.map((c) => c.label), containsAll(['账号状态', '在职状态']));
    expect(find.text('锁定'), findsOneWidget);
    expect(find.text('休假'), findsOneWidget);
    expect(find.text('未开通'), findsOneWidget);
    expect(find.text('试用'), findsOneWidget);
    expect(find.text('停用'), findsOneWidget);
    expect(find.text('离职'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('employee-picker-item-former')));
    await tester.pumpAndSettle();
    expect(find.text('未选择'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('employee-picker-item-locked')));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(selected!.single.id, 'locked');
    expect(selected!.single.accountStatus, 'locked');
    expect(selected!.single.employmentStatus, 'onLeave');
  });
}
