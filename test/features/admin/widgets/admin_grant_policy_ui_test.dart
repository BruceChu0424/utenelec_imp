// 授权策略驱动的管理页(ADR-109 / permissions-01、02)：
//   · 能否配给部门只看服务端下发的 grantPolicy：只能逐人授予的码不在部门页出现；
//   · 「全部配置」只把范围交给服务端(一次请求，服务端按策略补齐)，不在本地拼清单；
//   · 有未保存的逐项修改时先让管理员保存或撤销，不发批量请求；
//   · 全员基础包只显示能放进基础包的码，保存时交出期望的完整集合。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_baseline_perm_view.dart';
import 'package:uten_imp/features/admin/widgets/admin_department_perm_view.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/shared/auth/permission_grant_policy.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _normal = 'stock:view';
const _bulkExcluded = 'finance:view:all';
const _individualOnly = 'audit_log:view';

final _catalog = [
  const PermissionCatalogGroup(
    module: '仓库管理',
    category: '库存',
    permissions: [
      AdminPermission(
        id: 'p-normal',
        code: _normal,
        name: '查看库存',
        module: '仓库管理',
        category: '库存',
      ),
      AdminPermission(
        id: 'p-bulk-excluded',
        code: _bulkExcluded,
        name: '查看全部钱流数据',
        module: '仓库管理',
        category: '库存',
        grantPolicy: PermissionGrantPolicy({
          PermissionGrantPolicy.bulkExcluded,
        }),
      ),
      AdminPermission(
        id: 'p-individual',
        code: _individualOnly,
        name: '查看审计日志',
        module: '仓库管理',
        category: '库存',
        grantPolicy: PermissionGrantPolicy({
          PermissionGrantPolicy.individualOnly,
        }),
      ),
    ],
  ),
];

class _Repo implements AdminRepository {
  Set<String> department = {};
  Set<String> baseline = {};
  final grantAllScopes = <PermissionBulkScope>[];
  final baselineUpdates = <List<String>>[];

  @override
  Future<List<DepartmentNode>> departmentTree() async => [
    DepartmentNode(
      id: 'dept-wh',
      code: 'SUB_WH',
      name: '仓库部',
      level: '一级部门',
      children: const [],
    ),
  ];

  @override
  Future<List<PermissionCatalogGroup>> permissionCatalog() async => _catalog;

  @override
  Future<List<String>> departmentPermissions(String departmentId) async =>
      department.toList();

  @override
  Future<PermissionChange> updateDepartmentPermissions(
    String departmentId,
    List<String> permissionCodes,
  ) async {
    final before = department;
    department = permissionCodes.toSet();
    return PermissionChange(
      added: department.difference(before).toList(),
      removed: before.difference(department).toList(),
    );
  }

  @override
  Future<PermissionChange> grantAllToDepartment(
    String departmentId,
    PermissionBulkScope scope,
  ) async {
    grantAllScopes.add(scope);
    // 服务端按策略补齐：只有普通码会被带上。
    final added = {_normal}.difference(department);
    department = {...department, ...added};
    return PermissionChange(added: added.toList(), removed: const []);
  }

  @override
  Future<List<String>> permissionBaseline() async => baseline.toList();

  @override
  Future<PermissionChange> updatePermissionBaseline(List<String> codes) async {
    baselineUpdates.add(codes);
    final before = baseline;
    baseline = codes.toSet();
    return PermissionChange(
      added: baseline.difference(before).toList(),
      removed: before.difference(baseline).toList(),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  // 通知条自带停留计时；边产生边记，断言才稳。
  final notices = <String>[];

  Widget subject(_Repo repo, Widget child) {
    final container = ProviderContainer(
      overrides: [
        adminRepositoryProvider.overrideWithValue(repo),
        sharedPreferencesProvider.overrideWithValue(preferences),
        // 本地服务可达性探针带 60 秒周期计时器；按 Web 形态构造就不起探针。
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(preferences, web: true),
        ),
      ],
    );
    addTearDown(container.dispose);
    notices.clear();
    container.listen<List<AppNotification>>(
      appNotificationProvider,
      (previous, next) => notices.addAll(next.map((item) => item.message)),
      fireImmediately: true,
    );
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  Future<void> expandCatalog(WidgetTester tester) async {
    await tester.tap(find.text('仓库管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('库存'));
    await tester.pumpAndSettle();
  }

  testWidgets('department page hides individual-only codes and hands '
      'grant-all to the server in one request', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = _Repo();
    await tester.pumpWidget(
      subject(
        repo,
        const AdminDepartmentPermView(initialDepartmentId: 'dept-wh'),
      ),
    );
    await tester.pumpAndSettle();
    await expandCatalog(tester);

    expect(find.text('查看库存'), findsOneWidget);
    expect(find.text('查看全部钱流数据'), findsOneWidget);
    expect(find.text('不随批量授权'), findsOneWidget);
    expect(find.text('查看审计日志'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('permission-grant-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认授权'));
    await tester.pumpAndSettle();

    expect(repo.grantAllScopes, [PermissionBulkScope.everything]);
    expect(repo.department, {_normal});
  });

  testWidgets('grant-all waits until pending single edits are saved', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = _Repo();
    await tester.pumpWidget(
      subject(
        repo,
        const AdminDepartmentPermView(initialDepartmentId: 'dept-wh'),
      ),
    );
    await tester.pumpAndSettle();
    await expandCatalog(tester);

    final normalSwitch = find.descendant(
      of: find.byKey(const ValueKey('permission-$_normal')),
      matching: find.byType(Switch),
    );
    tester.widget<Switch>(normalSwitch).onChanged!(true);
    await tester.pump();
    expect(find.text('保存更改'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('permission-grant-all')));
    await tester.pumpAndSettle();

    expect(find.text('确认授权'), findsNothing);
    expect(repo.grantAllScopes, isEmpty);
    expect(notices, contains('请先保存或撤销当前的逐项修改，再做批量授权'));
  });

  testWidgets('baseline page shows only baseline-eligible codes and saves '
      'the desired set', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = _Repo();
    await tester.pumpWidget(subject(repo, const AdminBaselinePermView()));
    await tester.pumpAndSettle();
    await expandCatalog(tester);

    expect(find.text('查看库存'), findsOneWidget);
    expect(find.text('查看全部钱流数据'), findsNothing);
    expect(find.text('查看审计日志'), findsNothing);
    expect(find.byKey(const ValueKey('permission-grant-all')), findsNothing);

    tester
        .widget<Switch>(find.byKey(const ValueKey('baseline-switch-$_normal')))
        .onChanged!(true);
    await tester.pump();
    await tester.tap(find.text('保存更改'));
    await tester.pumpAndSettle();

    expect(repo.baselineUpdates, [
      [_normal],
    ]);
  });
}
