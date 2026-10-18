import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/employee/models/employee_api_models.dart';
import 'package:uten_imp/features/employee/repositories/employee_repository.dart';
import 'package:uten_imp/features/employee/widgets/department_employee_picker.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'account-a', epoch: 1),
);
final _server = StateProvider<String>((_) => 'https://server-a.test');
final _permissions = StateProvider<Set<String>>((_) => {'employee:view'});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final boundary in ['identity', 'server', 'permissions']) {
    testWidgets('$boundary ABA后迟到部门树不得打开旧身份滑窗', (tester) async {
      final pending = Completer<List<DepartmentNode>>();
      final results = <UtenEmployeePickerItem?>[];
      final repository = _FakeEmployeeRepository();
      final container = await _pumpWithAccess(
        tester,
        repository,
        treeLoader: () => pending.future,
        onPicked: results.add,
      );
      await tester.tap(find.text('打开选择器'));
      await tester.pump();
      expect(find.byType(UtenSplitView), findsNothing);
      await _changeBoundaryABA(tester, container, boundary);
      pending.complete(_tree);
      await tester.pumpAndSettle();
      expect(find.byType(UtenSplitView), findsNothing);
      expect(repository.searches, isEmpty);
      expect(results, [null]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$boundary ABA后迟到员工结果不得回填或确认', (tester) async {
      final repository = _DeferredEmployeeRepository();
      final results = <UtenEmployeePickerItem?>[];
      final container = await _pumpWithAccess(
        tester,
        repository,
        onPicked: results.add,
      );
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();
      await tester.enterText(_pickerSearch(tester), 'OLD');
      await tester.pump(const Duration(milliseconds: 301));
      expect(repository.oldRequested, isTrue);
      await _changeBoundaryABA(tester, container, boundary);
      repository.completeOld();
      await tester.pumpAndSettle();
      expect(find.byType(UtenSplitView), findsNothing);
      expect(find.text('旧员工'), findsNothing);
      expect(results, [null]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('权限变化只关闭自己的选人滑窗，不关闭后来打开的对话框', (tester) async {
    final results = <UtenEmployeePickerItem?>[];
    final container = await _pumpWithAccess(
      tester,
      _FakeEmployeeRepository(),
      onPicked: results.add,
    );
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(UtenDepartmentTreeView),
        matching: find.text('销售部'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('张三'));
    await tester.pumpAndSettle();
    expect(find.text('已选择：张三(E-100)'), findsOneWidget);
    final context = tester.element(find.byType(UtenSplitView));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('保留后打开的对话框')),
      ),
    );
    await tester.pumpAndSettle();
    container.read(_permissions.notifier).state = {};
    await tester.pumpAndSettle();
    expect(find.text('保留后打开的对话框'), findsOneWidget);
    expect(find.byType(UtenSplitView, skipOffstage: false), findsNothing);
    expect(results, [null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('弹窗已pop但返回尚未恢复时身份变化，丢弃已选员工返回值', (tester) async {
    final results = <UtenEmployeePickerItem?>[];
    final container = await _pumpWithAccess(
      tester,
      _FakeEmployeeRepository(),
      onPicked: results.add,
    );
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(UtenSplitView));
    Navigator.of(context).pop(
      const UtenEmployeePickerItem(
        id: 'employee-uuid',
        name: '已选员工',
        employeeCode: 'E-100',
      ),
    );
    container.read(_identity.notifier).state = const AuthenticatedScope(
      userId: 'account-b',
      epoch: 2,
    );
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('树加载后弹窗构建前切换身份，不显示旧组织树', (tester) async {
    final results = <UtenEmployeePickerItem?>[];
    final repository = _FakeEmployeeRepository();
    late ProviderContainer container;
    final observer = _PopupPushObserver(() {
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'account-b',
        epoch: 2,
      );
    });
    container = await _pumpWithAccess(
      tester,
      repository,
      onPicked: results.add,
      observer: observer,
    );
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    expect(observer.popupPushes, 1);
    expect(find.byType(UtenSplitView), findsNothing);
    expect(repository.searches, isEmpty);
    expect(results, [null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('部门人员字段打开后外部切换草稿，不接受旧滑窗的选择', (tester) async {
    final initialId = ValueNotifier('before');
    addTearDown(initialId.dispose);
    final picked = Completer<UtenEmployeePickerItem?>();
    String? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: initialId,
            builder: (_, id, _) => DepartmentEmployeePickerField(
              label: '保管人',
              hint: '选择保管人',
              initialId: id,
              initialName: '人员$id',
              onChanged: (id) => changed = id as String?,
              onPick: () => picked.future,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    initialId.value = 'after';
    await tester.pump();
    picked.complete(const UtenEmployeePickerItem(id: 'old', name: '旧选择'));
    await tester.pump();

    expect(changed, isNull);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '人员after',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('部门人员字段关闭后旧滑窗返回不会写已销毁状态', (tester) async {
    final picked = Completer<UtenEmployeePickerItem?>();
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DepartmentEmployeePickerField(
            label: '保管人',
            hint: '选择保管人',
            initialId: null,
            initialName: null,
            onChanged: (_) => changes++,
            onPick: () => picked.future,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpWidget(const SizedBox.shrink());
    picked.complete(const UtenEmployeePickerItem(id: 'old', name: '旧选择'));
    await tester.pump();

    expect(changes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('部门人员滑窗与客户选择器使用相同宽度、分栏与层级色', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpPicker(tester, _FakeEmployeeRepository());

    expect(find.byType(UtenSplitView), findsOneWidget);
    // 2026-10-17 滑窗口径：1920 屏 browse 档 = max(720, 1920 × 75%) = 1440。
    expect(tester.getSize(find.byType(UtenSplitView)).width, 1440);
    final tree = tester.widget<UtenDepartmentTreeView>(
      find.byType(UtenDepartmentTreeView),
    );
    expect(tree.flatLevelColors, isTrue);
    expect(tree.expandOnRowTap, isTrue);
    expect(tree.mode, UtenDepartmentTreeMode.single);
  });

  testWidgets('专用员工表独立展示账号及在职状态，缺失字段不猜作未开通', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const rows = [
      EmployeeSummary(
        id: 'locked-leave',
        code: 'S001',
        fullName: '锁定休假员工',
        departmentId: 'sales',
        departmentName: '销售部',
        accountStatus: 'locked',
        status: 'onLeave',
      ),
      EmployeeSummary(
        id: 'new-probation',
        code: 'S002',
        fullName: '待开通试用员工',
        departmentId: 'sales',
        departmentName: '销售部',
        accountStatus: 'notProvisioned',
        status: 'probation',
      ),
      EmployeeSummary(
        id: 'active-resigned',
        code: 'S003',
        fullName: '已开通离职员工',
        departmentId: 'sales',
        departmentName: '销售部',
        accountStatus: 'active',
        status: 'resigned',
      ),
      EmployeeSummary(
        id: 'unknown',
        code: 'S004',
        fullName: '状态未提供员工',
        departmentId: 'sales',
        departmentName: '销售部',
      ),
    ];
    UtenEmployeePickerItem? result;
    await _pumpPicker(
      tester,
      _FakeEmployeeRepository(suppliedRows: rows),
      statuses: const {'active', 'probation', 'onLeave', 'resigned'},
      onPicked: (item) => result = item,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(UtenDepartmentTreeView),
        matching: find.text('销售部'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('锁定'), findsOneWidget);
    expect(find.text('休假'), findsOneWidget);
    expect(find.text('未开通'), findsOneWidget);
    expect(find.text('试用'), findsOneWidget);
    expect(find.text('已开通'), findsOneWidget);
    expect(find.text('离职'), findsOneWidget);
    expect(find.text('未提供'), findsNWidgets(2));
    await tester.tap(find.text('锁定休假员工'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result?.id, 'locked-leave');
    expect(result?.accountStatus, 'locked');
    expect(result?.employmentStatus, 'onLeave');
    expect(result?.subtitle, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('统一左侧搜索员工后展开所属部门并在右侧显示结果', (tester) async {
    final repository = _FakeEmployeeRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _tree,
          ),
          employeeRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: _Harness()),
      ),
    );

    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();

    final searchFields = find.descendant(
      of: find.byType(UtenDepartmentTreeView),
      matching: find.byType(TextField),
    );
    expect(searchFields, findsOneWidget);
    expect(
      tester.widget<TextField>(searchFields).decoration?.hintText,
      '搜索部门/员工姓名或工号',
    );

    await tester.enterText(searchFields, 'E-100');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    final tree = tester.widget<UtenDepartmentTreeView>(
      find.byType(UtenDepartmentTreeView),
    );
    expect(tree.visibleFilterIds, {'root', 'sales'});
    expect(tree.selectedIds, {'sales'});
    expect(find.text('张三'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('department-employee-table')),
        matching: find.text('E-100'),
      ),
      findsOneWidget,
    );
    final table = tester.widget<MasterDataTableView<UtenEmployeePickerItem>>(
      find.byKey(const ValueKey('department-employee-table')),
    );
    expect(table.columns.map((column) => column.label), [
      '姓名',
      '工号',
      '部门',
      '账号状态',
      '在职状态',
    ]);
    expect(repository.searches, contains('E-100'));
  });

  testWidgets('分页结果可继续加载并选择首屏之外的授权员工', (tester) async {
    final repository = _PagedEmployeeRepository();
    await _pumpPicker(tester, repository);

    final search = _pickerSearch(tester);
    await tester.enterText(search, 'E-');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(find.text('第一页员工'), findsOneWidget);
    expect(find.text('E-001'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('department-employee-load-more')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('department-employee-load-more')),
    );
    await tester.pumpAndSettle();

    expect(find.text('第二页员工'), findsOneWidget);
    expect(find.text('E-101'), findsOneWidget);
    await tester.tap(find.text('第二页员工'));
    await tester.pumpAndSettle();
    expect(find.text('已选择：第二页员工(E-101)'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('department-employee-table')),
      findsOneWidget,
    );
    expect(repository.requestedPages, containsAll(<int>[1, 2]));
  });

  testWidgets('纯部门命中点击仍保留左查询并浏览该部门全部员工', (tester) async {
    final repository = _FakeEmployeeRepository();
    await _pumpPicker(tester, repository);

    final search = _pickerSearch(tester);
    await tester.enterText(search, 'SALES');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    final tree = find.byType(UtenDepartmentTreeView);
    await tester.tap(
      find.descendant(of: tree, matching: find.text('销售部')).first,
    );
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(search).controller?.text, 'SALES');
    expect(find.text('张三'), findsOneWidget);
    expect(repository.departmentIds.last, 'sales');
    expect(repository.searches.last, isNull);
  });

  testWidgets('继续输入会在防抖窗口内立即阻止旧员工结果回写', (tester) async {
    final repository = _DeferredEmployeeRepository();
    await _pumpPicker(tester, repository);

    final search = _pickerSearch(tester);
    await tester.enterText(search, 'OLD');
    await tester.pump(const Duration(milliseconds: 301));
    expect(repository.oldRequested, isTrue);

    await tester.enterText(search, 'NEW');
    repository.completeOld();
    await tester.pump();
    expect(find.text('旧员工'), findsNothing);

    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(find.text('新员工'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('department-employee-table')),
        matching: find.text('NEW'),
      ),
      findsOneWidget,
    );
    expect(find.text('旧员工'), findsNothing);
  });

  testWidgets('部门窄栏保留搜索清除和子部门，选员工后仍需确认', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _FakeEmployeeRepository();
    UtenEmployeePickerItem? result;
    await _pumpPicker(tester, repository, onPicked: (item) => result = item);
    await tester.drag(find.byTooltip('拖动调整宽度 · 双击复位'), const Offset(-1400, 0));
    await tester.pumpAndSettle();
    final treeFinder = find.byType(UtenDepartmentTreeView);
    expect(tester.getSize(treeFinder).width, 160);
    expect(tester.getSize(_pickerSearch(tester)).width, 144);

    await tester.tap(find.byTooltip('展开销售部'));
    await tester.pumpAndSettle();
    expect(find.text('海外销售组').hitTestable(), findsOneWidget);
    await tester.tap(
      find.descendant(of: treeFinder, matching: find.text('销售部')),
    );
    await tester.pumpAndSettle();
    expect(repository.departmentIds.last, 'sales');
    expect(repository.includeSubtrees.last, isTrue);

    await tester.enterText(_pickerSearch(tester), 'E-100');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(find.text('张三'), findsOneWidget);
    final clear = find.byTooltip('清除搜索');
    expect(
      tester.getRect(treeFinder).contains(tester.getRect(clear).center),
      isTrue,
    );
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_pickerSearch(tester)).controller!.text,
      '',
    );
    expect(tester.getSize(treeFinder).width, 160);
    await tester.tap(find.text('张三'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('已选择：张三(E-100)'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result?.id, 'employee');
    expect(tester.takeException(), isNull);
  });
}

Future<ProviderContainer> _pumpWithAccess(
  WidgetTester tester,
  EmployeeRepository repository, {
  Future<List<DepartmentNode>> Function()? treeLoader,
  required ValueChanged<UtenEmployeePickerItem?> onPicked,
  NavigatorObserver? observer,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      employeePickerDepartmentTreeProvider.overrideWith(
        (_) => treeLoader == null ? Future.value(_tree) : treeLoader(),
      ),
      employeeRepositoryProvider.overrideWithValue(repository),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      isSuperAdminProvider.overrideWithValue(false),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorObservers: [?observer],
        home: _Harness(onPicked: onPicked),
      ),
    ),
  );
  await tester.pump();
  return container;
}

class _PopupPushObserver extends NavigatorObserver {
  _PopupPushObserver(this.onPopup);
  final VoidCallback onPopup;
  int popupPushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      popupPushes++;
      onPopup();
    }
  }
}

Future<void> _changeBoundaryABA(
  WidgetTester tester,
  ProviderContainer container,
  String boundary,
) async {
  switch (boundary) {
    case 'identity':
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'account-b',
        epoch: 2,
      );
      await tester.pump();
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'account-a',
        epoch: 1,
      );
    case 'server':
      container.read(_server.notifier).state = 'https://server-b.test';
      await tester.pump();
      container.read(_server.notifier).state = 'https://server-a.test';
    case 'permissions':
      container.read(_permissions.notifier).state = {};
      await tester.pump();
      container.read(_permissions.notifier).state = {'employee:view'};
  }
}

Future<void> _pumpPicker(
  WidgetTester tester,
  EmployeeRepository repository, {
  ValueChanged<UtenEmployeePickerItem?>? onPicked,
  Set<String> statuses = const {'active', 'probation', 'onLeave'},
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        employeePickerDepartmentTreeProvider.overrideWith((ref) async => _tree),
        employeeRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: _Harness(onPicked: onPicked, statuses: statuses),
      ),
    ),
  );
  await tester.tap(find.text('打开选择器'));
  await tester.pumpAndSettle();
}

Finder _pickerSearch(WidgetTester tester) => find.descendant(
  of: find.byType(UtenDepartmentTreeView),
  matching: find.byType(TextField),
);

class _Harness extends ConsumerWidget {
  const _Harness({
    this.onPicked,
    this.statuses = const {'active', 'probation', 'onLeave'},
  });
  final ValueChanged<UtenEmployeePickerItem?>? onPicked;
  final Set<String> statuses;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: FilledButton(
      onPressed: () async {
        final picked = await showUtenDepartmentEmployeePicker(
          context,
          ref,
          statuses: statuses,
        );
        onPicked?.call(picked);
      },
      child: const Text('打开选择器'),
    ),
  );
}

class _FakeEmployeeRepository implements EmployeeRepository {
  _FakeEmployeeRepository({this.suppliedRows});
  final List<EmployeeSummary>? suppliedRows;
  final searches = <String?>[];
  final departmentIds = <String?>[];
  final includeSubtrees = <bool>[];

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
  }) async {
    searches.add(search);
    departmentIds.add(departmentId);
    includeSubtrees.add(includeSubtree);
    final items =
        suppliedRows ??
        (search == 'E-100' || departmentId == 'sales'
            ? const [
                EmployeeSummary(
                  id: 'employee',
                  code: 'E-100',
                  fullName: '张三',
                  departmentId: 'sales',
                  departmentName: '销售部',
                ),
              ]
            : const <EmployeeSummary>[]);
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: items.length,
      totalPages: 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PagedEmployeeRepository implements EmployeeRepository {
  final requestedPages = <int>[];

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
  }) async {
    requestedPages.add(page);
    final employee = page == 1
        ? const EmployeeSummary(
            id: 'first',
            code: 'E-001',
            fullName: '第一页员工',
            departmentId: 'sales',
            departmentName: '销售部',
          )
        : const EmployeeSummary(
            id: 'second',
            code: 'E-101',
            fullName: '第二页员工',
            departmentId: 'sales',
            departmentName: '销售部',
          );
    return PagedResult(
      items: [employee],
      page: page,
      size: size,
      total: 101,
      totalPages: 2,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DeferredEmployeeRepository implements EmployeeRepository {
  final _old = Completer<PagedResult<EmployeeSummary>>();
  bool oldRequested = false;

  void completeOld() => _old.complete(
    const PagedResult(
      items: [
        EmployeeSummary(
          id: 'old',
          code: 'OLD',
          fullName: '旧员工',
          departmentId: 'sales',
          departmentName: '销售部',
        ),
      ],
      page: 1,
      size: 100,
      total: 1,
      totalPages: 1,
    ),
  );

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
  }) {
    if (search == 'OLD') {
      oldRequested = true;
      return _old.future;
    }
    if (search == 'NEW') {
      return Future.value(
        PagedResult(
          items: const [
            EmployeeSummary(
              id: 'new',
              code: 'NEW',
              fullName: '新员工',
              departmentId: 'sales',
              departmentName: '销售部',
            ),
          ],
          page: page,
          size: size,
          total: 1,
          totalPages: 1,
        ),
      );
    }
    return Future.value(
      PagedResult(
        items: const [],
        page: page,
        size: size,
        total: 0,
        totalPages: 0,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _tree = [
  DepartmentNode(
    id: 'root',
    code: 'ROOT',
    name: '公司',
    level: '公司',
    children: [
      DepartmentNode(
        id: 'sales',
        code: 'SALES',
        name: '销售部',
        level: '一级部门',
        parentId: 'root',
        children: [
          DepartmentNode(
            id: 'overseas',
            code: 'OVERSEAS',
            name: '海外销售组',
            level: '二级班组',
            parentId: 'sales',
            children: const [],
          ),
        ],
      ),
    ],
  ),
];
