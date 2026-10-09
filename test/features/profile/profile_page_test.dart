import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/features/department/providers/my_department_providers.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/profile/models/profile_change_request.dart';
import 'package:uten_imp/features/profile/pages/profile_page.dart';
import 'package:uten_imp/features/profile/providers/profile_change_providers.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('expanded profile content grows with the available width', (
    tester,
  ) async {
    await _pumpProfilePage(tester, () async => _completeProfile);

    final content = find.byType(TabBarView);
    expect(content, findsOneWidget);
    final initialWidth = tester.getSize(content).width;
    expect(initialWidth, greaterThan(720));

    await tester.binding.setSurfaceSize(const Size(1800, 2200));
    await tester.pumpAndSettle();

    expect(tester.getSize(content).width, closeTo(initialWidth + 400, 0.01));
    expect(find.text('DTO-CODE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'EmployeeProfile overrides stale session identity and shows aligned fields',
    (tester) async {
      await _pumpProfilePage(tester, () async => _completeProfile);

      // Hero 身份恒可见：一律以本人档案 DTO 为准，不吃 session 陈旧字段。
      expect(find.text('DTO Name'), findsWidgets);
      expect(find.text('DTO-CODE'), findsOneWidget);
      expect(
        find.textContaining('DTO Department · DTO Position'),
        findsWidgets,
      );
      expect(find.text('Session Name'), findsNothing);
      expect(find.text('SESSION-CODE'), findsNothing);
      expect(find.text('Session Department'), findsNothing);
      expect(find.text('Session Position'), findsNothing);

      // Tab 1 基本信息（默认打开）：人口属性 + 策略徽章。
      expect(find.text('\u6027\u522b'), findsOneWidget);
      expect(find.text('\u8bc1\u4ef6\u7c7b\u578b'), findsOneWidget);
      expect(find.text('\u8bc1\u4ef6\u53f7\u7801'), findsOneWidget);
      expect(find.text('可直接修改'), findsWidgets);
      expect(find.text('需 HR 审核后生效'), findsWidgets);
      expect(find.text('请联系人事修改'), findsWidgets);
      await tester.dragUntilVisible(
        find.text('\u7d27\u6025\u8054\u7cfb\u4eba'),
        find.byType(ListView),
        const Offset(0, -160),
      );

      // Tab 2 组织与合同：组织信息 + 合同摘要；薪酬不外泄。
      await tester.tap(find.text('\u7ec4\u7ec7\u4e0e\u5408\u540c'));
      await tester.pumpAndSettle();
      expect(find.text('DTO Department'), findsOneWidget);
      expect(find.text('DTO Position'), findsOneWidget);
      expect(find.text('\u76f4\u5c5e\u4e0a\u7ea7'), findsOneWidget);
      expect(find.text('\u8f6c\u6b63\u65e5\u671f'), findsOneWidget);
      expect(find.text('\u7528\u5de5\u5f62\u5f0f'), findsOneWidget);
      expect(find.text('\u5408\u540c\u6458\u8981'), findsOneWidget);
      expect(find.text('SECRET-SALARY'), findsNothing);
      expect(find.text('SECRET-BANK'), findsNothing);
      await tester.dragUntilVisible(
        find.textContaining(
          '\u85aa\u916c\u4e0e\u94f6\u884c\u4fe1\u606f\u4e0d\u4f1a',
        ),
        find.byType(ListView),
        const Offset(0, -160),
      );
      expect(
        find.textContaining(
          '\u85aa\u916c\u4e0e\u94f6\u884c\u4fe1\u606f\u4e0d\u4f1a',
        ),
        findsOneWidget,
      );

      // Tab 4 任职记录：轨迹段落存在（tab 标签 + 段落标题同文）。
      await tester.tap(find.text('\u4efb\u804c\u8bb0\u5f55'));
      await tester.pumpAndSettle();
      expect(find.text('\u4efb\u804c\u8bb0\u5f55'), findsWidgets);
    },
  );

  testWidgets('loading profile is not rendered as empty field placeholders', (
    tester,
  ) async {
    final completer = Completer<EmployeeProfile?>();
    addTearDown(() {
      if (!completer.isCompleted) completer.complete(null);
    });

    await _pumpProfilePage(tester, () => completer.future, settle: false);

    expect(
      find.textContaining('\u6b63\u5728\u52a0\u8f7d\u5458\u5de5\u6863\u6848'),
      findsOneWidget,
    );
    expect(find.text('\u672a\u586b\u5199'), findsNothing);
  });

  testWidgets('profile load failure offers retry and recovers', (tester) async {
    var attempts = 0;
    await _pumpProfilePage(tester, () async {
      attempts += 1;
      if (attempts == 1) throw StateError('offline');
      return _completeProfile;
    });

    expect(
      find.text('\u5458\u5de5\u6863\u6848\u52a0\u8f7d\u5931\u8d25'),
      findsOneWidget,
    );
    expect(find.text('\u91cd\u8bd5'), findsOneWidget);

    await tester.tap(find.text('\u91cd\u8bd5'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('DTO Name'), findsWidgets);
  });

  testWidgets('unbound account has an explicit profile state', (tester) async {
    await _pumpProfilePage(tester, () async => null);

    expect(
      find.text(
        '\u5f53\u524d\u8d26\u53f7\u672a\u7ed1\u5b9a\u5458\u5de5\u6863\u6848',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        '\u8d26\u53f7\u4e0e\u5458\u5de5\u6863\u6848\u7ed1\u5b9a',
      ),
      findsOneWidget,
    );
    expect(find.text('\u672a\u586b\u5199'), findsNothing);
  });

  testWidgets('compact profile keeps the same field scope without overflow', (
    tester,
  ) async {
    await _pumpProfilePage(
      tester,
      () async => _completeProfile,
      size: const Size(375, 812),
    );

    expect(find.text('DTO Name'), findsWidgets);
    expect(find.text('\u6027\u522b'), findsOneWidget);
    // Tab 内 ListView 懒构建：滚动后应能到达同 Tab 下方的紧急联系人段。
    await tester.dragUntilVisible(
      find.text('\u7d27\u6025\u8054\u7cfb\u4eba'),
      find.byType(ListView),
      const Offset(0, -120),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'small desktop window (840-1200) stays single-column with inline shortcuts',
    (tester) async {
      // 2026-10-09 复现口径：958 宽小屏窗口。旧版在断点 840 即切「左 380 固定 +
      // 右 Tab」双列，右栏仅 ~470：Tab 横向截断、字段行触发 <480 两行堆叠。
      await _pumpProfilePage(
        tester,
        () async => _completeProfile,
        size: const Size(958, 944),
      );

      // 单列折叠布局（同员工详情页范式），不再是固定左栏双列。
      expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);

      // 「我的部门 / 我的修改申请」并排：两个入口图标同一水平线。
      final deptIcon = tester
          .getTopLeft(find.byIcon(Icons.account_tree_rounded))
          .dy;
      final changesIcon = tester
          .getTopLeft(find.byIcon(Icons.assignment_outlined))
          .dy;
      expect(deptIcon, changesIcon);

      // 字段行保持单行（标签与值同一水平线）——双列挤压时值会被挤到第二行。
      final labelDy = tester.getTopLeft(find.text('\u5de5\u53f7')).dy;
      final valueDy = tester.getTopLeft(find.text('DTO-CODE')).dy;
      expect(labelDy, valueDy);

      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpProfilePage(
  WidgetTester tester,
  Future<EmployeeProfile?> Function() loadProfile, {
  bool settle = true,
  Size size = const Size(1400, 2200),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(_ProfileSessionNotifier.new),
        myEmployeeProfileProvider.overrideWith((ref) => loadProfile()),
        myDepartmentTreeProvider.overrideWith((ref) async => const []),
        myProfileChangesProvider.overrideWith(
          (ref, key) async => const ProfileChangePage<MyProfileChangeListItem>(
            items: [],
            page: 1,
            size: 20,
            total: 0,
            totalPages: 0,
          ),
        ),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: ProfilePage(),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

class _ProfileSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'user-1',
      code: 'SESSION-CODE',
      name: 'Session Name',
      department: 'Session Department',
      position: 'Session Position',
      employeeId: 'stale-employee-id',
    ),
  );
}

const _completeProfile = EmployeeProfile(
  id: 'employee-1',
  code: 'DTO-CODE',
  fullName: 'DTO Name',
  gender: 'male',
  idType: 'idCard',
  idNumber: '510***********1234',
  birthDate: '1990-01-02',
  ethnicity: 'Han',
  politicalStatus: 'Member',
  maritalStatus: 'Married',
  hujiAddress: 'Registered Address',
  residenceAddress: 'Residence Address',
  departmentName: 'DTO Department',
  positionName: 'DTO Position',
  supervisorName: 'Supervisor Name',
  hireDate: '2020-03-04',
  confirmedAt: '2020-06-04',
  status: 'active',
  employmentType: 'regular',
  workLocation: 'Factory A',
  seatNo: 'A-18',
  phone: '13812345678',
  officePhone: '0755-12345678',
  email: 'dto@example.com',
  contractType: 'fixed',
  contractStart: '2025-01-01',
  contractEnd: '2027-12-31',
  probationMonths: 3,
  probationEndDate: '2020-06-04',
  renewCount: 1,
  accountStatus: 'locked',
  baseSalary: 'SECRET-SALARY',
  bankAccount: 'SECRET-BANK',
  emergencyContacts: [
    EmergencyContactView(
      id: 'contact-1',
      name: 'Emergency Name',
      phone: '13912345678',
      relationship: 'Parent',
    ),
  ],
  history: [
    EmploymentHistoryView(
      id: 'history-1',
      eventType: 'transfer',
      fromDeptName: 'Old Department',
      toDeptName: 'DTO Department',
      eventDate: '2025-02-03',
      remark: 'Approved',
    ),
  ],
);
