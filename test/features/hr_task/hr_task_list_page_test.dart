// HR 任务中心（2026-09-10 表格化 + 表头筛选 + 批量登记转正/批量送祝福）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
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

  @override
  Future<HrTaskSummary> summary() async => summaryValue;

  @override
  Future<int> count() async => 0;
}

class _FakeEmployeeRepository extends Fake implements EmployeeRepository {
  final List<String> confirmed = [];
  final List<String> updated = [];

  @override
  Future<void> confirm(String id, {String? confirmedDate}) async {
    confirmed.add('$id@$confirmedDate');
  }

  @override
  Future<EmployeeProfile> update(String id, Map<String, dynamic> body) async {
    updated.add(id);
    throw UnimplementedError('本用例不走 409 回退分支');
  }
}

class _FakeNoticeRepository extends Fake implements NoticeRepository {
  final List<List<String>> blessed = [];

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
    expect(table.selectable, isFalse, reason: '无 employee:confirm/edit 不开批量');

    await tester.pumpWidget(const SizedBox());
  });

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

  testWidgets('batch bless only sends today unblessed employees', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final hrTasks = _FakeHrTaskRepository(
      _summary(
        birthdayToday: [
          _item('a', days: 30),
          _item('b', days: 28, blessed: true),
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
}
