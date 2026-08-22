import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_department_perm_view.dart';
import 'package:uten_imp/features/admin/widgets/admin_user_detail_panel.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _cross = Perm.productionMaterialAnalysisCrossReallocate;
const _legacy = Perm.productionMaterialAnalysisReallocate;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  Finder searchField() => find.descendant(
    of: find.byKey(const ValueKey('permission-catalog-search')),
    matching: find.byType(TextField),
  );

  Finder permissionSwitch(String code) => find.descendant(
    of: find.byKey(ValueKey('permission-$code')),
    matching: find.byType(Switch),
  );

  testWidgets(
    'department catalog searches, grants, revokes and refreshes CROSS independently',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 860));
      final repository = _PermissionRepositoryFake(
        departmentPermissions: {_legacy},
      );
      await tester.pumpWidget(_departmentSubject(repository, preferences));
      await tester.pumpAndSettle();

      await tester.enterText(searchField(), _cross);
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.text('跨物料分析让料与优先补齐'), findsOneWidget);
      expect(find.bySemanticsLabel('跨物料分析让料与优先补齐未配置'), findsOneWidget);
      expect(tester.widget<Switch>(permissionSwitch(_cross)).value, isFalse);

      tester.widget<Switch>(permissionSwitch(_cross)).onChanged!(true);
      await tester.pump();
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();

      expect(repository.departmentUpdates, hasLength(1));
      expect(
        repository.departmentUpdates.single,
        containsAll({_legacy, _cross}),
      );
      expect(repository.departmentUpdates.single, contains(_legacy));
      await tester.enterText(searchField(), _cross);
      await tester.pump(const Duration(milliseconds: 220));
      await tester.enterText(searchField(), _cross);
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.widget<Switch>(permissionSwitch(_cross)).value, isTrue);

      tester.widget<Switch>(permissionSwitch(_cross)).onChanged!(false);
      await tester.pump();
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();

      expect(repository.departmentUpdates, hasLength(2));
      expect(repository.departmentUpdates.last, contains(_legacy));
      expect(repository.departmentUpdates.last, isNot(contains(_cross)));
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets(
    'personal override grants CROSS without changing legacy REALLOCATE',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 900));
      final repository = _PermissionRepositoryFake(
        effective: _effective(department: {_legacy}),
      );
      await tester.pumpWidget(_userSubject(repository, preferences));
      await tester.pumpAndSettle();

      await tester.enterText(searchField(), '跨物料分析让料');
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.widget<Switch>(permissionSwitch(_cross)).value, isFalse);
      tester.widget<Switch>(permissionSwitch(_cross)).onChanged!(true);
      await tester.pump();
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();

      expect(repository.overrideUpdates, hasLength(1));
      expect(repository.overrideUpdates.single.grants, contains(_cross));
      expect(
        repository.overrideUpdates.single.revokes,
        isNot(contains(_legacy)),
      );
      expect(tester.widget<Switch>(permissionSwitch(_cross)).value, isTrue);

      await tester.enterText(searchField(), _legacy);
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.widget<Switch>(permissionSwitch(_legacy)).value, isTrue);
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets(
    'personal override can revoke inherited CROSS while legacy stays effective',
    (tester) async {
      final repository = _PermissionRepositoryFake(
        effective: _effective(department: {_legacy, _cross}),
      );
      await tester.pumpWidget(_userSubject(repository, preferences));
      await tester.pumpAndSettle();

      await tester.enterText(searchField(), _cross);
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.widget<Switch>(permissionSwitch(_cross)).value, isTrue);
      tester.widget<Switch>(permissionSwitch(_cross)).onChanged!(false);
      await tester.pump();
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();

      expect(repository.overrideUpdates.single.revokes, contains(_cross));
      expect(
        repository.overrideUpdates.single.revokes,
        isNot(contains(_legacy)),
      );
      expect(tester.widget<Switch>(permissionSwitch(_cross)).value, isFalse);
    },
  );

  testWidgets(
    'personal authorize-all excludes CROSS but it remains individually grantable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1200));
      final repository = _PermissionRepositoryFake(effective: _effective());
      await tester.pumpWidget(_userSubject(repository, preferences));
      await tester.pumpAndSettle();

      await tester.tap(find.text('全部授权'));
      await tester.pump();

      await tester.enterText(searchField(), _cross);
      await tester.pump(const Duration(milliseconds: 220));
      expect(tester.widget<Switch>(permissionSwitch(_cross)).value, isFalse);
      expect(tester.widget<Switch>(permissionSwitch(_cross)).value, isFalse);
      tester.widget<Switch>(permissionSwitch(_cross)).onChanged!(true);
      await tester.pump();
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();

      expect(repository.overrideUpdates, hasLength(1));
      expect(
        repository.overrideUpdates.single.grants,
        containsAll({_legacy, _cross}),
      );
      expect(repository.overrideUpdates.single.revokes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    },
  );
  testWidgets(
    'department permission error retries and empty catalog is honest',
    (tester) async {
      final repository = _PermissionRepositoryFake(catalogError: true);
      await tester.pumpWidget(_departmentSubject(repository, preferences));
      await tester.pumpAndSettle();
      expect(find.text('部门权限加载失败'), findsOneWidget);

      repository.catalogError = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('生产管理'), findsOneWidget);

      final emptyRepository = _PermissionRepositoryFake(catalog: const []);
      await tester.pumpWidget(_departmentSubject(emptyRepository, preferences));
      await tester.pumpAndSettle();
      expect(find.text('权限目录为空'), findsOneWidget);
    },
  );
}

Widget _departmentSubject(
  _PermissionRepositoryFake repository,
  SharedPreferences preferences,
) => ProviderScope(
  overrides: [
    adminRepositoryProvider.overrideWithValue(repository),
    sharedPreferencesProvider.overrideWithValue(preferences),
  ],
  child: const MaterialApp(
    home: Scaffold(
      body: AdminDepartmentPermView(initialDepartmentId: 'dept-plan'),
    ),
  ),
);

Widget _userSubject(
  _PermissionRepositoryFake repository,
  SharedPreferences preferences,
) => ProviderScope(
  overrides: [
    adminRepositoryProvider.overrideWithValue(repository),
    sharedPreferencesProvider.overrideWithValue(preferences),
  ],
  child: const MaterialApp(
    home: Scaffold(
      body: AdminUserDetailPanel(
        user: AdminUserSummary(
          id: 'user-plan',
          loginAccount: 'planner',
          status: 'active',
          mustChangePassword: false,
          roles: [],
          remoteAccess: false,
          employeeName: '计划员',
          departmentId: 'dept-plan',
          departmentName: '计划部',
        ),
        canManageAuthorization: true,
        onAccountChanged: _noop,
      ),
    ),
  ),
);

void _noop() {}

List<PermissionCatalogGroup> get _catalog => const [
  PermissionCatalogGroup(
    module: '生产管理',
    category: '物料分析',
    permissions: [
      AdminPermission(
        id: 'legacy-reallocate',
        code: _legacy,
        name: '调整分析内物料分配',
        module: '生产管理',
        category: '物料分析',
      ),
      AdminPermission(
        id: 'cross-reallocate',
        code: _cross,
        name: '跨物料分析让料与优先补齐',
        module: '生产管理',
        category: '物料分析',
      ),
    ],
  ),
];

EffectivePermissions _effective({
  Set<String> department = const {},
  Set<String> grants = const {},
  Set<String> revokes = const {},
}) {
  final effective = {...department, ...grants}..removeAll(revokes);
  return EffectivePermissions(
    departmentId: 'dept-plan',
    departmentName: '计划部',
    departmentPermissions: department.toList(),
    baselinePermissions: const [],
    grants: grants.toList(),
    revokes: revokes.toList(),
    effective: effective.toList(),
  );
}

class _OverrideUpdate {
  const _OverrideUpdate(this.grants, this.revokes);
  final List<String> grants;
  final List<String> revokes;
}

class _PermissionRepositoryFake implements AdminRepository {
  _PermissionRepositoryFake({
    Set<String> departmentPermissions = const {},
    EffectivePermissions? effective,
    List<PermissionCatalogGroup>? catalog,
    this.catalogError = false,
  }) : _departmentPermissions = {...departmentPermissions},
       _effectivePermissions = effective ?? _effective(),
       catalog = catalog ?? _catalog;

  Set<String> _departmentPermissions;
  EffectivePermissions _effectivePermissions;
  final List<PermissionCatalogGroup> catalog;
  bool catalogError;
  final List<Set<String>> departmentUpdates = [];
  final List<_OverrideUpdate> overrideUpdates = [];

  @override
  Future<List<DepartmentNode>> departmentTree() async => [
    DepartmentNode(
      id: 'dept-plan',
      code: 'SUB_PLAN',
      name: '计划部',
      level: '一级部门',
      children: const [],
    ),
  ];

  @override
  Future<List<PermissionCatalogGroup>> permissionCatalog() async {
    if (catalogError) throw StateError('catalog unavailable');
    return catalog;
  }

  @override
  Future<List<String>> departmentPermissions(String departmentId) async =>
      _departmentPermissions.toList();

  @override
  Future<void> updateDepartmentPermissions(
    String departmentId,
    List<String> permissionCodes,
  ) async {
    _departmentPermissions = permissionCodes.toSet();
    departmentUpdates.add({..._departmentPermissions});
  }

  @override
  Future<EffectivePermissions> effectivePermissions(String userId) async =>
      _effectivePermissions;

  @override
  Future<void> updateUserPermOverrides(
    String userId, {
    required List<String> grants,
    required List<String> revokes,
  }) async {
    overrideUpdates.add(_OverrideUpdate([...grants], [...revokes]));
    _effectivePermissions = _effective(
      department: _effectivePermissions.departmentPermissions.toSet(),
      grants: grants.toSet(),
      revokes: revokes.toSet(),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
