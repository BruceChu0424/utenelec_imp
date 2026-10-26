import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/components/layout/uten_scroll_prefetch_policy.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/models/permission_template.dart';
import 'package:uten_imp/features/admin/pages/admin_permissions_page.dart';
import 'package:uten_imp/features/admin/repositories/admin_repository.dart';
import 'package:uten_imp/features/admin/repositories/permission_template_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_permission_export_button.dart';
import 'package:uten_imp/features/admin/widgets/admin_permission_templates.dart';
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
  testWidgets(
    'account list prefetches before the end once and preserves the viewport',
    (tester) async {
      final pending = Completer<PagedResult<AdminUserSummary>>();
      final repository = _PrefetchRepository(pageTwo: pending);
      await _mount(
        tester,
        repository,
        _AiRepository(),
        width: 1440,
        initialEmployeeId: null,
      );
      final list = find.byKey(const ValueKey('admin-account-list-scroll'));
      final original = tester.element(list);
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(repository.pages, [1]);
      expect(
        position.extentAfter,
        greaterThan(UtenScrollPrefetchPolicy.distanceOf(position)),
      );
      position.jumpTo(
        position.maxScrollExtent -
            UtenScrollPrefetchPolicy.distanceOf(position) / 2,
      );
      expect(position.extentAfter, greaterThan(0));
      await tester.pump();
      await tester.pump();
      expect(repository.pages, [1, 2]);
      position.jumpTo(position.pixels + 1);
      await tester.pump();
      expect(repository.pages, [
        1,
        2,
      ], reason: 'Only one read may be pending for the next page');
      final offset = position.pixels;
      pending.complete(repository.page(2));
      await tester.pumpAndSettle();
      expect(repository.pages, [1, 2]);
      expect(tester.element(list), same(original));
      expect(
        tester.state<ScrollableState>(scrollable).position,
        same(position),
      );
      expect(position.pixels, closeTo(offset, .01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account prefetch failure waits for manual retry without replacing loaded rows',
    (tester) async {
      final repository = _PrefetchRepository(failPageTwoOnce: true);
      await _mount(
        tester,
        repository,
        _AiRepository(),
        width: 1440,
        initialEmployeeId: null,
      );
      final list = find.byKey(const ValueKey('admin-account-list-scroll'));
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(
        position.maxScrollExtent -
            UtenScrollPrefetchPolicy.distanceOf(position) / 2,
      );
      await tester.pumpAndSettle();
      expect(repository.pages, [1, 2]);
      position.jumpTo(position.pixels + 1);
      await tester.pumpAndSettle();
      expect(repository.pages, [1, 2]);
      await tester.scrollUntilVisible(
        find.text('加载更多'),
        160,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(repository.pages, [1, 2]);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(repository.pages, [1, 2, 2]);
      expect(find.text('加载更多'), findsNothing);
      expect(
        tester.state<ScrollableState>(scrollable).position,
        same(position),
      );
      expect(tester.takeException(), isNull);
    },
  );

  if (_captureScreenshots) {
    testWidgets('capture permission workspace modes', (tester) async {
      await loadAuditScreenshotFonts(tester);
      await _mount(
        tester,
        _Repository(editablePermission: true, aiPermission: true),
        _AiRepository(),
        width: 1440,
        initialDepartmentId: 'department-target',
        templates: _TemplateRepository(),
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
      await _selectMode(tester, '按模板');
      await tester.tap(
        find.byKey(const ValueKey('permission-template-layout-template')),
      );
      await tester.pumpAndSettle();
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'permission-workspace-template',
      );
      await _selectMode(tester, '全员基础包');
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

  testWidgets('super administrator export explains the non-restorable scope', (
    tester,
  ) async {
    await _mount(
      tester,
      _Repository(superAdmin: true),
      _AiRepository(),
      width: 1440,
    );
    final export = tester.widget<AdminPermissionExportButton>(
      find.byType(AdminPermissionExportButton),
    );
    expect(export.scope, PermissionExportScope.employee);
    expect(export.enabled, isFalse);
    expect(export.disabledReason, contains('超级管理员'));
    expect(export.disabledReason, contains('可恢复权限文件'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'template first visit is lazy and autosave survives switching modes',
    (tester) async {
      final templates = _TemplateRepository();
      final saveGate = Completer<void>();
      templates.saveGate = saveGate;
      await _mount(
        tester,
        _Repository(editablePermission: true),
        _AiRepository(),
        width: 1440,
        templates: templates,
      );
      expect(templates.listReads, 0);
      expect(
        find.byType(AdminPermissionTemplatesView, skipOffstage: false),
        findsNothing,
      );
      await _selectMode(tester, '按模板');
      expect(templates.listReads, 1);
      await tester.tap(
        find.byKey(const ValueKey('permission-template-layout-template')),
      );
      await tester.pumpAndSettle();
      final workspace = tester.state(find.byType(AdminPermissionTemplatesView));
      await tester.tap(
        find.byKey(const ValueKey('permission-toggle-all-groups')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('template-code-goods:view')));
      await tester.pump();
      await tester.pump();
      _expectGlobalImportEnabled(tester, false);
      expect(templates.savedCodes, isEmpty);

      await _selectMode(tester, '全员基础包', settle: false);
      expect(
        tester.state(
          find.byType(AdminPermissionTemplatesView, skipOffstage: false),
        ),
        same(workspace),
      );
      _expectGlobalImportEnabled(tester, false);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(templates.savedCodes, [
        <String>{'goods:view'},
      ]);
      expect(templates.savedVersions, [4]);
      await _selectMode(tester, '按员工', settle: false);
      _expectGlobalImportEnabled(tester, false);
      saveGate.complete();
      await tester.pump();
      await tester.pumpAndSettle();
      _expectGlobalImportEnabled(tester, true);

      await _selectMode(tester, '按模板');
      expect(
        tester.state(find.byType(AdminPermissionTemplatesView)),
        same(workspace),
      );
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('template-code-goods:view')),
            )
            .value,
        isTrue,
      );
      expect(templates.savedCodes, hasLength(1));
      expect(find.textContaining('已自动保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'each mode exports its saved subject while the header exports all',
    (tester) async {
      final templates = _TemplateRepository();
      await _mount(
        tester,
        _Repository(editablePermission: true),
        _AiRepository(),
        width: 1440,
        initialDepartmentId: 'department-target',
        templates: templates,
      );
      expect(find.text('导出全部权限'), findsOneWidget);
      await _selectMode(tester, '按员工');
      var export = tester.widget<AdminPermissionExportButton>(
        find.byType(AdminPermissionExportButton),
      );
      expect(export.scope, PermissionExportScope.employee);
      expect(export.sourceId, 'user-target');
      expect(export.sourceName, '测试员工');
      expect(export.enabled, isTrue);

      await _selectMode(tester, '按部门');
      export = tester.widget<AdminPermissionExportButton>(
        find.byType(AdminPermissionExportButton),
      );
      expect(export.scope, PermissionExportScope.department);
      expect(export.sourceId, 'department-target');
      expect(export.sourceName, '制造部');
      expect(export.enabled, isTrue);
      expect(
        find.byKey(const ValueKey('admin-permission-department-tree')),
        findsOneWidget,
      );

      await _selectMode(tester, '全员基础包');
      export = tester.widget<AdminPermissionExportButton>(
        find.byType(AdminPermissionExportButton),
      );
      expect(export.scope, PermissionExportScope.baseline);
      expect(export.sourceId, isNull);
      expect(export.enabled, isTrue);

      await _selectMode(tester, '按模板');
      await tester.tap(
        find.byKey(const ValueKey('permission-template-layout-template')),
      );
      await tester.pumpAndSettle();
      export = tester.widget<AdminPermissionExportButton>(
        find.byType(AdminPermissionExportButton),
      );
      expect(export.scope, PermissionExportScope.template);
      expect(export.template, templates.template);
      expect(export.enabled, isTrue);
      expect(find.text('导出全部权限'), findsOneWidget);
      _expectGlobalImportEnabled(tester, true);
      expect(tester.takeException(), isNull);
    },
  );

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
        templates: _TemplateRepository(),
      );
      final navigation = find.byKey(const ValueKey('admin-permission-modules'));
      final position = tester.getTopLeft(navigation);
      for (final mode in ['按部门', '全员基础包', '按模板', '按员工']) {
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

void _expectGlobalImportEnabled(WidgetTester tester, bool enabled) {
  expect(_archiveActions(tester).importEnabled, enabled);
  expect(
    tester
        .widget<UtenButton>(
          find.byKey(const ValueKey('import-permission-configuration')),
        )
        .onPressed,
    enabled ? isNotNull : isNull,
  );
}

Future<void> _selectMode(
  WidgetTester tester,
  String label, {
  bool settle = true,
}) async {
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
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump();
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Repository repository,
  _AiRepository ai, {
  required double width,
  double scale = 1,
  String? initialEmployeeId = 'employee-target',
  String? initialDepartmentId,
  _TemplateRepository? templates,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final api = ApiClient(Dio(BaseOptions(baseUrl: 'https://example.test/api')));
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
        if (templates != null) ...[
          apiClientProvider.overrideWithValue(api),
          permissionTemplateRepositoryProvider.overrideWithValue(templates),
        ],
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
    this.superAdmin = false,
  });
  final bool protected;
  final bool paged;
  final bool editablePermission;
  final bool aiPermission;
  final bool superAdmin;
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
      EffectivePermissions(
        superAdmin: superAdmin,
        departmentPermissions: const [],
        baselinePermissions: const [],
        grants: const [],
        revokes: const [],
        effective: const [],
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

class _PrefetchRepository extends _Repository {
  _PrefetchRepository({this.pageTwo, this.failPageTwoOnce = false});
  final Completer<PagedResult<AdminUserSummary>>? pageTwo;
  final bool failPageTwoOnce;
  bool _failed = false;
  final pages = <int>[];

  PagedResult<AdminUserSummary> page(int number) => PagedResult(
    page: number,
    size: 30,
    total: 60,
    totalPages: 2,
    items: [
      for (var row = 0; row < 30; row++)
        AdminUserSummary(
          id: 'prefetch-account-$number-$row',
          loginAccount: 'UT-$number-$row',
          employeeName: '预加载员工 $number-$row',
          employeeCode: 'P$number-$row',
          employeeStatus: 'active',
          currentEmployee: true,
          status: 'active',
          mustChangePassword: false,
          remoteAccess: false,
          accountSupportAllowed: true,
        ),
    ],
  );

  @override
  Future<PagedResult<AdminUserSummary>> listUsers({
    int page = 1,
    int size = 20,
    String? search,
    String? status,
  }) async {
    pages.add(page);
    if (page == 2 && failPageTwoOnce && !_failed) {
      _failed = true;
      throw StateError('Mock pagination failure');
    }
    if (page == 2 && pageTwo != null) return pageTwo!.future;
    return this.page(page);
  }
}

class _TemplateRepository extends PermissionTemplateRepository {
  _TemplateRepository() : super(ApiClient(Dio()));

  var template = const PermissionTemplate(
    id: 'layout-template',
    name: '布局测试模板',
    description: '用于岗位操作权限',
    permissions: [],
    version: 4,
  );
  int listReads = 0;
  final savedCodes = <Set<String>>[];
  final savedVersions = <int>[];
  Completer<void>? saveGate;

  @override
  Future<List<PermissionTemplate>> list() async {
    listReads++;
    return [template];
  }

  @override
  Future<PermissionTemplate> save({
    PermissionTemplate? template,
    required String name,
    required String description,
    required Set<String> permissions,
  }) async {
    savedCodes.add({...permissions});
    savedVersions.add(template?.version ?? 0);
    await saveGate?.future;
    this.template = PermissionTemplate(
      id: template?.id ?? 'layout-template',
      name: name,
      description: description,
      permissions: permissions.toList(),
      version: (template?.version ?? 0) + 1,
    );
    return this.template;
  }
}
