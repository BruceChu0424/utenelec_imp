import 'package:uten_imp/components/buttons/uten_close_button.dart';
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
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
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
import 'package:uten_imp/features/admin/widgets/permission_batch_dialog.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_models.dart';
import 'package:uten_imp/shared/auth/permission_grant_policy.dart';
import 'package:uten_imp/shared/auth/page_permission_delegation_repository.dart';
import 'package:uten_imp/shared/auth/page_permission_scope.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/permission_action_type.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/components/cards/uten_card.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:uten_imp/components/layout/uten_scroll_gutter.dart';
import 'package:uten_imp/features/admin/widgets/admin_permission_editor_surface.dart';
import 'package:uten_imp/features/admin/widgets/admin_user_detail_panel.dart';
import 'package:uten_imp/features/admin/widgets/permission_catalog_browser.dart';
import 'package:uten_imp/features/admin/widgets/perm_catalog_group_section.dart';

part 'admin_permissions_real_alignment_cases.dart';

final _role = StateProvider<bool>((ref) => true);
final _captureKey = GlobalKey();
const _captureScreenshots = bool.fromEnvironment(
  'UTEN_CAPTURE_PERMISSION_LAYOUT',
);

void main() {
  permissionRealAlignmentCases();
  testWidgets(
    'saving baseline refreshes an already loaded department dependency warning',
    (tester) async {
      final repository = _BaselineDependencyRepository();
      await _mount(
        tester,
        repository,
        _AiRepository(),
        width: 1440,
        initialEmployeeId: null,
        initialDepartmentId: 'department-target',
      );
      expect(find.text('部门权限 · 制造部'), findsOneWidget);
      expect(find.text('有 1 项动作缺少所需查看权限'), findsOneWidget);
      expect(find.text('补齐所需查看权限'), findsOneWidget);
      final originalReads = repository.departmentReads;
      expect(originalReads, greaterThan(0));

      await _selectMode(tester, '全员基础包');
      final baseline = find.byKey(
        const ValueKey('admin-baseline-permission-card'),
      );
      await tester.tap(
        find.descendant(
          of: baseline,
          matching: find.byKey(const ValueKey('permission-toggle-all-groups')),
        ),
      );
      await tester.pumpAndSettle();
      final read = find.byKey(const ValueKey('baseline-switch-goods:view'));
      await tester.ensureVisible(read);
      await tester.tap(read);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();
      expect(repository.baselineWrites, [
        ['goods:view'],
      ]);

      await _selectMode(tester, '按部门');
      expect(
        repository.departmentReads,
        greaterThan(originalReads),
        reason:
            'Inherited permissions and diagnostics must be read again after a baseline change',
      );
      expect(find.text('部门权限 · 制造部'), findsOneWidget);
      expect(find.text('有 1 项动作缺少所需查看权限'), findsNothing);
      expect(find.text('补齐所需查看权限'), findsNothing);
      expect(
        repository.departmentWrites,
        0,
        reason:
            'The inherited baseline resolves the warning without duplicating a department grant',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'employee multiselect retains targets across loading and search',
    (tester) async {
      if (_captureScreenshots) await loadAuditScreenshotFonts(tester);
      final repository = _SelectionPagingRepository();
      await _mount(
        tester,
        repository,
        _AiRepository(),
        width: 1440,
        initialEmployeeId: null,
        templates: _TemplateRepository(),
      );
      await _selectMode(tester, '按员工');
      await tester.tap(
        find.byKey(const ValueKey('permission-employee-multi-select')),
      );
      await tester.pumpAndSettle();
      final first = find.byKey(
        const ValueKey('permission-select-user-prefetch-account-1-0'),
      );
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 人'), findsOneWidget);
      final list = find.byKey(const ValueKey('admin-account-list-scroll'));
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(repository.pages, contains(2));
      final second = find.byKey(
        const ValueKey('permission-select-user-prefetch-account-2-0'),
      );
      await tester.scrollUntilVisible(second, 250, scrollable: scrollable);
      await tester.pumpAndSettle();
      await tester.tap(second);
      await tester.pumpAndSettle();
      expect(find.text('已选 2 人'), findsOneWidget);
      final search = find.widgetWithText(TextField, '搜索姓名 / 工号 / 登录账号');
      await tester.enterText(search, '仅第一页');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(repository.searches, contains('仅第一页'));
      expect(find.text('已选 2 人'), findsOneWidget);
      expect(tester.widget<Checkbox>(first).value, isTrue);
      expect(second, findsNothing);
      final selectAll = find.byKey(
        const ValueKey('permission-employee-select-all'),
      );
      expect(
        find.descendant(of: selectAll, matching: find.text('取消全选')),
        findsOneWidget,
      );
      await tester.tap(selectAll);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 人'), findsOneWidget);
      expect(tester.widget<Checkbox>(first).value, isFalse);
      expect(
        find.descendant(of: selectAll, matching: find.text('全选')),
        findsOneWidget,
      );
      await tester.tap(selectAll);
      await tester.pumpAndSettle();
      expect(find.text('已选 2 人'), findsOneWidget);
      if (_captureScreenshots) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'permission-workspace-employee-multiselect',
        );
      }
      await tester.tap(find.text('应用模板'));
      await tester.pumpAndSettle();
      final dialog = tester.widget<PermissionBatchDialog>(
        find.byType(PermissionBatchDialog),
      );
      expect(
        dialog.userIds,
        unorderedEquals(['prefetch-account-1-0', 'prefetch-account-2-0']),
      );
      expect(dialog.departmentIds, isEmpty);
      await tester.tap(find.byType(UtenCloseButton).last);
      await tester.pumpAndSettle();
      expect(find.text('已选 2 人'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('permission-employee-multi-select')),
      );
      await tester.pumpAndSettle();
      expect(selectAll, findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('permission-employee-multi-select')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 0 人'), findsOneWidget);
      expect(tester.widget<Checkbox>(first).value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('department multiselect keeps hidden targets and starts folded', (
    tester,
  ) async {
    if (_captureScreenshots) await loadAuditScreenshotFonts(tester);
    await _mount(
      tester,
      _SelectionDepartmentRepository(),
      _AiRepository(),
      width: 1440,
      initialEmployeeId: null,
      templates: _TemplateRepository(),
    );
    await _selectMode(tester, '按部门');
    expect(
      find.byKey(const ValueKey('hierarchy-row:department-child')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('permission-department-multi-select')),
    );
    await tester.pumpAndSettle();
    Future<void> select(String id) async {
      final row = find.byKey(ValueKey('hierarchy-row:$id'));
      await tester.tap(
        find.descendant(of: row, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
    }

    await select('department-a');
    final search = find.descendant(
      of: find.byKey(const ValueKey('admin-permission-department-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, '班组甲');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await select('department-child');
    await tester.enterText(search, '部门乙');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await select('department-b');
    expect(find.text('已选 3 部门'), findsOneWidget);
    expect(find.text('已选 3 个部门'), findsOneWidget);
    if (_captureScreenshots) {
      await saveAuditScreenshot(
        tester,
        _captureKey,
        'permission-workspace-department-multiselect',
      );
    }
    await tester.tap(find.text('应用模板'));
    await tester.pumpAndSettle();
    final dialog = tester.widget<PermissionBatchDialog>(
      find.byType(PermissionBatchDialog),
    );
    expect(dialog.userIds, isEmpty);
    expect(dialog.departmentIds, [
      'department-a',
      'department-child',
      'department-b',
    ]);
    expect(tester.takeException(), isNull);
  });

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
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(AdminUserDetailPanel),
            matching: find.text('开通账号'),
          ),
          findsNothing,
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

  for (final width in [375.0, 1440.0]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets(
        'employee selection toolbar replaces provisioning at $width and text scale $scale',
        (tester) async {
          if (_captureScreenshots) await loadAuditScreenshotFonts(tester);
          await _mount(
            tester,
            _Repository(),
            _AiRepository(),
            width: width,
            scale: scale,
            initialEmployeeId: null,
          );
          final toggle = find.byKey(
            const ValueKey('permission-employee-multi-select'),
          );
          final filter = find.byKey(
            const ValueKey('admin-account-status-filter'),
          );
          expect(find.text('开通账号'), findsNothing);
          expect(tester.widget<UtenButton>(toggle).onPressed, isNotNull);
          expect(
            tester.getRect(toggle).top,
            greaterThan(tester.getRect(filter).bottom),
          );
          if (_captureScreenshots && scale == 1) {
            await saveAuditScreenshot(
              tester,
              _captureKey,
              'permission-employee-selection-idle-${width.toInt()}',
            );
          }

          await tester.tap(toggle);
          await tester.pumpAndSettle();
          final selectAll = find.byKey(
            const ValueKey('permission-employee-select-all'),
          );
          final count = find.byKey(
            const ValueKey('permission-employee-selection-count'),
          );
          expect(
            find.descendant(of: toggle, matching: find.text('取消')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: selectAll, matching: find.text('全选')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: count, matching: find.text('已选 0 人')),
            findsOneWidget,
          );
          expect(find.text('结束多选'), findsNothing);
          expect(find.text('选择已加载'), findsNothing);
          expect(find.text('清空'), findsNothing);
          expect(find.text('批量设置'), findsNothing);
          expect(tester.takeException(), isNull);

          await tester.tap(selectAll);
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: selectAll, matching: find.text('取消全选')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: count, matching: find.text('已选 1 人')),
            findsOneWidget,
          );
          expect(
            tester
                .widget<Checkbox>(
                  find.byKey(
                    const ValueKey('permission-select-user-user-target'),
                  ),
                )
                .value,
            isTrue,
          );
          if (_captureScreenshots) {
            await saveAuditScreenshot(
              tester,
              _captureKey,
              'permission-employee-selection-active-${width.toInt()}-${scale == 1 ? 'normal' : 'large'}',
            );
          }
          if (width < 1000) {
            await tester.tap(count);
            await tester.pumpAndSettle();
            expect(find.text('已选 1 名员工'), findsOneWidget);
            expect(find.text('应用模板'), findsOneWidget);
            expect(find.text('批量设置权限'), findsOneWidget);
            await tester.tap(find.text('返回员工列表'));
            await tester.pumpAndSettle();
            expect(
              find.descendant(of: count, matching: find.text('已选 1 人')),
              findsOneWidget,
            );
          }
          await tester.tap(selectAll);
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: count, matching: find.text('已选 0 人')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: selectAll, matching: find.text('全选')),
            findsOneWidget,
          );
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: toggle, matching: find.text('多选')),
            findsOneWidget,
          );
          expect(selectAll, findsNothing);
          expect(count, findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'employee select all excludes self and ineligible account states',
    (tester) async {
      await _mount(
        tester,
        _SelectionRowsRepository([
          _selectionUser('eligible'),
          _selectionUser('self'),
          _selectionUser('locked', status: 'locked'),
          _selectionUser('disabled', status: 'disabled'),
          _selectionUser('resigned', currentEmployee: false),
        ]),
        _AiRepository(),
        width: 1440,
        initialEmployeeId: null,
        actorUserId: 'self',
      );
      await tester.tap(
        find.byKey(const ValueKey('permission-employee-multi-select')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('permission-employee-select-all')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 1 人'), findsOneWidget);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('permission-select-user-eligible')),
            )
            .value,
        isTrue,
      );
      for (final id in ['self', 'locked', 'disabled', 'resigned']) {
        final checkbox = tester.widget<Checkbox>(
          find.byKey(ValueKey('permission-select-user-$id')),
        );
        expect(checkbox.value, isFalse);
        expect(checkbox.onChanged, isNull);
      }
      expect(find.text('取消全选'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'employee select all and individual selection retain the 500 person limit',
    (tester) async {
      await _mount(
        tester,
        _SelectionRowsRepository([
          for (var index = 0; index < 501; index++)
            _selectionUser('limit-$index'),
        ]),
        _AiRepository(),
        width: 1440,
        initialEmployeeId: null,
      );
      await tester.tap(
        find.byKey(const ValueKey('permission-employee-multi-select')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('permission-employee-select-all')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 500 人'), findsOneWidget);
      expect(find.text('取消全选'), findsOneWidget);
      final last = find.byKey(
        const ValueKey('permission-select-user-limit-500'),
      );
      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('admin-account-list-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(last, 2000, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(last).value, isFalse);
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(find.text('已选 500 人'), findsOneWidget);
      expect(tester.widget<Checkbox>(last).value, isFalse);
      await tester.tap(
        find.byKey(const ValueKey('permission-employee-select-all')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 0 人'), findsOneWidget);
      expect(find.text('全选'), findsOneWidget);
      expect(tester.widget<Checkbox>(last).value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending and failed employee search cannot select or cancel stale loaded accounts',
    (tester) async {
      final repository = _SelectionSearchRepository();
      await _mount(
        tester,
        repository,
        _AiRepository(),
        width: 1440,
        initialEmployeeId: null,
      );
      await tester.tap(
        find.byKey(const ValueKey('permission-employee-multi-select')),
      );
      await tester.pumpAndSettle();
      final selectAll = find.byKey(
        const ValueKey('permission-employee-select-all'),
      );
      await tester.tap(selectAll);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 人'), findsOneWidget);
      expect(find.text('取消全选'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, '搜索姓名 / 工号 / 登录账号'),
        '新范围',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(repository.searches, ['新范围']);
      expect(tester.widget<UtenButton>(selectAll).onPressed, isNull);
      await tester.tap(selectAll);
      await tester.pump();
      expect(find.text('已选 1 人'), findsOneWidget);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('permission-select-user-stale')),
            )
            .value,
        isTrue,
      );

      repository.pendingSearch.completeError(
        ApiException('SEARCH_FAILED', '搜索失败，请重试'),
      );
      await tester.pumpAndSettle();
      expect(find.text('搜索失败，请重试'), findsOneWidget);
      expect(tester.widget<UtenButton>(selectAll).onPressed, isNull);
      await tester.tap(selectAll);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 人'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
    'super administrator target allows personal revokes but locks superadmin-only codes',
    (tester) async {
      final repository = _SuperAdminOverrideRepository();
      await _mount(tester, repository, _AiRepository(), width: 1440);

      // 权限目录按模块/子类折叠，先展开到权限行。
      await tester.tap(find.text('常用模块').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('资料').first);
      await tester.pumpAndSettle();

      // 默认生效的普通码显示「超管默认」来源，开关可用。
      expect(find.text('超管默认'), findsWidgets);
      final revokedSwitch = tester.widget<Switch>(
        find.descendant(
          of: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                (widget.properties.label?.contains('编辑销售订单') ?? false),
          ),
          matching: find.byType(Switch),
        ),
      );
      expect(revokedSwitch.value, isFalse, reason: '已收回的码开关为关');
      expect(revokedSwitch.onChanged, isNotNull, reason: '超管目标可逐项调整');

      // 只随超管身份生效的码锁定，提示不能收回。
      final exclusiveSwitch = tester.widget<Switch>(
        find.descendant(
          of: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                (widget.properties.label?.contains('管理授权') ?? false),
          ),
          matching: find.byType(Switch),
        ),
      );
      expect(exclusiveSwitch.value, isTrue);
      expect(exclusiveSwitch.onChanged, isNull);

      // 「全部授权」对超管目标可用（=恢复全量默认）；「全部收回」不出现。
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('admin-grant-all-permissions')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        find.byKey(const ValueKey('admin-revoke-all-permissions')),
        findsNothing,
      );

      // 打开已收回的码 = 撤掉个人收回恢复默认：保存时不写任何加授行。
      await tester.tap(
        find.descendant(
          of: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                (widget.properties.label?.contains('编辑销售订单') ?? false),
          ),
          matching: find.byType(Switch),
        ),
      );
      await tester.pump();
      expect(find.text('已修改 1 项'), findsOneWidget);
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();
      expect(
        repository.overrideSaves,
        hasLength(1),
        reason: '超管目标保存只携带收回差量，恢复默认即空集合',
      );
      expect(
        repository.overrideSaves.single.grants,
        isEmpty,
        reason: '不写任何加授行',
      );
      expect(
        repository.overrideSaves.single.revokes,
        isEmpty,
        reason: '撤掉收回后期望集合为空',
      );
      expect(tester.takeException(), isNull);
    },
  );

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
      // 不再逐键即存（每次保存都要输一次密码）：短暂停顿不触发保存。
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(templates.savedCodes, isEmpty);
      // 停止操作满一分钟：闲置自动保存接管，草稿一次落库。
      await tester.pump(const Duration(minutes: 1));
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
      expect(find.textContaining('已保存'), findsOneWidget);
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
        findsNothing,
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
  double height = 1000,
  bool pageFrame = false,
  String? initialEmployeeId = 'employee-target',
  String? initialDepartmentId,
  _TemplateRepository? templates,
  String? actorUserId,
}) async {
  tester.view.physicalSize = Size(width, height);
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
        if (actorUserId != null)
          sessionProvider.overrideWith(() => _SelectionSession(actorUserId)),
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
          home: pageFrame
              ? Row(
                  children: [
                    if (width >= 600) const SizedBox(width: 80),
                    Expanded(
                      child: UtenContentContainer(
                        selectable: false,
                        child: AdminPermissionsPage(
                          key: const ValueKey('permission-real-page-frame'),
                          initialEmployeeId: initialEmployeeId,
                          initialDepartmentId: initialDepartmentId,
                        ),
                      ),
                    ),
                  ],
                )
              : AdminPermissionsPage(
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

/// 超管目标（含本人）权限编辑语义：默认码可收回、专属码锁定、保存只携带收回差量。
class _SuperAdminOverrideRepository extends _Repository {
  final overrideSaves = <({List<String> grants, List<String> revokes})>[];

  @override
  Future<List<PermissionCatalogGroup>> permissionCatalog() async => [
    const PermissionCatalogGroup(
      category: '资料',
      module: '常用模块',
      permissions: [
        AdminPermission(
          id: 'perm-goods-view',
          code: 'goods:view',
          actionType: PermissionActionType.view,
          name: '查看测试资料',
          category: '资料',
          module: '常用模块',
        ),
        AdminPermission(
          id: 'perm-sales-edit',
          code: 'sales_order:edit',
          actionType: PermissionActionType.edit,
          name: '编辑销售订单',
          category: '订单',
          module: '订单模块',
        ),
        AdminPermission(
          id: 'perm-auth-manage',
          code: 'authorization:manage',
          actionType: PermissionActionType.edit,
          name: '管理授权',
          category: '系统',
          module: '系统管理',
          grantPolicy: PermissionGrantPolicy(<String>{
            PermissionGrantPolicy.superadminOnly,
          }),
        ),
      ],
    ),
  ];

  @override
  Future<EffectivePermissions> effectivePermissions(String userId) async =>
      const EffectivePermissions(
        superAdmin: true,
        departmentPermissions: [],
        baselinePermissions: [],
        grants: [],
        revokes: ['sales_order:edit'],
        effective: ['goods:view', 'authorization:manage'],
      );

  @override
  Future<PermissionChange> updateUserPermOverrides(
    String userId, {
    required List<String> grants,
    required List<String> revokes,
  }) async {
    overrideSaves.add((grants: grants, revokes: revokes));
    return PermissionChange.none;
  }
}

class _SelectionSession extends SessionNotifier {
  _SelectionSession(this.userId);
  final String userId;

  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: userId, code: userId, name: userId),
  );
}

AdminUserSummary _selectionUser(
  String id, {
  String status = 'active',
  bool currentEmployee = true,
}) => AdminUserSummary(
  id: id,
  loginAccount: id,
  employeeName: id,
  status: status,
  employeeStatus: currentEmployee ? 'active' : 'resigned',
  currentEmployee: currentEmployee,
  mustChangePassword: false,
  remoteAccess: false,
);

class _SelectionRowsRepository extends _Repository {
  _SelectionRowsRepository(this.rows);
  final List<AdminUserSummary> rows;

  @override
  Future<PagedResult<AdminUserSummary>> listUsers({
    int page = 1,
    int size = 20,
    String? search,
    String? status,
  }) async => PagedResult(
    items: rows,
    page: 1,
    size: rows.length,
    total: rows.length,
    totalPages: 1,
  );
}

class _SelectionSearchRepository extends _SelectionRowsRepository {
  _SelectionSearchRepository() : super([_selectionUser('stale')]);
  final pendingSearch = Completer<PagedResult<AdminUserSummary>>();
  final searches = <String>[];

  @override
  Future<PagedResult<AdminUserSummary>> listUsers({
    int page = 1,
    int size = 20,
    String? search,
    String? status,
  }) {
    if (search != null) {
      searches.add(search);
      return pendingSearch.future;
    }
    return super.listUsers(page: page, size: size, status: status);
  }
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

class _SelectionPagingRepository extends _PrefetchRepository {
  final searches = <String?>[];
  @override
  Future<PagedResult<AdminUserSummary>> listUsers({
    int page = 1,
    int size = 20,
    String? search,
    String? status,
  }) async {
    pages.add(page);
    searches.add(search);
    if (search?.isNotEmpty == true) {
      return PagedResult(
        items: [this.page(1).items.first],
        page: 1,
        size: size,
        total: 1,
        totalPages: 1,
      );
    }
    return this.page(page);
  }
}

class _SelectionDepartmentRepository extends _Repository {
  @override
  Future<List<DepartmentNode>> departmentTree() async => [
    DepartmentNode(
      id: 'department-a',
      code: 'A',
      name: '部门甲',
      level: '一级部门',
      children: [
        DepartmentNode(
          id: 'department-child',
          code: 'A1',
          name: '班组甲',
          level: '二级班组',
          children: [],
        ),
      ],
    ),
    DepartmentNode(
      id: 'department-b',
      code: 'B',
      name: '部门乙',
      level: '一级部门',
      children: [],
    ),
  ];
}

class _BaselineDependencyRepository extends _Repository {
  bool _hasBaselineRead = false;
  int departmentReads = 0;
  int departmentWrites = 0;
  final baselineWrites = <List<String>>[];

  @override
  Future<List<PermissionCatalogGroup>> permissionCatalog() async => const [
    PermissionCatalogGroup(
      module: '基础资料',
      category: '货品资料',
      permissions: [
        AdminPermission(
          id: 'goods-view',
          code: 'goods:view',
          name: '查看货品',
          category: '货品资料',
          module: '基础资料',
          actionType: PermissionActionType.view,
        ),
        AdminPermission(
          id: 'goods-edit',
          code: 'goods:edit',
          name: '编辑货品',
          category: '货品资料',
          module: '基础资料',
          actionType: PermissionActionType.edit,
          requiredPermissions: ['goods:view'],
        ),
      ],
    ),
  ];

  @override
  Future<List<String>> departmentPermissions(String departmentId) async {
    expect(departmentId, 'department-target');
    departmentReads++;
    return DepartmentPermissionCodes(
      ['goods:edit'],
      inheritedPermissions: _hasBaselineRead ? ['goods:view'] : const [],
      requiredPermissions: const {
        'goods:edit': ['goods:view'],
      },
      missingDependencies: _hasBaselineRead
          ? const {}
          : const {
              'goods:edit': ['goods:view'],
            },
    );
  }

  @override
  Future<List<String>> permissionBaseline() async =>
      _hasBaselineRead ? ['goods:view'] : [];

  @override
  Future<PermissionChange> updatePermissionBaseline(List<String> codes) async {
    baselineWrites.add(List.of(codes)..sort());
    final previouslyHeld = _hasBaselineRead;
    _hasBaselineRead = codes.contains('goods:view');
    return PermissionChange(
      added: _hasBaselineRead && !previouslyHeld ? ['goods:view'] : [],
      removed: !_hasBaselineRead && previouslyHeld ? ['goods:view'] : [],
    );
  }

  @override
  Future<PermissionChange> updateDepartmentPermissions(
    String departmentId,
    List<String> permissionCodes,
  ) async {
    departmentWrites++;
    return PermissionChange.none;
  }
}
