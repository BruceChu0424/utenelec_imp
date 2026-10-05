// 员工详情页证件问题：顶部常驻提醒(校验未通过红) + 证件号码行「待核对」徽标；
// 持 employee:pii:edit 才有「修改证件信息」，改好后重新读档，提醒随之消失。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_inline_notice.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/models/employee_id_number_issue.dart';
import 'package:uten_imp/features/employee/pages/employee_detail_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _notice = ValueKey('employee-identity-issue-notice');
const _noticeCorrect = ValueKey('employee-identity-issue-correct');
const _badge = ValueKey('employee-id-number-issue-badge');
const _rowCorrect = ValueKey('employee-id-number-correct');

const _invalid = EmployeeIdNumberIssue(
  kind: EmployeeIdNumberIssueKind.invalid,
  reason: '身份证号应为18位，当前为17位',
);

class _DetailRepository extends Fake implements EmployeeRepository {
  EmployeeIdNumberIssue? issue = _invalid;
  int getByIdCalls = 0;
  final changes = <(String, String)>[];

  @override
  Future<EmployeeProfile> getById(String id) async {
    getByIdCalls++;
    return EmployeeProfile(
      id: id,
      code: 'UT0009',
      fullName: '孙七',
      status: 'active',
      idType: '身份证',
      idNumber: '****1234',
      idNumberIssue: issue,
      accountStatus: 'active',
    );
  }

  @override
  Future<void> changeIdentity(
    String id, {
    required String idType,
    required String idNumber,
  }) async {
    changes.add((idType, idNumber));
    issue = null;
  }
}

class _Session extends SessionNotifier {
  _Session(this.permissions);

  final List<String> permissions;

  @override
  SessionState build() => SessionState(
    user: AppUser(
      id: 'hr-user',
      code: 'HR001',
      name: '人事',
      permissions: permissions,
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  _DetailRepository repository,
  List<String> permissions,
) async {
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            const EmployeeDetailPage(employeeId: 'emp-9'),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        employeeRepositoryProvider.overrideWithValue(repository),
        sessionProvider.overrideWith(() => _Session(permissions)),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(UtenBusyOverlay.debugResetYield);

  testWidgets('校验未通过：顶部红色提醒 + 红色待核对徽标，改好后提醒消失', (tester) async {
    final repository = _DetailRepository();
    await _pump(tester, repository, const [
      Perm.employeeView,
      Perm.employeePiiEdit,
    ]);

    final notice = tester.widget<UtenInlineNotice>(
      find.descendant(
        of: find.byKey(_notice),
        matching: find.byType(UtenInlineNotice),
      ),
    );
    expect(notice.level, UtenInlineNoticeLevel.error);
    expect(notice.message, contains('具体问题：身份证号应为18位，当前为17位'));
    final badge = tester.widget<UtenStatusBadge>(find.byKey(_badge));
    expect(badge.label, '待核对');
    expect(badge.type, UtenStatusBadgeType.danger);
    expect(find.byKey(_rowCorrect), findsOneWidget);

    await tester.tap(find.byKey(_noticeCorrect));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('employee-identity-correction-dialog')),
      findsOneWidget,
    );
    final numberField = tester.widget<TextField>(
      find.byKey(const ValueKey('employee-identity-correction-number')),
    );
    expect(numberField.controller!.text, isEmpty, reason: '脱敏值不预填');

    await tester.enterText(
      find.byKey(const ValueKey('employee-identity-correction-number')),
      '11010519491231002X',
    );
    await tester.tap(
      find.byKey(const ValueKey('employee-identity-correction-save')),
    );
    await tester.pumpAndSettle();

    expect(repository.changes, [('身份证', '11010519491231002X')]);
    expect(repository.getByIdCalls, 2, reason: '改好后重新读档');
    expect(find.byKey(_notice), findsNothing);
    expect(find.byKey(_badge), findsNothing);
  });

  testWidgets('没有 pii:edit：照样提醒，但不给修改入口', (tester) async {
    final repository = _DetailRepository()
      ..issue = const EmployeeIdNumberIssue(
        kind: EmployeeIdNumberIssueKind.unchecked,
        reason: '证件号码来自历史资料导入，系统还没有完成校验',
      );
    await _pump(tester, repository, const [Perm.employeeView]);

    final notice = tester.widget<UtenInlineNotice>(
      find.descendant(
        of: find.byKey(_notice),
        matching: find.byType(UtenInlineNotice),
      ),
    );
    expect(notice.level, UtenInlineNoticeLevel.warning);
    expect(
      tester.widget<UtenStatusBadge>(find.byKey(_badge)).type,
      UtenStatusBadgeType.warning,
    );
    expect(find.byKey(_noticeCorrect), findsNothing);
    expect(find.byKey(_rowCorrect), findsNothing);
  });

  testWidgets('证件没问题：不提醒、不显示徽标', (tester) async {
    final repository = _DetailRepository()..issue = null;
    await _pump(tester, repository, const [Perm.employeeView]);

    expect(find.byKey(_notice), findsNothing);
    expect(find.byKey(_badge), findsNothing);
  });
}
