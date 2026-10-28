import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/admin/widgets/page_permission_drawer.dart';
import 'package:uten_imp/features/admin/widgets/perm_catalog_group_section.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_models.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_repository.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permission_action_type.dart';
import 'package:uten_imp/shared/auth/permission_grant_policy.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';

const _action = 'goods:edit';
final _operatorScope = StateProvider<AuthenticatedScope>(
  (ref) => const AuthenticatedScope(userId: 'manager'),
);

class _ManagerSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'manager', code: 'M1', name: '经理'),
  );
}

PageStaffPermissionState _permission({
  String code = _action,
  bool effective = false,
  bool configured = false,
  bool delegation = false,
  bool editable = true,
  bool? canEnable,
  bool? canDisable,
  bool missingRead = false,
  int version = 7,
  PermissionActionType type = PermissionActionType.edit,
  PermissionGrantPolicy policy = PermissionGrantPolicy.normalOnly,
}) => PageStaffPermissionState(
  code: code,
  name: code == _action
      ? '编辑货品'
      : code == 'goods:create'
      ? '新增货品'
      : '敏感编辑能力',
  actionType: type,
  baseEffective: false,
  delegationEnabled: delegation,
  configuredEnabled: configured,
  effective: effective,
  editable: editable,
  canEnable: canEnable,
  canDisable: canDisable,
  rowVersion: version,
  grantPolicy: policy,
  requiredPermissions: missingRead ? const ['goods:view'] : const [],
  missingDependencies: missingRead ? const ['goods:view'] : const [],
);

PagePermissionEmployeeDetail _detail(
  List<PageStaffPermissionState> permissions, {
  bool grouped = false,
}) => PagePermissionEmployeeDetail(
  surfaceKey: 'basic.goods',
  surfaceTitle: '货品资料',
  departmentId: 'department',
  departmentName: '运营部门',
  employeeId: 'employee',
  fullName: '测试员工',
  code: 'UT001',
  departmentManager: false,
  hasAccount: true,
  superAdminMode: false,
  groups: [
    PagePermissionSurfaceGroup(
      surfaceKey: 'basic.goods',
      title: '货品资料',
      root: !grouped,
      permissions: permissions,
    ),
  ],
);

class _Repository implements PagePermissionDelegationRepository {
  _Repository(this.detail);
  PagePermissionEmployeeDetail detail;
  PagePermissionEmployeeDetail? savedDetail;
  bool detailFailsAfterCommit = false;
  Object? saveFailure;
  int reads = 0;
  final writes = <List<PagePermissionChange>>[];
  Completer<PagePermissionEmployeeDetail>? pendingSave;

  @override
  Future<List<ManagedPermissionDepartment>> managedDepartments(
    String surfaceKey,
  ) async => const [
    ManagedPermissionDepartment(
      departmentId: 'department',
      departmentName: '运营部门',
      level: '一级部门',
    ),
  ];

  @override
  Future<PagePermissionStaffPage> staffPage({
    required String surfaceKey,
    String? departmentId,
    String? search,
    int page = 1,
    int size = 40,
    Map<String, String?> columnQuery = const {},
    String? sort,
    bool ascending = true,
  }) async => PagePermissionStaffPage(
    surfaceKey: surfaceKey,
    departmentId: 'department',
    departmentName: '运营部门',
    items: const [
      PagePermissionStaffSummary(
        employeeId: 'employee',
        departmentId: 'department',
        departmentName: '运营部门',
        fullName: '测试员工',
        code: 'UT001',
        departmentManager: false,
        hasAccount: true,
        accountActive: true,
      ),
    ],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<PagePermissionEmployeeDetail> employeePermissions({
    required String surfaceKey,
    required String departmentId,
    required String employeeId,
  }) async {
    reads++;
    return detail;
  }

  @override
  Future<PagePermissionEmployeeDetail> saveEmployeePermissions({
    required String surfaceKey,
    required String departmentId,
    required String employeeId,
    required List<PagePermissionChange> changes,
  }) async {
    writes.add(List.of(changes));
    if (pendingSave != null) return pendingSave!.future;
    if (saveFailure != null) throw saveFailure!;
    detail = savedDetail ?? detail;
    if (detailFailsAfterCommit) {
      throw PagePermissionSaveCommittedError(NetworkException('最新配置读取中断'));
    }
    return detail;
  }
}

class _Snapshot extends SessionSnapshotNotifier {
  int refreshCalls = 0;
  bool failRefresh = false;
  @override
  Future<SessionSnapshot?> build() async =>
      SessionSnapshot(delegableSurfaceKeys: const {'basic.goods'});
  @override
  Future<void> refresh() async {
    refreshCalls++;
    state = failRefresh
        ? AsyncError(StateError('会话读取中断'), StackTrace.current)
        : AsyncData(
            SessionSnapshot(delegableSurfaceKeys: const {'basic.goods'}),
          );
  }
}

class _Harness {
  _Harness(this.container, this.snapshot, this.messages);
  final ProviderContainer container;
  final _Snapshot snapshot;
  final List<String> messages;
}

Future<_Harness> _mount(
  WidgetTester tester,
  _Repository repository, {
  bool refreshFails = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final snapshot = _Snapshot()..failRefresh = refreshFails;
  final container = ProviderContainer(
    overrides: [
      pagePermissionDelegationRepositoryProvider.overrideWithValue(repository),
      sessionSnapshotProvider.overrideWith(() => snapshot),
      sharedPreferencesProvider.overrideWithValue(preferences),
      currentPermissionsProvider.overrideWithValue(const {}),
      isSuperAdminProvider.overrideWithValue(false),
      authenticatedScopeProvider.overrideWith(
        (ref) => ref.watch(_operatorScope),
      ),
      sessionProvider.overrideWith(_ManagerSession.new),
      apiClientProvider.overrideWithValue(_NoNetworkApi()),
      apiBaseUrlProvider.overrideWithValue('https://permission-test.invalid'),
    ],
  );
  addTearDown(container.dispose);
  await container.read(sessionSnapshotProvider.future);
  final messages = <String>[];
  container.listen<List<AppNotification>>(
    appNotificationProvider,
    (_, next) => messages.addAll(next.map((message) => message.message)),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PagePermissionDrawer(
            scope: PagePermissionScope(
              surfaceKey: 'basic.goods',
              title: '货品资料',
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(const ValueKey('page-permission-staff-employee')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('确定'));
  await tester.pumpAndSettle();
  final sections = find.byType(PermCatalogGroupSection);
  if (sections.evaluate().isNotEmpty) {
    final section = sections.first;
    await tester.tap(
      find.descendant(
        of: section,
        matching: find.text(
          tester.widget<PermCatalogGroupSection>(section).title,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('编辑(含新增与修改)'));
  await tester.pumpAndSettle();
  return _Harness(container, snapshot, messages);
}

class _NoNetworkApi extends ApiClient {
  _NoNetworkApi() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) => throw StateError('Unexpected network read: $path');
}

Finder _switch(String code) =>
    find.byKey(ValueKey('page-permission-employee-$code'));
Finder get _save => find.byKey(const ValueKey('page-permission-save'));

Future<void> _saveAndSettle(WidgetTester tester) async {
  await tester.tap(_save);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('operator change removes retained employee permission details', (
    tester,
  ) async {
    final repository = _Repository(_detail([_permission()]));
    final harness = await _mount(tester, repository);
    expect(_switch(_action), findsOneWidget);
    harness.container.read(_operatorScope.notifier).state =
        const AuthenticatedScope(userId: 'another-manager');
    await tester.pumpAndSettle();
    expect(_switch(_action), findsNothing);
    expect(find.text('登录身份、权限或连接已变化，请关闭并重新打开权限设置。'), findsOneWidget);
    expect(repository.writes, isEmpty);
  });

  testWidgets(
    'late permission save cannot repopulate another operators drawer or refresh their session',
    (tester) async {
      final repository = _Repository(_detail([_permission()]));
      final harness = await _mount(tester, repository);
      await tester.tap(_switch(_action));
      await tester.pumpAndSettle();
      final pending = Completer<PagePermissionEmployeeDetail>();
      repository.pendingSave = pending;
      await tester.tap(_save);
      await tester.pump();
      expect(repository.writes, hasLength(1));
      harness.container.read(_operatorScope.notifier).state =
          const AuthenticatedScope(userId: 'another-manager');
      pending.complete(
        _detail([_permission(effective: true, configured: true, version: 8)]),
      );
      await tester.pumpAndSettle();
      expect(_switch(_action), findsNothing);
      expect(harness.snapshot.refreshCalls, 0);
      expect(repository.writes, hasLength(1));
    },
  );
  testWidgets(
    'inactive manager delegation is OFF and can be explicitly renewed with its current version',
    (tester) async {
      final repository =
          _Repository(
              _detail([
                _permission(
                  configured: true,
                  delegation: true,
                  canEnable: true,
                  canDisable: true,
                ),
              ]),
            )
            ..savedDetail = _detail([
              _permission(
                configured: true,
                delegation: true,
                effective: true,
                version: 8,
              ),
            ]);
      final harness = await _mount(tester, repository);
      expect(tester.widget<Switch>(_switch(_action)).value, isFalse);
      expect(find.text('原授权已失效，当前未授权。'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('permission-repair-goods:edit')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(_switch(_action)).value, isTrue);
      await _saveAndSettle(tester);
      expect(repository.writes.single.single.code, _action);
      expect(repository.writes.single.single.enabled, isTrue);
      expect(repository.writes.single.single.expectedVersion, 7);
      expect(harness.snapshot.refreshCalls, 1);
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'centrally revoked historical delegation permits cleanup but no individual or batch regrant',
    (tester) async {
      final repository = _Repository(
        _detail([
          _permission(
            configured: true,
            delegation: true,
            canEnable: false,
            canDisable: true,
          ),
        ], grouped: true),
      )..savedDetail = _detail([_permission(version: 8)], grouped: true);
      await _mount(tester, repository);
      expect(tester.widget<Switch>(_switch(_action)).value, isFalse);
      expect(tester.widget<Switch>(_switch(_action)).onChanged, isNull);
      expect(
        find.byKey(const ValueKey('permission-repair-goods:edit')),
        findsNothing,
      );
      expect(find.text('当前只能移除原有授权，不能重新授权。'), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
      await tester.tap(find.byTooltip('本组批量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本组授权(不含敏感及锁定项)'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      expect(repository.writes, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('permission-clear-inactive-goods:edit')),
      );
      await tester.pumpAndSettle();
      await _saveAndSettle(tester);
      expect(repository.writes.single.single.enabled, isFalse);
      expect(repository.writes.single.single.expectedVersion, 7);
    },
  );

  testWidgets(
    'inherited action missing reads cannot be falsely repaired or removed through a manager delegation',
    (tester) async {
      final repository = _Repository(
        _detail([
          _permission(
            configured: true,
            delegation: true,
            canEnable: false,
            canDisable: false,
            missingRead: true,
          ),
        ], grouped: true),
      );
      await _mount(tester, repository);
      expect(tester.widget<Switch>(_switch(_action)).onChanged, isNull);
      expect(
        find.byKey(const ValueKey('permission-repair-goods:edit')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('permission-clear-inactive-goods:edit')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('本组批量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本组全部收回（不含锁定项）'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      expect(repository.writes, isEmpty);
    },
  );

  testWidgets(
    'inactive uneditable delegation can still be explicitly cleared even while its switch is OFF',
    (tester) async {
      final repository = _Repository(
        _detail([
          _permission(configured: true, delegation: true, editable: false),
        ]),
      )..savedDetail = _detail([_permission(version: 8)]);
      final harness = await _mount(tester, repository);
      expect(tester.widget<Switch>(_switch(_action)).value, isFalse);
      expect(tester.widget<Switch>(_switch(_action)).onChanged, isNull);
      await tester.tap(
        find.byKey(const ValueKey('permission-clear-inactive-goods:edit')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(_save).onPressed, isNotNull);
      await _saveAndSettle(tester);
      expect(repository.writes.single.single.enabled, isFalse);
      expect(repository.writes.single.single.expectedVersion, 7);
      expect(harness.snapshot.refreshCalls, 1);
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
    },
  );

  testWidgets(
    'renewing an inactive action submits that action and lets the server choose allowed page reads',
    (tester) async {
      final repository =
          _Repository(
              _detail([_permission(configured: true, missingRead: true)]),
            )
            ..savedDetail = _detail([
              _permission(configured: true, effective: true, version: 8),
            ]);
      final harness = await _mount(tester, repository);
      expect(tester.widget<Switch>(_switch(_action)).value, isFalse);
      expect(
        find.text('授权配置已保留，但当前未生效，且缺少对应页面所需的查看权限。请核对授权状态；需要进入该页面时再补齐查看权限。'),
        findsOneWidget,
      );
      expect(find.text('重新授权'), findsOneWidget);
      expect(find.text('补齐所需查看权限'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('permission-repair-goods:edit')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('保存时只补齐允许自动授予的普通查看权限；需要恢复已收回的权限或授予敏感权限时，请在相应授权项中单独确认。'),
        findsOneWidget,
      );
      await _saveAndSettle(tester);
      expect(repository.writes.single.map((change) => change.code), [_action]);
      expect(repository.writes.single.single.enabled, isTrue);
      expect(harness.snapshot.refreshCalls, 1);
      expect(tester.widget<Switch>(_switch(_action)).value, isTrue);
    },
  );

  testWidgets(
    'family bulk enables only ordinary permissions and can turn them off while a sensitive item stays OFF',
    (tester) async {
      const sensitive = PermissionGrantPolicy({
        PermissionGrantPolicy.bulkExcluded,
      });
      List<PageStaffPermissionState> states(bool enabled, int version) => [
        _permission(
          code: 'goods:create',
          type: PermissionActionType.create,
          effective: enabled,
          configured: enabled,
          version: version,
        ),
        _permission(effective: enabled, configured: enabled, version: version),
        _permission(
          code: 'goods:sensitive_edit',
          policy: sensitive,
          version: 4,
        ),
      ];
      final repository = _Repository(_detail(states(false, 7)))
        ..savedDetail = _detail(states(true, 8));
      final harness = await _mount(tester, repository);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Switch>(_switch('goods:sensitive_edit')).value,
        isFalse,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await _saveAndSettle(tester);
      expect(repository.writes.single.map((change) => change.code).toSet(), {
        'goods:create',
        _action,
      });
      expect(
        repository.writes.single.every((change) => change.enabled),
        isTrue,
      );
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      repository.savedDetail = _detail(states(false, 9));
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await _saveAndSettle(tester);
      expect(repository.writes.last.map((change) => change.code).toSet(), {
        'goods:create',
        _action,
      });
      expect(repository.writes.last.every((change) => !change.enabled), isTrue);
      expect(harness.snapshot.refreshCalls, 2);
    },
  );

  testWidgets(
    'acknowledged PUT followed by failed detail read clears pending changes and never offers a duplicate save',
    (tester) async {
      final repository = _Repository(_detail([_permission()]))
        ..savedDetail = _detail([
          _permission(configured: true, effective: true, version: 8),
        ])
        ..detailFailsAfterCommit = true;
      final harness = await _mount(tester, repository);
      await tester.tap(_switch(_action));
      await tester.pumpAndSettle();
      await _saveAndSettle(tester);
      expect(repository.writes, hasLength(1));
      expect(harness.snapshot.refreshCalls, 1);
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      expect(find.text('权限已保存，但未能读取最新配置。请重新加载当前员工后再操作。'), findsOneWidget);
      expect(
        harness.messages.any((message) => message.contains('权限已保存')),
        isTrue,
      );
      expect(
        harness.messages.any(
          (message) => message.contains('未提交') || message.contains('保存失败'),
        ),
        isFalse,
      );
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(repository.writes, hasLength(1));
      expect(repository.reads, 2);
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
    },
  );

  testWidgets(
    'session refresh failure is reported as saved with refresh pending rather than a failed permission write',
    (tester) async {
      final repository = _Repository(_detail([_permission()]))
        ..savedDetail = _detail([
          _permission(configured: true, effective: true, version: 8),
        ]);
      final harness = await _mount(tester, repository, refreshFails: true);
      await tester.tap(_switch(_action));
      await tester.pumpAndSettle();
      await _saveAndSettle(tester);
      expect(repository.writes, hasLength(1));
      expect(harness.snapshot.refreshCalls, 1);
      expect(harness.messages, contains('权限已保存，但当前会话未能刷新。请刷新页面后核对最新权限。'));
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      expect(tester.widget<Switch>(_switch(_action)).value, isTrue);
    },
  );

  testWidgets(
    'explicit group revoke also clears inactive ordinary and sensitive delegation records',
    (tester) async {
      const sensitive = PermissionGrantPolicy({
        PermissionGrantPolicy.bulkExcluded,
      });
      final repository =
          _Repository(
              _detail([
                _permission(
                  configured: true,
                  delegation: true,
                  editable: false,
                ),
                _permission(
                  code: 'goods:sensitive_edit',
                  configured: true,
                  delegation: true,
                  editable: false,
                  policy: sensitive,
                ),
                _permission(
                  code: 'goods:create',
                  type: PermissionActionType.create,
                  configured: true,
                  effective: true,
                ),
              ], grouped: true),
            )
            ..savedDetail = _detail([
              _permission(version: 8),
              _permission(
                code: 'goods:sensitive_edit',
                policy: sensitive,
                version: 8,
              ),
              _permission(
                code: 'goods:create',
                type: PermissionActionType.create,
                version: 8,
              ),
            ], grouped: true);
      final harness = await _mount(tester, repository);
      expect(tester.widget<Switch>(_switch(_action)).value, isFalse);
      expect(
        tester.widget<Switch>(_switch('goods:sensitive_edit')).value,
        isFalse,
      );
      await tester.tap(find.byTooltip('本组批量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本组全部收回（不含锁定项）'));
      await tester.pumpAndSettle();
      await _saveAndSettle(tester);
      expect(repository.writes.single.map((change) => change.code).toSet(), {
        _action,
        'goods:sensitive_edit',
        'goods:create',
      });
      expect(
        repository.writes.single.every((change) => !change.enabled),
        isTrue,
      );
      expect(harness.snapshot.refreshCalls, 1);
    },
  );

  testWidgets(
    'an uncertain transport failure says the save result needs checking and does not retry the write',
    (tester) async {
      final repository = _Repository(_detail([_permission()]))
        ..saveFailure = NetworkTimeoutException();
      final harness = await _mount(tester, repository);
      await tester.tap(_switch(_action));
      await tester.pumpAndSettle();
      await _saveAndSettle(tester);
      expect(repository.writes, hasLength(1));
      expect(harness.snapshot.refreshCalls, 0);
      expect(harness.messages, contains('权限保存结果尚未确认，请先重新读取当前员工的权限，核对后再操作。'));
      expect(
        harness.messages.any(
          (message) => message.contains('未提交') || message.contains('保存失败'),
        ),
        isFalse,
      );
    },
  );

  test(
    'repository wraps only the post-commit GET failure and preserves its cause',
    () async {
      final api = _RecordingApi();
      final repository = PagePermissionDelegationRepository(api);
      await expectLater(
        repository.saveEmployeePermissions(
          surfaceKey: 'basic.goods',
          departmentId: 'department',
          employeeId: 'employee',
          changes: const [
            PagePermissionChange(
              code: _action,
              enabled: true,
              expectedVersion: 7,
            ),
          ],
        ),
        throwsA(
          isA<PagePermissionSaveCommittedError>().having(
            (error) => error.cause,
            'cause',
            same(api.readFailure),
          ),
        ),
      );
      expect(api.writes, 1);
      expect(api.reads, 1);
      expect(api.body, {
        'changes': [
          {'code': _action, 'enabled': true, 'expectedVersion': 7},
        ],
      });
    },
  );

  test(
    'repository propagates an unacknowledged PUT failure without claiming a committed save or reading details',
    () async {
      final api = _RecordingApi()..failWrite = true;
      final repository = PagePermissionDelegationRepository(api);
      await expectLater(
        repository.saveEmployeePermissions(
          surfaceKey: 'basic.goods',
          departmentId: 'department',
          employeeId: 'employee',
          changes: const [
            PagePermissionChange(
              code: _action,
              enabled: true,
              expectedVersion: 7,
            ),
          ],
        ),
        throwsA(same(api.writeFailure)),
      );
      expect(api.writes, 1);
      expect(api.reads, 0);
    },
  );
}

class _RecordingApi extends ApiClient {
  _RecordingApi() : super(Dio());
  int writes = 0, reads = 0;
  bool failWrite = false;
  Object? body;
  final readFailure = NetworkException('读取失败');
  final writeFailure = NetworkException('写入未确认');
  @override
  Future<Map<String, dynamic>> putWithQuery(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    writes++;
    this.body = body;
    if (failWrite) throw writeFailure;
    return {};
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads++;
    throw readFailure;
  }
}
