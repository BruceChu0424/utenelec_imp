// HR 任务中心（2026-09-10 表格化 + 表头筛选 + 批量登记转正/批量送祝福）。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_card_list.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/hr_task/models/hr_task_summary.dart';
import 'package:uten_imp/features/hr_task/pages/hr_task_list_page.dart';
import 'package:uten_imp/features/hr_task/repositories/hr_task_repository.dart';
import 'package:uten_imp/features/hr_task/widgets/hr_task_widgets.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _FakeHrTaskRepository extends Fake implements HrTaskRepository {
  _FakeHrTaskRepository(this.summaryValue);

  HrTaskSummary summaryValue;
  int summaryCalls = 0;

  @override
  Future<HrTaskSummary> summary() async {
    summaryCalls++;
    return summaryValue;
  }
}

class _FakeEmployeeRepository extends Fake implements EmployeeRepository {
  final List<String> confirmed = [];
  final List<String> updated = [];
  final List<String> identityChanges = [];

  @override
  Future<EmployeeProfile> getById(String id) async =>
      EmployeeProfile(id: id, code: 'UT-$id', fullName: '员工$id');

  @override
  Future<void> changeIdentity(
    String id, {
    required String idType,
    required String idNumber,
  }) async {
    identityChanges.add('$id:$idType');
  }

  @override
  Future<void> confirm(String id, {String? confirmedDate}) async {
    confirmed.add('$id@$confirmedDate');
  }

  @override
  Future<EmployeeProfile> update(String id, Map<String, dynamic> body) async {
    updated.add(id);
    throw UnimplementedError('转正只走 confirm，不回退 PUT 档案');
  }
}

class _FakeNoticeRepository extends Fake implements NoticeRepository {
  final List<List<String>> blessed = [];

  /// 「自动发送祝福」开关状态（V600：默认关，页面开关翻转）。
  bool autoEnabled = false;

  @override
  Future<NoticeCelebrationSettings> getCelebrationSettings() async =>
      NoticeCelebrationSettings(autoEnabled: autoEnabled);

  @override
  Future<NoticeCelebrationSettings> setCelebrationAutoEnabled(
    bool enabled,
  ) async {
    autoEnabled = enabled;
    return NoticeCelebrationSettings(autoEnabled: enabled);
  }

  @override
  Future<CelebrationBatchResult> publishCelebrationBatch({
    required NoticeType type,
    required List<String> employeeIds,
  }) async {
    blessed.add(employeeIds);
    return CelebrationBatchResult(
      published: employeeIds.length,
      skipped: 0,
      notices: 1,
    );
  }
}

HrTaskItem _item(
  String id, {
  String? dept,
  int days = 0,
  String? note,
  String? claimedByName,
  bool claimedByMe = false,
  bool blessed = false,
  String date = '2026-09-11',
}) => HrTaskItem(
  employeeId: id,
  code: 'UT-$id',
  name: '员工$id',
  deptName: dept ?? '研发部',
  positionName: '工程师',
  date: date,
  days: days,
  note: note,
  claimedByName: claimedByName,
  claimedByMe: claimedByMe,
  blessed: blessed,
);

HrTaskSummary _summary({
  List<HrTaskItem> confirmOverdue = const [],
  List<HrTaskItem> confirmToday = const [],
  List<HrTaskItem> confirmUpcoming = const [],
  List<HrTaskItem> birthdayToday = const [],
  List<HrTaskItem> birthdayUpcoming = const [],
  List<HrTaskItem> identityReview = const [],
}) => HrTaskSummary(
  generatedAt: '2026-09-11T08:00:00+08:00',
  probationMonths: 3,
  confirmToday: confirmToday,
  confirmUpcoming: confirmUpcoming,
  confirmOverdue: confirmOverdue,
  unconfirmedLegacyCount: 0,
  birthdayToday: birthdayToday,
  birthdayUpcoming: birthdayUpcoming,
  anniversaryToday: const [],
  newHires: const [],
  identityReview: identityReview,
  badgeCount: 0,
);

Widget _app({
  required HrTaskType type,
  required _FakeHrTaskRepository hrTasks,
  required SharedPreferences preferences,
  _FakeEmployeeRepository? employees,
  _FakeNoticeRepository? notices,
  Set<String> permissions = const {},
}) => ProviderScope(
  overrides: [
    hrTaskRepositoryProvider.overrideWithValue(hrTasks),
    sharedPreferencesProvider.overrideWithValue(preferences),
    currentPermissionsProvider.overrideWithValue(permissions),
    if (employees != null)
      employeeRepositoryProvider.overrideWithValue(employees),
    if (notices != null) noticeRepositoryProvider.overrideWithValue(notices),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: HrTaskListPage(type: type),
  ),
);

MasterDataTableView<HrTaskItem> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<HrTaskItem>>(
      find.byKey(const Key('hr-task-table')),
    );

List<String> _menuLabels(WidgetTester tester, HrTaskItem item) => [
  for (final entry in _table(tester).rowMenuBuilder!(item))
    if (entry is UtenMenuItem) entry.label,
];

UtenMenuItem _menuItem(WidgetTester tester, HrTaskItem item, String label) =>
    _table(tester).rowMenuBuilder!(item).whereType<UtenMenuItem>().firstWhere(
      (entry) => entry.label == label,
    );

void main() {
  testWidgets('confirm queue renders the unified table with client facets', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final hrTasks = _FakeHrTaskRepository(
      _summary(
        confirmOverdue: [_item('a', days: 3)],
        confirmToday: [_item('b', dept: '财务部')],
        confirmUpcoming: [_item('c', days: 7, claimedByName: '李四')],
      ),
    );
    await tester.pumpWidget(
      _app(
        type: HrTaskType.confirm,
        hrTasks: hrTasks,
        preferences: preferences,
        permissions: {Perm.employeeView},
      ),
    );
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(
      table.columns.map((c) => c.key),
      containsAll(<String>[
        'code',
        'name',
        'deptName',
        'positionName',
        'date',
        'days',
        'window',
        'claim',
      ]),
    );
    expect(table.facets['deptName']!.map((b) => b.value), ['研发部', '财务部']);
    expect(
      table.facets['window']!.map((b) => b.value),
      containsAll(<String>['逾期', '今日', '即将']),
    );
    expect(
      table.facets['claim']!.map((b) => b.value),
      containsAll(<String>['未认领', '他人处理中']),
    );
    // 逾期行天数取负值（服务端 days 是逾期天数）
    final daysColumn = table.columns.firstWhere((c) => c.key == 'days');
    expect(daysColumn.value(_table(tester).items.first), '-3');
    expect(table.selectable, isFalse, reason: '无 employee:confirm 不开批量');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('identity review shows the reason column without timeline', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final hrTasks = _FakeHrTaskRepository(
      _summary(
        identityReview: [
          _item('a', days: 120, note: '身份证号应为18位，当前为17位'),
          _item('b', days: 30, note: '档案里没有证件号码'),
        ],
      ),
    );
    await tester.pumpWidget(
      _app(
        type: HrTaskType.identity,
        hrTasks: hrTasks,
        preferences: preferences,
        permissions: {
          Perm.employeeView,
          Perm.employeeConfirm,
          Perm.employeePiiEdit,
        },
      ),
    );
    await tester.pumpAndSettle();

    final table = _table(tester);
    final keys = table.columns.map((c) => c.key).toList();
    expect(keys, containsAll(<String>['code', 'name', 'date', 'note']));
    expect(keys, isNot(contains('days')), reason: '证件核对没有天数');
    expect(keys, isNot(contains('window')), reason: '证件核对没有区间');
    expect(table.columns.firstWhere((c) => c.key == 'note').label, '原因');
    expect(table.columns.firstWhere((c) => c.key == 'date').label, '入职日');
    expect(table.facets.containsKey('window'), isFalse);
    expect(table.selectable, isFalse, reason: '证件核对逐人修改，不开多选');
    expect(table.batchActionsBuilder, isNull);
    final noteColumn = table.columns.firstWhere((c) => c.key == 'note');
    expect(noteColumn.value(table.items.first), '身份证号应为18位，当前为17位');
    expect(find.text('身份证号应为18位，当前为17位'), findsWidgets);
    for (final cell in tester.widgetList<Text>(find.text('身份证号应为18位，当前为17位'))) {
      expect(cell.overflow, isNot(TextOverflow.ellipsis), reason: '表格里原因折行不截断');
      expect(cell.maxLines, isNull);
    }

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('375 宽窄屏卡片：校验码原因红字完整显示，不截断', (tester) async {
    const reason = '身份证号第18位校验码与前17位不符，通常是某一位数字录错或相邻两位颠倒，请对照证件逐位核对';
    const viewSize = Size(375, 1200);
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final hrTasks = _FakeHrTaskRepository(
      _summary(identityReview: [_item('a', days: 120, note: reason)]),
    );
    await tester.pumpWidget(
      _app(
        type: HrTaskType.identity,
        hrTasks: hrTasks,
        preferences: preferences,
        permissions: {Perm.employeeView, Perm.employeePiiEdit},
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '375 宽不溢出');
    expect(
      find.byType(MasterDataCardList<HrTaskItem>),
      findsOneWidget,
      reason: '窄屏走卡片形态',
    );

    final reasonFinder = find.text(reason);
    expect(reasonFinder, findsOneWidget, reason: '原因原样完整，不拼「原因」前缀');
    final text = tester.widget<Text>(reasonFinder);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(
      text.style?.color,
      Theme.of(tester.element(reasonFinder)).colorScheme.error,
      reason: '卡片里也是红字',
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: reasonFinder, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    final rect = tester.getRect(reasonFinder);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(viewSize.width));
    expect(rect.bottom, lessThanOrEqualTo(viewSize.height));

    await tester.pumpWidget(const SizedBox());
  });

  // 能不能修由服务端判定：证件核对条目只下发给能修改证件的人(超管或 employee:pii:edit)，
  // 本页路由守卫也要求 employee:pii:edit(见 page_route_permission_dependency_test)；
  // 页面只再挡「他人处理中」。
  testWidgets(
    'identity correction menu is offered unless someone else handles it',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final free = _item('a', note: '身份证号第18位只能是数字或X');
      final mine = _item('b', note: '档案里没有证件号码', claimedByMe: true);
      final others = _item(
        'c',
        note: '证件号码来自历史资料导入，系统还没有完成校验',
        claimedByName: '李四',
      );
      final hrTasks = _FakeHrTaskRepository(
        _summary(identityReview: [free, mine, others]),
      );

      final employees = _FakeEmployeeRepository();
      await tester.pumpWidget(
        _app(
          type: HrTaskType.identity,
          hrTasks: hrTasks,
          preferences: preferences,
          employees: employees,
          permissions: {Perm.employeeView, Perm.employeePiiEdit},
        ),
      );
      await tester.pumpAndSettle();
      expect(_menuLabels(tester, free), contains('修改证件信息'));
      expect(_menuLabels(tester, mine), contains('修改证件信息'));
      expect(
        _menuLabels(tester, others),
        isNot(contains('修改证件信息')),
        reason: '他人处理中不显示，防重复修改',
      );

      final callsBefore = hrTasks.summaryCalls;
      _menuItem(tester, free, '修改证件信息').onTap();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('employee-identity-correction-dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('employee-identity-correction-number')),
        '11010519491231002X',
      );
      await tester.tap(
        find.byKey(const ValueKey('employee-identity-correction-save')),
      );
      await tester.pumpAndSettle();

      expect(employees.identityChanges, ['a:身份证']);
      expect(
        find.byKey(const ValueKey('employee-identity-correction-dialog')),
        findsNothing,
      );
      expect(
        hrTasks.summaryCalls,
        greaterThan(callsBefore),
        reason: '改完静默重取，任务随之消失',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('batch confirm skips rows claimed by others', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final hrTasks = _FakeHrTaskRepository(
      _summary(
        confirmToday: [_item('a'), _item('b')],
        confirmUpcoming: [_item('c', days: 5, claimedByName: '李四')],
      ),
    );
    final employees = _FakeEmployeeRepository();
    await tester.pumpWidget(
      _app(
        type: HrTaskType.confirm,
        hrTasks: hrTasks,
        preferences: preferences,
        employees: employees,
        permissions: {
          Perm.employeeView,
          Perm.employeeConfirm,
          Perm.employeeEdit,
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(_table(tester).selectable, isTrue);
    _table(tester).onSelectedIdsChanged!({'a', 'b', 'c'});
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('hr-task-batch-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('所选 2 人将使用同一个实际转正日期'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(employees.confirmed.length, 2);
    expect(
      employees.confirmed.map((c) => c.split('@').first).toSet(),
      {'a', 'b'},
      reason: '被他人认领的 c 不发请求',
    );
    expect(employees.updated, isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('batch confirm needs only employee:confirm (no PUT fallback)', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final hrTasks = _FakeHrTaskRepository(_summary(confirmToday: [_item('a')]));
    final employees = _FakeEmployeeRepository();
    await tester.pumpWidget(
      _app(
        type: HrTaskType.confirm,
        hrTasks: hrTasks,
        preferences: preferences,
        employees: employees,
        permissions: {Perm.employeeView, Perm.employeeConfirm},
      ),
    );
    await tester.pumpAndSettle();

    expect(_table(tester).selectable, isTrue, reason: '批量转正不再要求 employee:edit');
    _table(tester).onSelectedIdsChanged!({'a'});
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('hr-task-batch-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(employees.confirmed, hasLength(1));
    expect(employees.updated, isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('batch bless only sends today unblessed employees', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final hrTasks = _FakeHrTaskRepository(
      _summary(
        birthdayToday: [
          _item('a'),
          _item('b', blessed: true),
        ],
        birthdayUpcoming: [_item('c', days: 5)],
      ),
    );
    final notices = _FakeNoticeRepository();
    await tester.pumpWidget(
      _app(
        type: HrTaskType.birthday,
        hrTasks: hrTasks,
        preferences: preferences,
        notices: notices,
        permissions: {Perm.employeeView, Perm.noticePublish},
      ),
    );
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(table.columns.map((c) => c.key), contains('blessed'));
    expect(table.selectable, isTrue);
    table.onSelectedIdsChanged!({'a', 'b', 'c'});
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('hr-task-batch-bless')));
    await tester.pumpAndSettle();

    expect(notices.blessed.single, ['a'], reason: '已祝福的 b 与未到日的 c 都不发');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('celebration auto-send toggle defaults off and flips via api', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final hrTasks = _FakeHrTaskRepository(
      _summary(birthdayToday: [_item('a')]),
    );
    final notices = _FakeNoticeRepository();
    await tester.pumpWidget(
      _app(
        type: HrTaskType.birthday,
        hrTasks: hrTasks,
        preferences: preferences,
        notices: notices,
        permissions: {Perm.employeeView, Perm.noticePublish},
      ),
    );
    await tester.pumpAndSettle();

    // V600：默认关；开关存在于页面并显示当前值。
    final toggle = tester.widget<Switch>(
      find.byKey(const Key('hr-task-celebration-auto-switch')),
    );
    expect(toggle.value, isFalse);

    await tester.tap(find.byKey(const Key('hr-task-celebration-auto-switch')));
    await tester.pumpAndSettle();

    expect(notices.autoEnabled, isTrue, reason: '点击开关应调用翻转端点');
    final updated = tester.widget<Switch>(
      find.byKey(const Key('hr-task-celebration-auto-switch')),
    );
    expect(updated.value, isTrue, reason: '翻转成功后开关回显新状态');

    await tester.pumpWidget(const SizedBox());
  });
}
