part of 'admin_permissions_layout_test.dart';

class _GeometryRepository extends _Repository {
  _GeometryRepository() : super(editablePermission: true);
  AdminUserSummary get otherUser => const AdminUserSummary(
    id: 'user-other',
    employeeId: 'employee-other',
    employeeName: '测试员工乙',
    currentEmployee: true,
    employeeStatus: 'active',
    loginAccount: '13900000088',
    status: 'active',
    mustChangePassword: false,
    remoteAccess: false,
  );
  @override
  Future<PagedResult<AdminUserSummary>> listUsers({
    int page = 1,
    int size = 20,
    String? search,
    String? status,
  }) async => PagedResult(
    items: [user, otherUser],
    page: 1,
    size: 20,
    total: 2,
    totalPages: 1,
  );
  @override
  Future<List<DepartmentNode>> departmentTree() async => [
    DepartmentNode(
      id: 'department-target',
      code: 'DEPT',
      name: '制造部',
      level: '一级部门',
      children: [],
    ),
    DepartmentNode(
      id: 'department-other',
      code: 'OTHER',
      name: '制造部乙',
      level: '一级部门',
      children: [],
    ),
  ];
  @override
  Future<List<DataScopeCatalogItem>> dataScopeCatalog() async => const [
    DataScopeCatalogItem(
      scope: 'client',
      label: '客户资料',
      description: '按负责人配置可查看范围',
      viewAllPermission: 'client:view:all',
      enabled: true,
      group: '客户与销售',
    ),
  ];
  @override
  Future<List<String>> getUserDataScopes(String userId, String scope) async =>
      [];
  @override
  Future<List<DataScopeOwner>> dataScopeOwners(String scope) async => [];
}

class _GeometryTemplates extends _TemplateRepository {
  @override
  Future<List<PermissionTemplate>> list() async => [
    template,
    const PermissionTemplate(
      id: 'template-other',
      name: '布局测试模板乙',
      description: '',
      permissions: [],
      version: 1,
    ),
  ];
}

Future<void> _returnToRealDetailTop(WidgetTester tester) async {
  final state = tester.state<ScrollableState>(
    find
        .descendant(
          of: find.byType(ListView).last,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  state.position.jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> _revealRealCatalog(WidgetTester tester) async {
  final search = find.byKey(const ValueKey('permission-catalog-search'));
  for (var attempt = 0; attempt < 12 && search.evaluate().isEmpty; attempt++) {
    await tester.drag(find.byType(ListView).last, const Offset(0, -250));
    await tester.pumpAndSettle();
  }
  expect(search, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(search), alignment: .2);
  await tester.pumpAndSettle();
}

void permissionRealAlignmentCases() {
  for (final width in [984.0, 791.0, 390.0]) {
    for (final mode in ['按员工', '按部门', '全员基础包', '按模板']) {
      testWidgets(
        'real permission editor $mode at $width shares the page edges',
        (tester) async {
          final repository = _GeometryRepository();
          final templates = _TemplateRepository();
          await _mount(
            tester,
            repository,
            _AiRepository(),
            width: width,
            height: width == 984 ? 763 : 1000,
            pageFrame: true,
            initialDepartmentId: mode == '按部门' ? 'department-target' : null,
            templates: templates,
          );
          await _selectMode(tester, mode);
          if (mode == '按模板') {
            await tester.tap(find.text('布局测试模板'));
            await tester.pumpAndSettle();
          }
          if (mode == '按员工') {
            expect(find.byType(AdminUserDetailPanel), findsOneWidget);
            final summary = find.byKey(
              const ValueKey('admin-user-summary-card'),
            );
            final frame = tester.getRect(
              find.byKey(const ValueKey('permission-real-page-frame')),
            );
            expect(tester.getRect(summary).left, closeTo(frame.left, .1));
            expect(
              tester.widget<UtenCard>(summary).padding,
              const EdgeInsets.all(12),
            );
          }
          await _revealRealCatalog(tester);
          final frame = tester.getRect(
            find.byKey(const ValueKey('permission-real-page-frame')),
          );
          final editor = tester.getRect(
            find.byType(AdminPermissionEditorSurface),
          );
          final catalog = tester.getRect(find.byType(PermissionCatalogBrowser));
          final search = tester.getRect(
            find.byKey(const ValueKey('permission-catalog-search')),
          );
          final module = find.byWidgetPredicate(
            (widget) =>
                widget is PermCatalogGroupSection &&
                widget.level == PermCatalogLevel.module &&
                widget.title == '常用模块',
          );
          final moduleRect = tester.getRect(module);
          for (final entry in [
            (editor, 'editor'),
            (catalog, 'catalog'),
            (moduleRect, 'module'),
          ]) {
            expect(
              entry.$1.left,
              closeTo(frame.left, .1),
              reason: '${entry.$2} left',
            );
            expect(
              entry.$1.right,
              closeTo(frame.right, .1),
              reason: '${entry.$2} right',
            );
          }
          expect(search.left, closeTo(frame.left, .1));
          // The arrow and nested category retain actual tree spacing.
          await tester.tap(
            find.descendant(of: module, matching: find.text('常用模块')),
          );
          await tester.pumpAndSettle();
          final category = find.byWidgetPredicate(
            (widget) =>
                widget is PermCatalogGroupSection &&
                widget.level == PermCatalogLevel.category &&
                widget.title == '资料',
          );
          expect(tester.getRect(category).left - frame.left, closeTo(30, .1));
          expect(tester.takeException(), isNull);
          if (mode == '按员工') {
            await _returnToRealDetailTop(tester);
            await tester.tap(find.text('可查看数据'));
            await tester.pumpAndSettle();
            final scope = tester.getRect(
              find.byKey(const ValueKey('admin-data-scope-editor')),
            );
            expect(scope.left, closeTo(frame.left, .1));
            expect(scope.right, closeTo(frame.right, .1));
            expect(find.text('客户资料'), findsOneWidget);
            await _returnToRealDetailTop(tester);
            await tester.tap(find.text('账号安全').first);
            await tester.pumpAndSettle();
            final cards = find.descendant(
              of: find.byType(AdminUserDetailPanel),
              matching: find.byType(UtenCard),
            );
            for (final element in cards.evaluate()) {
              final card = find.byElementPredicate(
                (candidate) => identical(candidate, element),
              );
              expect(tester.getRect(card).left, closeTo(frame.left, .1));
            }
          }
          expect(repository.lockedUsers, isEmpty);
          expect(repository.resetUsers, isEmpty);
          expect(templates.savedCodes, isEmpty);
        },
      );
    }
  }
  testWidgets('real permission desktop keeps the editor card inset', (
    tester,
  ) async {
    await _mount(
      tester,
      _GeometryRepository(),
      _AiRepository(),
      width: 1600,
      pageFrame: true,
      templates: _TemplateRepository(),
    );
    await _revealRealCatalog(tester);
    final editor = tester.getRect(find.byType(AdminPermissionEditorSurface));
    final search = tester.getRect(
      find.byKey(const ValueKey('permission-catalog-search')),
    );
    expect(search.left - editor.left, closeTo(16, .1));
    expect(tester.takeException(), isNull);
  });
  for (final mode in ['按员工', '按部门', '全员基础包', '按模板']) {
    testWidgets(
      'real permission resize preserves search expansion and selected target: $mode',
      (tester) async {
        final templates = _TemplateRepository();
        await _mount(
          tester,
          _GeometryRepository(),
          _AiRepository(),
          width: 984,
          pageFrame: true,
          templates: templates,
          initialDepartmentId: mode == '按部门' ? 'department-target' : null,
        );
        await _selectMode(tester, mode);
        if (mode == '按模板') {
          await tester.tap(find.text('布局测试模板'));
          await tester.pumpAndSettle();
        }
        await _revealRealCatalog(tester);
        await tester.tap(find.text('常用模块'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('资料'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('permission-goods:view')),
          findsOneWidget,
        );
        final catalogState = tester.state(
          find.byType(PermissionCatalogBrowser),
        );
        for (final width in [1600.0, 984.0]) {
          tester.view.physicalSize = Size(width, 1000);
          await tester.pumpAndSettle();
          await _revealRealCatalog(tester);
          expect(
            tester.state(find.byType(PermissionCatalogBrowser)),
            same(catalogState),
          );
          expect(
            find.byKey(const ValueKey('permission-goods:view')),
            findsOneWidget,
          );
        }
        final search = find.descendant(
          of: find.byKey(const ValueKey('permission-catalog-search')),
          matching: find.byType(TextField),
        );
        await tester.enterText(search, '查看测试');
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        for (final width in [1600.0, 984.0]) {
          tester.view.physicalSize = Size(width, 1000);
          await tester.pumpAndSettle();
          await _revealRealCatalog(tester);
          expect(
            tester.state(find.byType(PermissionCatalogBrowser)),
            same(catalogState),
          );
          expect(tester.widget<TextField>(search).controller!.text, '查看测试');
        }
        expect(templates.savedCodes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'real permission popup retains the card inset despite inherited page scopes',
    (tester) async {
      await _mount(
        tester,
        _GeometryRepository(),
        _AiRepository(),
        width: 984,
        pageFrame: true,
        templates: _TemplateRepository(),
      );
      const bodyKey = Key('permission-local-surface-body');
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(AdminPermissionsPage)),
          builder: (_) => const UtenPagePaneScope(
            split: false,
            child: UtenContentInsetsScope(
              child: Dialog(
                child: SizedBox(
                  width: 440,
                  child: AdminPermissionEditorSurface(
                    child: SizedBox(key: bodyKey, height: 100),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final surface = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(AdminPermissionEditorSurface),
      );
      expect(
        tester.getRect(find.byKey(bodyKey)).left - tester.getRect(surface).left,
        closeTo(16, .1),
      );
      expect(
        tester.getRect(surface).right -
            tester.getRect(find.byKey(bodyKey)).right,
        closeTo(16, .1),
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final mode in ['按员工', '按部门', '全员基础包', '按模板']) {
    testWidgets(
      'real permission read generation retires directory state: $mode',
      (tester) async {
        await _mount(
          tester,
          _GeometryRepository(),
          _AiRepository(),
          width: 984,
          pageFrame: true,
          templates: _TemplateRepository(),
          initialDepartmentId: mode == '按部门' ? 'department-target' : null,
        );
        await _selectMode(tester, mode);
        if (mode == '按模板') {
          await tester.tap(find.text('布局测试模板'));
          await tester.pumpAndSettle();
        }
        await _revealRealCatalog(tester);
        final oldState = tester.state(find.byType(PermissionCatalogBrowser));
        final search = find.descendant(
          of: find.byKey(const ValueKey('permission-catalog-search')),
          matching: find.byType(TextField),
        );
        await tester.enterText(search, '查看测试');
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(AdminPermissionsPage)),
        );
        container.read(readScopeRevisionProvider.notifier).state = 1;
        await tester.pumpAndSettle();
        await _revealRealCatalog(tester);
        expect(
          tester.state(find.byType(PermissionCatalogBrowser)),
          isNot(same(oldState)),
        );
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        final intermediate = tester.state(
          find.byType(PermissionCatalogBrowser),
        );
        container.read(readScopeRevisionProvider.notifier).state = 0;
        await tester.pumpAndSettle();
        expect(
          tester.state(find.byType(PermissionCatalogBrowser)),
          isNot(same(intermediate)),
        );
        expect(
          tester.state(find.byType(PermissionCatalogBrowser)),
          isNot(same(oldState)),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final mode in ['按员工', '按部门', '按模板']) {
    testWidgets(
      'real permission selected owner retires directory state: $mode',
      (tester) async {
        await _mount(
          tester,
          _GeometryRepository(),
          _AiRepository(),
          width: 984,
          pageFrame: true,
          templates: _GeometryTemplates(),
          initialDepartmentId: mode == '按部门' ? 'department-target' : null,
        );
        await _selectMode(tester, mode);
        if (mode == '按模板') {
          await tester.tap(find.text('布局测试模板'));
          await tester.pumpAndSettle();
        }
        await _revealRealCatalog(tester);
        final oldState = tester.state(find.byType(PermissionCatalogBrowser));
        final search = find.descendant(
          of: find.byKey(const ValueKey('permission-catalog-search')),
          matching: find.byType(TextField),
        );
        await tester.enterText(search, '查看测试');
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        await _returnToRealDetailTop(tester);
        if (mode == '按部门') {
          await tester.tap(
            find.byKey(const ValueKey('admin-department-back-to-directory')),
          );
        } else {
          await tester.tap(find.text(mode == '按员工' ? '返回列表' : '返回模板列表'));
        }
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(switch (mode) {
            '按员工' => '测试员工乙',
            '按部门' => '制造部乙',
            _ => '布局测试模板乙',
          }).first,
        );
        await tester.pumpAndSettle();
        await _revealRealCatalog(tester);
        expect(
          tester.state(find.byType(PermissionCatalogBrowser)),
          isNot(same(oldState)),
        );
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
