// 授权策略驱动的管理页(ADR-109 / permissions-01、02)：
//   · 能否配给部门只看服务端下发的 grantPolicy：只能逐人授予的码不在部门页出现；
//   · 「全部配置」只把范围交给服务端(一次请求，服务端按策略补齐)，不在本地拼清单；
//   · 有未保存的逐项修改时先让管理员保存或撤销，不发批量请求；
//   · 全员基础包只显示能放进基础包的码，保存时交出期望的完整集合；
//   · 基础包钉死码(V832/ADR-170)开关锁定、批量移出跳过、恒在提交集合里。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_baseline_perm_view.dart';
import 'package:uten_imp/features/admin/widgets/admin_department_perm_view.dart';
import 'package:uten_imp/features/admin/widgets/admin_user_detail_panel.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/shared/auth/permission_grant_policy.dart';
import 'package:uten_imp/shared/auth/permission_action_type.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _normal = 'stock:view';
const _bulkExcluded = 'finance:view:all';
const _individualOnly = 'audit_log:view';
const _action = 'goods:edit';
const _pageRead = 'goods:view';
const _revokedRead = 'client:view';
const _sensitiveRead = 'goods:sensitive:view';
const _otherAction = 'client:edit';

const _dependencyCatalog = [
  PermissionCatalogGroup(
    module: '仓库管理',
    category: '库存',
    permissions: [
      AdminPermission(
        id: _action,
        code: _action,
        name: '编辑货品',
        module: '仓库管理',
        category: '库存',
        actionType: PermissionActionType.edit,
      ),
      AdminPermission(
        id: _otherAction,
        code: _otherAction,
        name: '编辑其他资料',
        module: '仓库管理',
        category: '库存',
        actionType: PermissionActionType.edit,
      ),
      AdminPermission(
        id: _pageRead,
        code: _pageRead,
        name: '查看货品页面',
        module: '仓库管理',
        category: '库存',
        actionType: PermissionActionType.view,
      ),
      AdminPermission(
        id: _revokedRead,
        code: _revokedRead,
        name: '查看客户页面',
        module: '仓库管理',
        category: '库存',
        actionType: PermissionActionType.view,
      ),
      AdminPermission(
        id: _sensitiveRead,
        code: _sensitiveRead,
        name: '敏感页面查看',
        module: '仓库管理',
        category: '库存',
        actionType: PermissionActionType.view,
        grantPolicy: PermissionGrantPolicy({
          PermissionGrantPolicy.bulkExcluded,
        }),
      ),
    ],
  ),
];

const _catalog = [
  PermissionCatalogGroup(
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
  _Repo([this.catalog = _catalog]);

  final List<PermissionCatalogGroup> catalog;
  Set<String> department = {};
  Set<String> baseline = {};
  Map<String, List<String>> dependencies = {};
  List<String>? completedDepartmentResponse;
  final departmentUpdates = <List<String>>[];
  final grantAllScopes = <PermissionBulkScope>[];
  final baselineUpdates = <List<String>>[];
  final overrideUpdates = <(List<String>, List<String>)>[];
  EffectivePermissions userPermissions = const EffectivePermissions(
    departmentPermissions: [],
    baselinePermissions: [],
    grants: [],
    revokes: [],
    effective: [],
  );

  @override
  Future<EffectivePermissions> effectivePermissions(String userId) async =>
      userPermissions;

  @override
  Future<PermissionChange> updateUserPermOverrides(
    String userId, {
    required List<String> grants,
    required List<String> revokes,
  }) async {
    overrideUpdates.add((List.of(grants), List.of(revokes)));
    return PermissionChange.none;
  }

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
  Future<List<PermissionCatalogGroup>> permissionCatalog() async => catalog;

  @override
  Future<List<String>> departmentPermissions(String departmentId) async =>
      DepartmentPermissionCodes(
        department.toList(),
        requiredPermissions: dependencies,
        missingDependencies: {
          for (final code in department)
            if ((dependencies[code] ?? const <String>[]).any(
              (required) => !department.contains(required),
            ))
              code: dependencies[code]!
                  .where((required) => !department.contains(required))
                  .toList(),
        },
      );

  @override
  Future<PermissionChange> updateDepartmentPermissions(
    String departmentId,
    List<String> permissionCodes,
  ) async {
    final before = department;
    departmentUpdates.add(List.of(permissionCodes));
    department = (completedDepartmentResponse ?? permissionCodes).toSet();
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
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
  }

  Future<void> expandCatalog(WidgetTester tester) async {
    await tester.tap(find.text('仓库管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('库存'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'existing incomplete department grant offers a repair using the current configuration',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo =
          _Repo([
              ..._catalog,
              const PermissionCatalogGroup(
                module: '业务页面',
                category: '所需页面',
                permissions: [
                  AdminPermission(
                    id: 'required-page:view',
                    code: 'required-page:view',
                    name: '查看业务页面',
                    module: '业务页面',
                    category: '所需页面',
                    actionType: PermissionActionType.view,
                  ),
                ],
              ),
            ])
            ..department = {_normal}
            ..dependencies = {
              _normal: ['required-page:view'],
            }
            ..completedDepartmentResponse = [_normal, 'required-page:view'];
      await tester.pumpWidget(
        subject(
          repo,
          const AdminDepartmentPermView(initialDepartmentId: 'dept-wh'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('有 1 项动作缺少所需查看权限'), findsOneWidget);
      await tester.tap(find.text('补齐所需查看权限'));
      await tester.pumpAndSettle();
      expect(repo.departmentUpdates.single.toSet(), {
        _normal,
        'required-page:view',
      });
      expect(repo.department, {_normal, 'required-page:view'});
      expect(find.text('补齐所需查看权限'), findsNothing);
    },
  );

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

  Finder permissionSwitch(String code) => find.descendant(
    of: find.byKey(ValueKey('permission-$code')),
    matching: find.byType(Switch),
  );

  Widget userPanel() => AdminUserDetailPanel(
    user: const AdminUserSummary(
      id: 'user',
      employeeId: 'employee',
      employeeName: '在职员工',
      employeeStatus: 'active',
      currentEmployee: true,
      loginAccount: 'UT001',
      status: 'active',
      mustChangePassword: false,
      remoteAccess: false,
    ),
    canManageAuthorization: true,
    onAccountChanged: () {},
  );

  testWidgets(
    'personal action toggle preserves a revoked navigation read and submits only its explicit code',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = _Repo(_dependencyCatalog)
        ..userPermissions = const EffectivePermissions(
          departmentPermissions: [],
          baselinePermissions: [],
          grants: [],
          revokes: [_pageRead],
          effective: [],
          requiredPermissions: {
            _action: [_pageRead],
          },
        );
      await tester.pumpWidget(subject(repo, userPanel()));
      await tester.pumpAndSettle();
      await expandCatalog(tester);
      tester.widget<Switch>(permissionSwitch(_action)).onChanged!(true);
      await tester.pump();
      expect(tester.widget<Switch>(permissionSwitch(_action)).value, isTrue);
      expect(find.text('待保存'), findsWidgets);
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();
      expect(repo.overrideUpdates.single.$1, [_action]);
      expect(repo.overrideUpdates.single.$2, [_pageRead]);
    },
  );

  testWidgets(
    'unrelated pending edit does not remove a server-confirmed action missing navigation reads',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = _Repo(_dependencyCatalog)
        ..userPermissions = const EffectivePermissions(
          departmentPermissions: [],
          baselinePermissions: [],
          grants: [_action],
          revokes: [_pageRead],
          effective: [_action],
          requiredPermissions: {
            _action: [_pageRead],
          },
          missingDependencies: {
            _action: [_pageRead],
          },
        );
      await tester.pumpWidget(subject(repo, userPanel()));
      await tester.pumpAndSettle();
      await expandCatalog(tester);
      expect(tester.widget<Switch>(permissionSwitch(_action)).value, isTrue);
      tester.widget<Switch>(permissionSwitch(_otherAction)).onChanged!(true);
      await tester.pump();
      expect(tester.widget<Switch>(permissionSwitch(_action)).value, isTrue);
      expect(find.text('尚缺对应页面所需的查看权限'), findsOneWidget);
      expect(find.text('未完整生效'), findsNothing);
    },
  );

  testWidgets(
    'explicit personal repair adds ordinary reads without regranting revoked or sensitive reads',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = _Repo(_dependencyCatalog)
        ..userPermissions = const EffectivePermissions(
          departmentPermissions: [],
          baselinePermissions: [],
          grants: [_action],
          revokes: [_revokedRead],
          effective: [_action],
          missingDependencies: {
            _action: [_pageRead, _revokedRead, _sensitiveRead, 'unknown:view'],
          },
        );
      await tester.pumpWidget(subject(repo, userPanel()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('补齐所需查看权限'));
      await tester.pump();
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();
      expect(repo.overrideUpdates.single.$1.toSet(), {_action, _pageRead});
      expect(repo.overrideUpdates.single.$2, [_revokedRead]);
    },
  );

  testWidgets(
    'department toggle never adds navigation reads or undoes an explicit read removal',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = _Repo(_dependencyCatalog)
        ..department = {_pageRead}
        ..dependencies = {
          _action: [_pageRead, _sensitiveRead],
        };
      await tester.pumpWidget(
        subject(
          repo,
          const AdminDepartmentPermView(initialDepartmentId: 'dept-wh'),
        ),
      );
      await tester.pumpAndSettle();
      await expandCatalog(tester);
      tester.widget<Switch>(permissionSwitch(_pageRead)).onChanged!(false);
      await tester.pump();
      tester.widget<Switch>(permissionSwitch(_action)).onChanged!(true);
      await tester.pump();
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();
      expect(repo.departmentUpdates.single, [_action]);
    },
  );

  testWidgets(
    'explicit department repair adds only ordinary known view permissions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = _Repo(_dependencyCatalog)
        ..department = {_action}
        ..dependencies = {
          _action: [_pageRead, _sensitiveRead, 'unknown:view'],
        };
      await tester.pumpWidget(
        subject(
          repo,
          const AdminDepartmentPermView(initialDepartmentId: 'dept-wh'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('补齐所需查看权限'));
      await tester.pumpAndSettle();
      expect(repo.departmentUpdates.single.toSet(), {_action, _pageRead});
    },
  );

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

  testWidgets('baseline page locks pinned codes against single and bulk '
      'removal', (tester) async {
    const pinned = 'notice:read';
    final repo = _Repo(const [
      PermissionCatalogGroup(
        module: '系统管理',
        category: '通知',
        permissions: [
          AdminPermission(
            id: 'p-notice-read',
            code: pinned,
            name: '阅读通知',
            module: '系统管理',
            category: '通知',
            baselinePinned: true,
          ),
          AdminPermission(
            id: 'p-notice-manage',
            code: 'notice:manage',
            name: '发布通知',
            module: '系统管理',
            category: '通知',
          ),
        ],
      ),
    ])..baseline = {pinned, 'notice:manage'};
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(subject(repo, const AdminBaselinePermView()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('系统管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通知'));
    await tester.pumpAndSettle();

    final pinnedSwitch = tester.widget<Switch>(
      find.byKey(const ValueKey('baseline-switch-$pinned')),
    );
    expect(pinnedSwitch.onChanged, isNull, reason: '钉死码开关必须禁用');
    expect(pinnedSwitch.value, isTrue, reason: '钉死码按不变式恒显示已包含');
    expect(
      find.byKey(const ValueKey('baseline-pinned-$pinned')),
      findsOneWidget,
    );

    // 「本模块全部移出」批量移出会跳过钉死码，只移掉同模块的普通码。
    await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本模块全部移出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存更改'));
    await tester.pumpAndSettle();

    expect(repo.baselineUpdates.last, [pinned]);
  });
}
