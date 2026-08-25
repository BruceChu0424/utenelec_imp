import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_user_detail_panel.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _permissionCode = 'account:test';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '375px resigned account blocks recovery and grants but can clear/reset',
    (tester) async {
      final repository = _LifecycleRepository(
        effective: _effective(grants: const {_permissionCode}),
      );
      await _pumpPanel(
        tester,
        repository: repository,
        user: _user(status: 'disabled'),
      );

      expect(find.bySemanticsLabel(RegExp('已离职.*复职')), findsWidgets);
      expect(_button(tester, '授权云端').onPressed, isNull);
      expect(_button(tester, '授权云端').onDisabledTap, isNotNull);
      expect(_button(tester, '设为超管').onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('permission-catalog-search')),
        '测试个人授权',
      );
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pump();
      expect(_permissionSwitch(tester).onChanged, isNull);
      expect(_button(tester, '清空个人授权').onPressed, isNotNull);

      await tester.tap(_buttonFinder('清空个人授权'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空授权'));
      await tester.pumpAndSettle();
      expect(repository.overrideUpdates, hasLength(1));
      expect(repository.overrideUpdates.single.$1, isEmpty);
      expect(repository.overrideUpdates.single.$2, isEmpty);

      await tester.tap(find.text('账号安全').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(_buttonFinder('启用'));
      expect(_button(tester, '启用').onPressed, isNull);
      expect(_button(tester, '启用').onDisabledTap, isNotNull);
      expect(_button(tester, '设置临时密码').onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resigned account keeps remote and super-admin revoke directions',
    (tester) async {
      final repository = _LifecycleRepository(
        effective: _effective(superAdmin: true),
      );
      await _pumpPanel(
        tester,
        repository: repository,
        user: _user(status: 'disabled', remoteAccess: true),
      );

      expect(_button(tester, '取消授权').onPressed, isNotNull);
      expect(_button(tester, '取消超管').onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('non-current active/locked account cannot lock or unlock', (
    tester,
  ) async {
    for (final status in const ['active', 'locked']) {
      await _pumpPanel(
        tester,
        repository: _LifecycleRepository(effective: _effective()),
        user: _user(status: status),
      );
      await tester.tap(find.text('账号安全').first);
      await tester.pumpAndSettle();
      final blockedLabel = status == 'active' ? '锁定' : '解锁';
      await tester.ensureVisible(_buttonFinder(blockedLabel));
      expect(_button(tester, blockedLabel).onPressed, isNull);
      expect(_button(tester, blockedLabel).onDisabledTap, isNotNull);
      expect(_button(tester, '停用').onPressed, isNotNull);
      expect(_button(tester, '设置临时密码').onPressed, isNull);
      expect(tester.takeException(), isNull);
    }
  });
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  required _LifecycleRepository repository,
  required AdminUserSummary user,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(375, 900);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adminRepositoryProvider.overrideWithValue(repository),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: AdminUserDetailPanel(
            user: user,
            canManageAuthorization: true,
            onAccountChanged: _noop,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

AdminUserSummary _user({required String status, bool remoteAccess = false}) =>
    AdminUserSummary(
      id: 'user-1',
      employeeId: 'employee-1',
      employeeName: '离职员工',
      employeeStatus: 'resigned',
      loginAccount: '13800000000',
      status: status,
      mustChangePassword: false,
      roles: const [],
      remoteAccess: remoteAccess,
    );

Finder _buttonFinder(String label) => find
    .ancestor(of: find.text(label), matching: find.byType(UtenButton))
    .first;

UtenButton _button(WidgetTester tester, String label) =>
    tester.widget<UtenButton>(_buttonFinder(label));

Switch _permissionSwitch(WidgetTester tester) => tester.widget<Switch>(
  find.descendant(
    of: find.byKey(const ValueKey('permission-$_permissionCode')),
    matching: find.byType(Switch),
  ),
);

void _noop() {}

const _catalog = [
  PermissionCatalogGroup(
    module: '账号管理',
    category: '测试权限',
    permissions: [
      AdminPermission(
        id: _permissionCode,
        code: _permissionCode,
        name: '测试个人授权',
        module: '账号管理',
        category: '测试权限',
      ),
    ],
  ),
];

EffectivePermissions _effective({
  Set<String> grants = const {},
  bool superAdmin = false,
}) => EffectivePermissions(
  departmentPermissions: const [],
  baselinePermissions: const [],
  grants: grants.toList(),
  revokes: const [],
  effective: grants.toList(),
  superAdmin: superAdmin,
);

class _LifecycleRepository implements AdminRepository {
  _LifecycleRepository({required this._effective});

  EffectivePermissions _effective;
  final List<(List<String>, List<String>)> overrideUpdates = [];

  @override
  Future<EffectivePermissions> effectivePermissions(String userId) async =>
      _effective;

  @override
  Future<List<PermissionCatalogGroup>> permissionCatalog() async => _catalog;

  @override
  Future<void> updateUserPermOverrides(
    String userId, {
    required List<String> grants,
    required List<String> revokes,
  }) async {
    overrideUpdates.add(([...grants], [...revokes]));
    _effective = EffectivePermissions(
      departmentPermissions: _effective.departmentPermissions,
      baselinePermissions: _effective.baselinePermissions,
      grants: [...grants],
      revokes: [...revokes],
      effective: [...grants],
      superAdmin: _effective.superAdmin,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
