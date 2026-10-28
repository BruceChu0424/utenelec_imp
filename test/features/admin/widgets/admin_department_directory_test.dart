import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_department_perm_view.dart';
import 'package:uten_imp/features/admin/widgets/admin_permission_export_button.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('UTEN_CAPTURE_PERMISSION_DEPARTMENTS');
final _captureKey = GlobalKey();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('directory uses the shared category tree and admin tree source', (
    tester,
  ) async {
    final repository = _Repository();
    await _mount(tester, repository);
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'permission-department-directory-1440',
      );
    }
    final tree = tester.widget<UtenDepartmentTreeView>(
      find.byKey(const ValueKey('admin-permission-department-tree')),
    );
    expect(tree.flatLevelColors, isTrue);
    expect(tree.nodeEnabledPredicate!(repository.decision), isFalse);
    expect(tree.nodeEnabledPredicate!(repository.center), isTrue);
    expect(find.byType(UtenDepartmentPicker), findsNothing);
    expect(repository.departmentReads, isEmpty);
    expect(find.text('先选择一个部门，再为其设置权限'), findsOneWidget);

    await _tapDepartment(tester, '仓库部');
    await tester.pumpAndSettle();
    expect(repository.departmentReads, ['warehouse']);
    expect(find.text('部门权限 · 仓库部'), findsOneWidget);
    final export = tester.widget<AdminPermissionExportButton>(
      find.byType(AdminPermissionExportButton),
    );
    expect(export.sourceId, 'warehouse');
    expect(export.sourceName, '仓库部');
    expect(export.enabled, isTrue);
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'permission-department-detail-1440',
      );
    }

    final search = find.descendant(
      of: find.byKey(const ValueKey('admin-permission-department-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, 'WH');
    await tester.pumpAndSettle();
    expect(_departmentRow('仓库部'), findsOneWidget);
    expect(_departmentRow('采购部'), findsNothing);
    expect(_departmentRow('制造中心'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'switching department preserves changes unless discard is confirmed',
    (tester) async {
      final repository = _Repository();
      await _mount(tester, repository);
      await _tapDepartment(tester, '仓库部');
      await tester.pumpAndSettle();
      await _modifyPermission(tester);
      expect(
        tester
            .widget<AdminPermissionExportButton>(
              find.byType(AdminPermissionExportButton),
            )
            .enabled,
        isFalse,
      );

      await _tapDepartment(tester, '采购部');
      await tester.pumpAndSettle();
      // 三选一离开弹窗：继续编辑留在当前部门，草稿保留。
      expect(find.text('保存未提交的修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('部门权限 · 仓库部'), findsOneWidget);
      expect(repository.departmentReads, ['warehouse']);
      expect(find.text('已修改 1 项'), findsOneWidget);

      await _tapDepartment(tester, '采购部');
      await tester.pumpAndSettle();
      await tester.tap(find.text('不保存离开'));
      await tester.pumpAndSettle();
      expect(find.text('部门权限 · 采购部'), findsOneWidget);
      expect(repository.departmentReads, ['warehouse', 'purchase']);
      expect(find.text('已修改 1 项'), findsNothing);
      expect(repository.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact directory and details preserve the draft on return', (
    tester,
  ) async {
    final repository = _Repository();
    await _mount(tester, repository, width: 375, scale: 1.8);
    await _tapDepartment(tester, '仓库部');
    await tester.pumpAndSettle();
    expect(find.text('部门权限 · 仓库部'), findsOneWidget);
    expect(find.byType(UtenDepartmentTreeView), findsNothing);
    if (_capture) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'permission-department-detail-375',
      );
    }
    await _modifyPermission(tester);
    await tester.tap(
      find.byKey(const ValueKey('admin-department-back-to-directory')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UtenDepartmentTreeView), findsOneWidget);
    await _tapDepartment(tester, '仓库部');
    await tester.pumpAndSettle();
    expect(find.text('已修改 1 项'), findsOneWidget);
    expect(repository.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed directory retries the owning provider', (tester) async {
    final repository = _Repository()..treeFails = true;
    await _mount(tester, repository);
    expect(find.text('部门目录加载失败'), findsOneWidget);
    repository.treeFails = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(_departmentRow('仓库部'), findsNothing);
    await _expandDepartmentAncestors(tester);
    expect(_departmentRow('仓库部'), findsOneWidget);
    expect(repository.treeReads, 2);
    expect(tester.takeException(), isNull);
  });
}

Finder _departmentRow(String name) => find.descendant(
  of: find.byKey(const ValueKey('admin-permission-department-tree')),
  matching: find.text(name),
);

Future<void> _modifyPermission(WidgetTester tester) async {
  final search = find.descendant(
    of: find.byKey(const ValueKey('permission-catalog-search')),
    matching: find.byType(TextField),
  );
  await tester.enterText(search, 'stock:view');
  await tester.pumpAndSettle();
  final toggle = find.descendant(
    of: find.byKey(const ValueKey('permission-stock:view')),
    matching: find.byType(Switch),
  );
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

Future<void> _mount(
  WidgetTester tester,
  _Repository repository, {
  double width = 1440,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final preferences = await SharedPreferences.getInstance();
  if (_capture) await loadAuditScreenshotFonts(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        adminRepositoryProvider.overrideWithValue(repository),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWith(
          (ref) => {Perm.authorizationManage},
        ),
        isSuperAdminProvider.overrideWith((ref) => true),
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(preferences, web: true),
        ),
      ],
      child: RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _capture
              ? auditScreenshotTheme(buildLightTheme())
              : buildLightTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const Scaffold(body: AdminDepartmentPermView()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapDepartment(WidgetTester tester, String label) async {
  if (_departmentRow(label).evaluate().isEmpty) {
    await _expandDepartmentAncestors(tester);
  }
  await tester.tap(_departmentRow(label));
}

Future<void> _expandDepartmentAncestors(WidgetTester tester) async {
  for (final label in ['决策层', '制造中心']) {
    final toggle = find.byTooltip('展开$label');
    if (toggle.evaluate().isNotEmpty) {
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
    }
  }
}

class _Repository implements AdminRepository {
  final departmentReads = <String>[];
  int treeReads = 0;
  int writes = 0;
  bool treeFails = false;
  late final warehouse = DepartmentNode(
    id: 'warehouse',
    code: 'WH',
    name: '仓库部',
    level: '一级部门',
    children: [],
  );
  late final purchase = DepartmentNode(
    id: 'purchase',
    code: 'PUR',
    name: '采购部',
    level: '一级部门',
    children: [],
  );
  late final center = DepartmentNode(
    id: 'center',
    code: 'CENTER',
    name: '制造中心',
    level: '管理中心',
    children: [warehouse, purchase],
  );
  late final decision = DepartmentNode(
    id: 'decision',
    code: 'DECISION',
    name: '决策层',
    level: '决策层',
    children: [center],
  );

  @override
  Future<List<DepartmentNode>> departmentTree() async {
    treeReads++;
    if (treeFails) throw StateError('fixture tree failure');
    return [decision];
  }

  @override
  Future<List<String>> departmentPermissions(String departmentId) async {
    departmentReads.add(departmentId);
    return [];
  }

  @override
  Future<List<PermissionCatalogGroup>> permissionCatalog() async => const [
    PermissionCatalogGroup(
      module: '仓库管理',
      category: '库存',
      permissions: [
        AdminPermission(
          id: 'stock:view',
          code: 'stock:view',
          name: '查看库存',
          module: '仓库管理',
          category: '库存',
        ),
      ],
    ),
  ];

  @override
  Future<PermissionChange> updateDepartmentPermissions(
    String departmentId,
    List<String> codes,
  ) async {
    writes++;
    return PermissionChange.none;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
