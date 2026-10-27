// 入职 5 步向导的页面级契约：
// 1) 分步校验：第 1 步必填未填/身份证号非法不能进入第 2 步，且错误原因走通知复述；
// 2) 默认值：入职日期=今天、员工状态=试用(不出现转正日期)、证件类型=身份证；
//    切到「在职」时转正日期自动带入入职日期；
// 3) 完整走完 5 步提交：payload 携带按证件号派生的性别/出生日期、教育经历、
//    紧急联系人与银行资料；一次性凭据弹窗必须点「我已妥善保存」后才能返回。
// 注意：Material Stepper 垂直模式会同时构建全部步骤内容(AnimatedCrossFade 收起但
// 仍在树里)，所有 finder 必须按 label/key 限定作用域，不能用全局顺序下标。
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../helpers/badge_summary_fixture.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/core/utils/id_card_utils.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/pages/employee_onboarding_page.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';

/// 固定 standard 性能档：UtenCard 依赖 performanceProvider，其默认链路会读
/// SharedPreferences；mock prefs 会让草稿原生存储走真实磁盘 IO，在 fake 时钟里
/// 永远挂起。直接固定档位即可绕开整条链(见 uten_skeleton_motion_test 同款做法)。
class _FixedPerformanceNotifier extends PerformanceNotifier {
  @override
  PerformanceTier build() => PerformanceTier.standard;
}

class _Api extends Fake implements ApiClient {}

class _IdleSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}

class _OnboardingActor extends SessionNotifier {
  _OnboardingActor(this.permissions);
  final Set<String> permissions;
  @override
  SessionState build() => identity('hr-user');
  SessionState identity(String id) => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: id,
      code: 'HR1',
      name: '人事',
      businessDatasetId: 'onboarding-dataset',
      permissions: permissions.toList(),
    ),
  );
  void change() => state = identity('other-hr');
}

/// 校验码合法的示例身份证(1949-12-31 出生，第 17 位偶数=女)。
const _validIdNumber = '11010519491231002X';

/// 按浮动标签定位文本字段(TextFormField 内部的 TextField 暴露 decoration)：
/// 可选字段是 labelText，必填字段的 label 是 requiredLabel 生成的 Text.rich('label *')。
bool _labelMatches(InputDecoration? decoration, String label) {
  if (decoration?.labelText == label) return true;
  final l = decoration?.label;
  if (l is Text) {
    final plain = l.data ?? l.textSpan?.toPlainText() ?? '';
    return plain.startsWith(label);
  }
  return false;
}

Finder _inputByLabel(String label) => find.byWidgetPredicate(
  (w) => w is TextField && _labelMatches(w.decoration, label),
);

Finder _contactInput(int index, String label) => find.descendant(
  of: find.byKey(ValueKey('onboarding-contact-entry-$index')),
  matching: _inputByLabel(label),
);

Future<void> _tapNext(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('employee-onboarding-next')));
  await tester.pumpAndSettle();
}

/// 卸载页面并推进假时钟：冲掉草稿自动保存防抖与通知停留的挂起计时器，
/// 否则 binding 在用例末尾断言「无未完成 Timer」失败。
Future<void> _disposePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

int _currentStep(WidgetTester tester) =>
    tester.widget<Stepper>(find.byType(Stepper)).currentStep;

/// 通知宿主在应用壳里，测试树不渲染它；用显式容器直接读通知队列断言。
/// 交互用例统一 800×1600 画布：下拉浮层可向上/向下完整展开，不被 600px 顶边裁掉。
Future<ProviderContainer> _pump(
  WidgetTester tester,
  _OnboardingRepository repo, {
  bool accountSupport = false,
  bool authenticated = false,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/employee-list',
    routes: [
      GoRoute(
        path: '/employee-list',
        builder: (_, _) => Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => context.push('/employee/onboarding'),
                child: const Text('员工列表'),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/employee/onboarding',
        builder: (_, _) =>
            const EmployeeOnboardingPage(initialDepartmentId: 'dept-1'),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      if (!authenticated)
        currentPermissionsProvider.overrideWithValue({
          Perm.employeeCreate,
          Perm.departmentView,
          Perm.employeePiiEdit,
          Perm.employeeCompensationEdit,
          if (accountSupport) Perm.accountSupport,
        }),
      if (authenticated) ...[
        sessionProvider.overrideWith(
          () => _OnboardingActor({
            Perm.employeeCreate,
            Perm.departmentView,
            Perm.employeePiiEdit,
            Perm.employeeCompensationEdit,
            if (accountSupport) Perm.accountSupport,
          }),
        ),
        apiClientProvider.overrideWithValue(_Api()),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        sessionSnapshotProvider.overrideWith(_IdleSnapshot.new),
        fixedBadgeSummaryOverride(),
      ],
      employeeRepositoryProvider.overrideWithValue(repo),
      performanceProvider.overrideWith(_FixedPerformanceNotifier.new),
      // 草稿自动保存 → formDraftsProvider → apiBaseUrl → localServerReachable，
      // Riverpod 3 同步挂链会在测试容器里拉起 60s 周期可达性探针定时器，
      // 假时钟下永远到不了销毁点，收尾「无 pending timer」断言必炸。
      // 按仓库既有口径用 web: true（Web 不跑探针、不起定时器）关掉。
      localServerReachableProvider.overrideWith(
        (ref) => LocalServerReachabilityNotifier(null, web: true),
      ),
      departmentPickerTreeProvider.overrideWith(
        (ref) async => [
          DepartmentNode(
            id: 'dept-1',
            code: 'F1',
            name: '生产部',
            level: 'department',
            children: const [],
          ),
        ],
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('员工列表'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('没有账号支持权限也可明确只建员工档案，不造登录账号', (tester) async {
    final repo = _OnboardingRepository();
    await _pump(tester, repo, authenticated: true);
    await _fillRequiredAndGoLast(tester);
    await _tapNext(tester);
    expect(repo.created!.account.openAccount, isFalse);
    expect(find.text('Temp@2468'), findsNothing);
    expect(find.text('员工列表'), findsOneWidget);
    await _disposePage(tester);
  });

  testWidgets('入职旧创建成功迟到时不能向另一个操作者展示账号凭据', (tester) async {
    final pending = Completer<EmployeeOnboardingResult>();
    final repo = _OnboardingRepository()..pending = pending;
    final container = await _pump(
      tester,
      repo,
      accountSupport: true,
      authenticated: true,
    );
    await _fillRequiredAndGoLast(tester);
    final option = find.byKey(
      const ValueKey('employee-onboarding-open-account'),
    );
    expect(option, findsOneWidget);
    await tester.ensureVisible(option);
    await tester.tap(option);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('employee-onboarding-next')));
    for (var frame = 0; frame < 5 && repo.created == null; frame++) {
      await tester.pump();
    }
    expect(repo.created, isNotNull);
    (container.read(sessionProvider.notifier) as _OnboardingActor).change();
    pending.complete(_issuedResult);
    await tester.pumpAndSettle();
    expect(find.text('Temp@2468'), findsNothing);
    expect(find.text('账号已创建'), findsNothing);
    await _disposePage(tester);
  });
  testWidgets('入职只授查看部门仍可打开并确认部门，不需要部门编辑权限', (tester) async {
    final container = await _pump(tester, _OnboardingRepository());
    final permissions = container.read(currentPermissionsProvider);
    expect(permissions, contains(Perm.departmentView));
    expect(permissions, isNot(contains(Perm.departmentEdit)));
    await tester.enterText(_inputByLabel('姓名'), '李慕白');
    await tester.enterText(_inputByLabel('证件号码'), _validIdNumber);
    await tester.enterText(_inputByLabel('手机号'), '13800138000');
    await _tapNext(tester);
    expect(_currentStep(tester), 1);
    final field = find
        .descendant(
          of: find.byType(UtenDepartmentPicker),
          matching: find.byType(InputDecorator),
        )
        .first;
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    expect(find.text('选择部门'), findsWidgets);
    await tester.tap(find.text('确定').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenDepartmentPicker>(find.byType(UtenDepartmentPicker))
          .initialSelection
          .single
          .id,
      'dept-1',
    );
    expect(tester.takeException(), isNull);
    await _disposePage(tester);
  });
  testWidgets('第 1 步必填未填或身份证非法时不能进入第 2 步', (tester) async {
    final repo = _OnboardingRepository();
    final container = await _pump(tester, repo);

    expect(find.text('1. 基本信息'), findsOneWidget);
    await _tapNext(tester);
    expect(_currentStep(tester), 0, reason: '姓名/证件/手机为空，不能前进');
    expect(repo.created, isNull);

    await tester.enterText(_inputByLabel('姓名'), '李慕白');
    await tester.enterText(_inputByLabel('证件号码'), '110105194912310021');
    await tester.enterText(_inputByLabel('手机号'), '13800138000');
    await _tapNext(tester);
    expect(_currentStep(tester), 0, reason: '身份证号校验码不合法，不能前进');
    expect(
      container
          .read(appNotificationProvider)
          .any((n) => n.message.contains('身份证号第18位校验码')),
      isTrue,
      reason: '被拦时用通知把具体原因再复述一遍',
    );
    await _disposePage(tester);
  });

  testWidgets('默认值正确；切到在职时转正日期自动带入入职日期', (tester) async {
    final repo = _OnboardingRepository();
    await _pump(tester, repo);

    await tester.enterText(_inputByLabel('姓名'), '李慕白');
    await tester.enterText(_inputByLabel('证件号码'), _validIdNumber);
    await tester.enterText(_inputByLabel('手机号'), '13800138000');
    expect(IdCardUtils.problemOf(_validIdNumber), isNull, reason: '样例证件号必须合法');
    await _tapNext(tester);
    expect(_currentStep(tester), 1);

    // 默认：入职日期=今天(选择器以今天封顶)、状态=试用 → 不出现转正日期字段。
    // 按真正的日期控件定位，避免把浮动标签和框内字段名算成两个字段。
    final confirmedDateField = find.byWidgetPredicate(
      (widget) => widget is UtenDateField && widget.label == '转正日期',
    );
    expect(confirmedDateField, findsNothing);
    final today = ChinaDateTime.formatDate(ChinaDateTime.today());
    expect(find.text(today), findsWidgets, reason: '入职日期默认今天并已展示');

    // 切到「在职」：转正日期出现且默认=入职日期，直接可前进。
    await tester.ensureVisible(find.byKey(const ValueKey('onboarding-status')));
    await tester.tap(find.byKey(const ValueKey('onboarding-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在职').last);
    await tester.pumpAndSettle();
    expect(confirmedDateField, findsOneWidget);
    expect(
      ChinaDateTime.formatDate(
        tester.widget<UtenDateField>(confirmedDateField).value!,
      ),
      today,
      reason: '切到在职后转正日期的真实值必须等于默认入职日期',
    );
    await _tapNext(tester);
    expect(_currentStep(tester), 2, reason: '转正日期已自动带入，不被必填拦下');
    expect(repo.created, isNull);
    await _disposePage(tester);
  });

  testWidgets('完整 5 步提交：派生档案/教育/紧急联系人/银行资料与凭据弹窗', (tester) async {
    final repo = _OnboardingRepository();
    await _pump(tester, repo, accountSupport: true, authenticated: true);

    // 第 1 步：基本信息(性别/出生日期由身份证号自动带出)。
    await tester.enterText(_inputByLabel('姓名'), '李慕白');
    await tester.enterText(_inputByLabel('证件号码'), _validIdNumber);
    await tester.enterText(_inputByLabel('手机号'), '13800138000');
    await _tapNext(tester);
    expect(_currentStep(tester), 1);

    // 第 2 步：部门已由入口预填、日期与下拉均有默认值，直接前进。
    await _tapNext(tester);
    expect(_currentStep(tester), 2);

    // 第 3 步：添加一条教育经历(学校 + 学历必填)。
    await tester.ensureVisible(find.text('添加教育经历'));
    await tester.tap(find.text('添加教育经历'));
    await tester.pumpAndSettle();
    await tester.enterText(_inputByLabel('学校'), '华中科技大学');
    await tester.ensureVisible(
      find.byKey(const ValueKey('onboarding-degree-0')),
    );
    await tester.tap(find.byKey(const ValueKey('onboarding-degree-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本科').last);
    await tester.pumpAndSettle();
    await _tapNext(tester);
    expect(_currentStep(tester), 3);

    // 第 4 步：添加一位紧急联系人(姓名 + 手机号必填)。
    await tester.ensureVisible(find.text('添加紧急联系人'));
    await tester.tap(find.text('添加紧急联系人'));
    await tester.pumpAndSettle();
    await tester.enterText(_contactInput(0, '姓名'), '王紧急');
    await tester.enterText(_contactInput(0, '手机号'), '13900139000');
    await _tapNext(tester);
    expect(_currentStep(tester), 4);

    // 第 5 步：选填现居住地与银行资料后提交。
    await tester.enterText(_inputByLabel('现居住地'), '北京市朝阳区望京街道');
    await tester.enterText(_inputByLabel('开户银行'), '工商银行北京分行');
    await tester.enterText(_inputByLabel('银行卡号'), '6222020000123456789');
    final openAccount = find.byKey(
      const ValueKey('employee-onboarding-open-account'),
    );
    expect(openAccount, findsOneWidget);
    await tester.ensureVisible(openAccount);
    await tester.tap(openAccount);
    await tester.pump();
    await _tapNext(tester); // 末步=提交入职
    await tester.pumpAndSettle();

    // 一次性凭据弹窗：不点「我已妥善保存」不会离开本页。
    expect(find.text('账号已创建'), findsOneWidget);
    expect(find.text('Temp@2468'), findsOneWidget);
    await tester.tap(find.text('我已妥善保存'));
    await tester.pumpAndSettle();
    expect(find.text('员工列表'), findsOneWidget);

    final input = repo.created!;
    expect(input.profile['fullName'], '李慕白');
    expect(input.profile['idType'], '身份证');
    expect(input.profile['idNumber'], _validIdNumber);
    expect(input.profile['phone'], '13800138000');
    expect(input.profile['gender'], 'female', reason: '身份证第17位偶数=女');
    expect(input.profile['birthDate'], '1949-12-31');
    expect(input.profile['residenceAddress'], '北京市朝阳区望京街道');
    expect(input.profile, isNot(contains('email')));
    expect(input.employment['departmentId'], 'dept-1');
    expect(input.employment['employmentType'], 'regular');
    expect(input.employment['status'], 'probation', reason: '默认试用，不带转正日期');
    expect(
      input.employment['hireDate'],
      ChinaDateTime.formatDate(ChinaDateTime.today()),
    );
    expect(input.employment, isNot(contains('confirmedAt')));
    expect(input.compensation!['bankBranch'], '工商银行北京分行');
    expect(input.compensation!['bankAccount'], '6222020000123456789');
    expect(input.educations, hasLength(1));
    expect(input.educations.first['school'], '华中科技大学');
    expect(input.educations.first['degree'], '本科');
    expect(input.emergencyContacts, hasLength(1));
    expect(input.emergencyContacts.first['name'], '王紧急');
    expect(input.emergencyContacts.first['phone'], '13900139000');
    await _disposePage(tester);
  });

  testWidgets('375px 暗色大字号下第 1 步仍可渲染无溢出', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: '/employee/onboarding',
      routes: [
        GoRoute(
          path: '/employee/onboarding',
          builder: (_, _) => const EmployeeOnboardingPage(),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue({
            Perm.employeeCreate,
            Perm.employeePiiEdit,
          }),
          employeeRepositoryProvider.overrideWithValue(_OnboardingRepository()),
          performanceProvider.overrideWith(_FixedPerformanceNotifier.new),
          departmentPickerTreeProvider.overrideWith((ref) async => []),
        ],
        child: MaterialApp.router(
          locale: const Locale('zh'),
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1. 基本信息'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('employee-onboarding-next')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _disposePage(tester);
  });
}

class _OnboardingRepository extends Fake implements EmployeeRepository {
  EmployeeOnboardingInput? created;
  Completer<EmployeeOnboardingResult>? pending;

  @override
  Future<EmployeeOnboardingResult> create(EmployeeOnboardingInput input) async {
    created = input;
    if (pending != null) return pending!.future;
    return input.account.openAccount == false
        ? const EmployeeOnboardingResult(
            employee: EmployeeProfile(
              id: 'e-1',
              code: 'UT0001',
              fullName: '李慕白',
            ),
            temporaryPassword: null,
            loginAccount: null,
          )
        : _issuedResult;
  }

  @override
  Future<PagedResult<EmployeeSummary>> list({
    int page = 1,
    int size = 20,
    String? search,
    Set<String>? statuses,
    String? departmentId,
    bool includeSubtree = false,
    String? sort,
    String? order,
  }) async => PagedResult(
    items: const [],
    page: page,
    size: size,
    total: 0,
    totalPages: 0,
  );
}

const _issuedResult = EmployeeOnboardingResult(
  employee: EmployeeProfile(
    id: 'e-1',
    code: 'UT0001',
    fullName: '李慕白',
    accountStatus: 'active',
  ),
  temporaryPassword: 'Temp@2468',
  loginAccount: '13800138000',
);

Future<void> _fillRequiredAndGoLast(WidgetTester tester) async {
  await tester.enterText(_inputByLabel('姓名'), '李慕白');
  await tester.enterText(_inputByLabel('证件号码'), _validIdNumber);
  await tester.enterText(_inputByLabel('手机号'), '13800138000');
  for (var step = 0; step < 4; step++) {
    await _tapNext(tester);
  }
}
