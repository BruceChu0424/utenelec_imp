import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/pages/admin_permissions_page.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/widgets/page_permission_drawer.dart';
import 'package:uten_imp/features/admin/widgets/admin_permission_transfer_actions.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_models.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_repository.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/permission_action_type.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../support/audit_screenshot_support.dart';

final _role = StateProvider<bool>((ref) => true);
final _captureKey = GlobalKey();
const _captureScreenshots = bool.fromEnvironment(
  'UTEN_CAPTURE_PERMISSION_LAYOUT',
);

void main() {
  if (_captureScreenshots) {
    testWidgets('capture permission workspace modes', (tester) async {
      await loadAuditScreenshotFonts(tester);
      await _mount(
        tester,
        _Repository(editablePermission: true, aiPermission: true),
        _AiRepository(),
        width: 1440,
        initialDepartmentId: 'department-target',
      );
      await _selectMode(tester, '按员工');
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'permission-workspace-employee',
      );
      await _selectMode(tester, '按部门');
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'permission-workspace-department',
      );
      await _selectMode(tester, '全员基础包');
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'permission-workspace-baseline',
      );
      tester.view.physicalSize = const Size(375, 1000);
      await tester.pumpAndSettle();
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'permission-workspace-baseline-compact',
      );
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [375.0, 1440.0]) {
    testWidgets(
      'account header and left filters fit at $width with large text',
      (tester) async {
        final repository = _Repository();
        final ai = _AiRepository();
        await _mount(tester, repository, ai, width: width, scale: 1.6);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('以后端实时授权为准'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(UtenAppBar),
            matching: find.text('AI 使用权限'),
          ),
          findsNothing,
        );
        final lock = find.byKey(const ValueKey('admin-header-account-status'));
        expect(lock, findsOneWidget);
        expect(tester.widget<UtenButton>(lock).onPressed, isNotNull);
        expect(
          find.descendant(of: lock, matching: find.text('锁定账号')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('admin-header-provision-account')),
          findsOneWidget,
        );
        if (width > 1000) {
          final filter = tester.getRect(
            find.byKey(const ValueKey('admin-account-status-filter')),
          );
          final search = tester.getRect(
            find.widgetWithText(TextField, '搜索姓名 / 工号 / 登录账号'),
          );
          expect((filter.left - search.left).abs(), lessThan(2));
          expect(search.top, lessThan(filter.top));
          expect(
            search.top,
            greaterThan(
              tester
                  .getRect(
                    find.byKey(const ValueKey('admin-permission-modules')),
                  )
                  .top,
            ),
          );
          expect(
            tester.getRect(lock).right,
            greaterThan(tester.getRect(find.text('测试员工').first).right),
          );
        }

        await tester.tap(lock);
        await tester.pumpAndSettle();
        await tester.tap(find.text('锁定账号').last);
        await tester.pumpAndSettle();
        expect(repository.lockedUsers, ['user-target']);
        expect(find.text('解锁账号'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'department and baseline drafts also block imports across modes',
    (tester) async {
      await _mount(
        tester,
        _Repository(editablePermission: true),
        _AiRepository(),
        width: 1440,
        initialDepartmentId: 'department-target',
      );
      await tester.tap(find.text('常用模块'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('资料'));
      await tester.pumpAndSettle();
      final permission = find.byKey(const ValueKey('permission-goods:view'));
      tester
          .widget<Switch>(
            find.descendant(of: permission, matching: find.byType(Switch)),
          )
          .onChanged!(true);
      await tester.pumpAndSettle();
      expect(_archiveActions(tester).importEnabled, isFalse);
      await _selectMode(tester, '全员基础包');
      await tester.tap(find.text('常用模块'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('资料'));
      await tester.pumpAndSettle();
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('baseline-switch-goods:view')),
          )
          .onChanged!(true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(_archiveActions(tester).importEnabled, isFalse);
      await _selectMode(tester, '按部门');
      expect(find.text('已修改 1 项'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(_archiveActions(tester).importEnabled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'authorization modes keep navigation and detail columns aligned',
    (tester) async {
      await _mount(tester, _Repository(), _AiRepository(), width: 1440);
      final navigation = find.byKey(const ValueKey('admin-permission-modules'));
      final originalNavigation = tester.getRect(navigation);
      final originalDetail = tester.getRect(
        find.byKey(const ValueKey('admin-user-summary-card')),
      );
      expect(find.byType(UtenSplitView), findsOneWidget);
      await tester.tap(find.text('按部门'));
      await tester.pumpAndSettle();
      expect(tester.getRect(navigation), originalNavigation);
      expect(find.byType(UtenSplitView), findsOneWidget);
      await tester.tap(find.text('全员基础包'));
      await tester.pumpAndSettle();
      expect(tester.getRect(navigation), originalNavigation);
      final baselineDetail = tester.getRect(
        find.byKey(const ValueKey('admin-baseline-permission-card')),
      );
      expect(baselineDetail.left, originalDetail.left);
      expect(baselineDetail.width, originalDetail.width);
      expect(find.byType(UtenSplitView), findsOneWidget);
      expect(find.text('全体在职员工'), findsOneWidget);
      expect(find.text('全部授权'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bulk operations and shared pane width retain drafts across modes',
    (tester) async {
      await _mount(
        tester,
        _Repository(editablePermission: true),
        _AiRepository(),
        width: 1440,
        initialDepartmentId: 'department-target',
      );
      await _selectMode(tester, '按员工');
      final detail = find.byKey(const ValueKey('admin-user-permission-card'));
      final summary = find.byKey(const ValueKey('admin-user-summary-card'));
      for (final label in ['全部授权', '全部收回']) {
        expect(
          find.descendant(of: detail, matching: find.text(label)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: summary, matching: find.text(label)),
          findsNothing,
        );
      }
      await tester.tap(find.text('常用模块'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('资料'));
      await tester.pumpAndSettle();
      final permission = find.byKey(const ValueKey('permission-goods:view'));
      tester
          .widget<Switch>(
            find.descendant(of: permission, matching: find.byType(Switch)),
          )
          .onChanged!(true);
      await tester.pumpAndSettle();
      expect(find.text('已修改 1 项'), findsOneWidget);
      expect(_archiveActions(tester).importEnabled, isFalse);
      final originalLeft = tester.getRect(summary).left;
      await tester.drag(find.byTooltip('拖动调整宽度 · 双击复位'), const Offset(90, 0));
      await tester.pumpAndSettle();
      final draggedLeft = tester.getRect(summary).left;
      expect(draggedLeft, greaterThan(originalLeft));
      expect(find.text('已修改 1 项'), findsOneWidget);
      await _selectMode(tester, '按部门');
      expect(
        tester
            .getRect(
              find.byKey(const ValueKey('admin-department-permission-card')),
            )
            .left,
        draggedLeft,
      );
      await tester.tap(find.text('全员基础包'));
      await tester.pumpAndSettle();
      expect(
        tester
            .getRect(
              find.byKey(const ValueKey('admin-baseline-permission-card')),
            )
            .left,
        draggedLeft,
      );
      expect(_archiveActions(tester).importEnabled, isFalse);
      await tester.tap(find.text('按员工'));
      await tester.pumpAndSettle();
      expect(tester.getRect(summary).left, draggedLeft);
      expect(find.text('已修改 1 项'), findsOneWidget);
      tester.view.physicalSize = const Size(375, 1000);
      await tester.pumpAndSettle();
      expect(find.text('已修改 1 项'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(_archiveActions(tester).importEnabled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [375.0, 1440.0]) {
    testWidgets('all authorization modes fit large text at $width', (
      tester,
    ) async {
      await _mount(
        tester,
        _Repository(),
        _AiRepository(),
        width: width,
        scale: 1.6,
      );
      final navigation = find.byKey(const ValueKey('admin-permission-modules'));
      final position = tester.getTopLeft(navigation);
      for (final mode in ['按部门', '全员基础包', '按员工']) {
        await _selectMode(tester, mode);
        expect(tester.getTopLeft(navigation), position);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('AI use is an editable category inside permission details', (
    tester,
  ) async {
    final ai = _AiRepository();
    await _mount(tester, _Repository(aiPermission: true), ai, width: 1440);
    final modules = find.byKey(const ValueKey('admin-permission-modules'));
    expect(
      find.descendant(of: modules, matching: find.text('AI 使用权限')),
      findsNothing,
    );
    expect(find.byType(PagePermissionDrawer), findsNothing);
    expect(ai.scopes, isEmpty);
    expect(find.text('系统管理'), findsNothing);
    await tester.tap(find.text('通用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 助手'));
    await tester.pumpAndSettle();
    expect(find.text('使用 AI 助手（对话与文件识别）'), findsOneWidget);
    final permission = find.byKey(const ValueKey('permission-ai:use'));
    final toggle = tester.widget<Switch>(
      find.descendant(of: permission, matching: find.byType(Switch)),
    );
    expect(toggle.onChanged, isNotNull);
    toggle.onChanged!(true);
    await tester.pumpAndSettle();
    expect(find.text('已修改 1 项'), findsOneWidget);
    expect(ai.scopes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'server protected target hides locking and never sends a request',
    (tester) async {
      final repository = _Repository(protected: true);
      await _mount(tester, repository, _AiRepository(), width: 1440);
      expect(
        find.byKey(const ValueKey('admin-header-account-status')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('admin-header-provision-account')),
        findsOneWidget,
      );
      expect(repository.lockedUsers, isEmpty);
    },
  );

  testWidgets(
    'permission revocation while confirming prevents the old lock command',
    (tester) async {
      final repository = _Repository();
      await _mount(tester, repository, _AiRepository(), width: 1440);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(AdminPermissionsPage)),
      );
      await tester.tap(
        find.byKey(const ValueKey('admin-header-account-status')),
      );
      await tester.pumpAndSettle();
      container.read(_role.notifier).state = false;
      await tester.pumpAndSettle();
      await tester.tap(find.text('锁定账号').last);
      await tester.pumpAndSettle();
      expect(repository.lockedUsers, isEmpty);
      expect(
        find.byKey(const ValueKey('admin-header-account-status')),
        findsNothing,
      );
      expect(find.text('AI 使用权限'), findsNothing);
    },
  );

  testWidgets(
    'account action explicitly confirms discarding a permission draft',
    (tester) async {
      final repository = _Repository(editablePermission: true);
      await _mount(tester, repository, _AiRepository(), width: 1440);
      final search = find.descendant(
        of: find.byKey(const ValueKey('permission-catalog-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, '查看测试资料');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      tester.widget<Switch>(find.byType(Switch)).onChanged!(true);
      await tester.pumpAndSettle();
      expect(find.text('已修改 1 项'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('admin-header-account-status')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('会丢弃 1 项尚未保存'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(repository.lockedUsers, isEmpty);
      expect(find.text('已修改 1 项'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('admin-header-account-status')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('锁定账号').last);
      await tester.pumpAndSettle();
      expect(repository.lockedUsers, ['user-target']);
      expect(find.text('已修改 1 项'), findsNothing);
    },
  );

  testWidgets(
    'page two account keeps its credential dialog through list refresh',
    (tester) async {
      final repository = _Repository(paged: true);
      await _mount(
        tester,
        repository,
        _AiRepository(),
        width: 1440,
        initialEmployeeId: null,
      );
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('第二页员工').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('账号安全'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置临时密码'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('set-temporary-password-confirm')));
      await tester.pumpAndSettle();
      expect(repository.resetUsers, ['user-target']);
      expect(repository.refreshedTargets, 0);
      expect(find.text('Temp-Demo!12345'), findsOneWidget);
      expect(find.text('一次性临时密码'), findsWidgets);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Temp-Demo!12345'), findsOneWidget);
      await tester.tap(find.text('我已妥善保存'));
      await tester.pumpAndSettle();
      expect(repository.refreshedTargets, greaterThanOrEqualTo(1));
      expect(find.text('Temp-Demo!12345'), findsNothing);
      expect(find.text('第二页员工'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}

AdminPermissionArchiveActions _archiveActions(WidgetTester tester) => tester
    .widget<UtenAppBar>(find.byType(UtenAppBar))
    .actions!
    .whereType<AdminPermissionArchiveActions>()
    .single;

Future<void> _selectMode(WidgetTester tester, String label) async {
  final navigation = find.byKey(const ValueKey('admin-permission-modules'));
  final choice = find.descendant(of: navigation, matching: find.text(label));
  if (choice.evaluate().isEmpty) {
    await tester.tap(
      find.descendant(of: navigation, matching: find.byType(OutlinedButton)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
  } else {
    await tester.tap(choice);
  }
  await tester.pumpAndSettle();
}

Future<void> _mount(
  WidgetTester tester,
  _Repository repository,
  _AiRepository ai, {
  required double width,
  double scale = 1,
  String? initialEmployeeId = 'employee-target',
  String? initialDepartmentId,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_role)
              ? {Perm.accountSupport, Perm.authorizationManage}
              : {},
        ),
        isSuperAdminProvider.overrideWith((ref) => ref.watch(_role)),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        adminRepositoryProvider.overrideWithValue(repository),
        pagePermissionDelegationRepositoryProvider.overrideWithValue(ai),
      ],
      child: RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _captureScreenshots
              ? auditScreenshotTheme(buildLightTheme())
              : null,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: AdminPermissionsPage(
            initialEmployeeId: initialEmployeeId,
            initialDepartmentId: initialDepartmentId,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async =>
      SessionSnapshot(delegableSurfaceKeys: {aiUsePermissionScope.surfaceKey});
}

class _AiRepository implements PagePermissionDelegationRepository {
  final scopes = <String>[];
  @override
  Future<List<ManagedPermissionDepartment>> managedDepartments(
    String surfaceKey,
  ) async {
    scopes.add(surfaceKey);
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repository implements AdminRepository {
  _Repository({
    this.protected = false,
    this.paged = false,
    this.editablePermission = false,
    this.aiPermission = false,
  });
  final bool protected;
  final bool paged;
  final bool editablePermission;
  final bool aiPermission;
  final lockedUsers = <String>[];
  final resetUsers = <String>[];
  int refreshedTargets = 0;
  String status = 'active';
  AdminUserSummary get user => AdminUserSummary(
    id: 'user-target',
    employeeId: 'employee-target',
    employeeName: paged ? '第二页员工' : '测试员工',
    employeeCode: 'UT0099',
    employeeStatus: 'active',
    currentEmployee: true,
    loginAccount: '13900000099',
    status: status,
    mustChangePassword: false,
    remoteAccess: false,
    departmentName: '制造部',
    positionName: '工程师',
    accountSupportAllowed: !protected,
  );
  @override
  Future<PagedResult<AdminUserSummary>> listUsers({
    int page = 1,
    int size = 20,
    String? search,
    String? status,
  }) async {
    if (paged && search == user.loginAccount) refreshedTargets++;
    const first = AdminUserSummary(
      id: 'user-first',
      loginAccount: '13900000001',
      employeeName: '第一页员工',
      employeeCode: 'UT0001',
      employeeStatus: 'active',
      currentEmployee: true,
      status: 'active',
      mustChangePassword: false,
      remoteAccess: false,
      accountSupportAllowed: true,
    );
    final items = paged && page == 1 && search == null ? [first] : [user];
    return PagedResult(
      items: items,
      page: page,
      size: size,
      total: paged && search == null ? 2 : 1,
      totalPages: paged && search == null ? 2 : 1,
    );
  }

  @override
  Future<AdminUserSummary> userByEmployeeId(String employeeId) async => user;
  @override
  Future<List<DepartmentNode>> departmentTree() async => [
    DepartmentNode(
      id: 'department-target',
      code: 'DEPT_PROD',
      name: '制造部',
      level: '一级部门',
      children: [],
    ),
  ];
  @override
  Future<List<String>> departmentPermissions(String departmentId) async => [];
  @override
  Future<List<PermissionCatalogGroup>> permissionCatalog() async => [
    if (editablePermission)
      const PermissionCatalogGroup(
        category: '资料',
        module: '常用模块',
        permissions: [
          AdminPermission(
            id: 'permission-view',
            code: 'goods:view',
            actionType: PermissionActionType.view,
            name: '查看测试资料',
            category: '资料',
            module: '常用模块',
          ),
        ],
      ),
    if (aiPermission)
      const PermissionCatalogGroup(
        category: 'AI 助手',
        module: '通用',
        permissions: [
          AdminPermission(
            id: 'permission-ai',
            code: Perm.aiUse,
            actionType: PermissionActionType.execute,
            name: '使用 AI 助手（对话与文件识别）',
            category: 'AI 助手',
            module: '通用',
          ),
        ],
      ),
  ];
  @override
  Future<List<String>> permissionBaseline() async => [];
  @override
  Future<EffectivePermissions> effectivePermissions(String userId) async =>
      const EffectivePermissions(
        departmentPermissions: [],
        baselinePermissions: [],
        grants: [],
        revokes: [],
        effective: [],
      );
  @override
  Future<void> lockUser(String userId) async {
    lockedUsers.add(userId);
    status = 'locked';
  }

  @override
  Future<String> resetPassword(String userId) async {
    resetUsers.add(userId);
    return 'Temp-Demo!12345';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
