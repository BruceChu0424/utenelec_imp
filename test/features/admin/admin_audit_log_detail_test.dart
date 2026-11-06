import '../../support/master_dictionary_fixture.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'dart:async';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';

import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/features/admin/pages/admin_audit_session_detail_page.dart';
import 'package:uten_imp/features/admin/widgets/audit_query_scope.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/core/audit/device_audit_store.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/models/audit_session.dart';
import 'package:uten_imp/features/admin/pages/admin_audit_log_page.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';
import 'package:uten_imp/shared/models/department_node.dart';
import 'package:uten_imp/features/employee/providers/employee_picker_department_tree_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

part 'admin_audit_cache_cases.dart';

final _auditDepartmentTree = [
  DepartmentNode(
    id: 'audit-company',
    code: 'AUDIT_COMPANY',
    name: '测试公司',
    level: '公司',
    children: [
      DepartmentNode(
        id: 'audit-production',
        code: 'AUDIT_PRODUCTION',
        name: '生产部',
        level: '一级部门',
        parentId: 'audit-company',
        children: [],
      ),
    ],
  ),
];

void main() {
  for (final sessionMode in [true, false]) {
    testWidgets(
      'header query ${sessionMode ? 'session' : 'event'} applies before paging and matches export scope',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final repository = _HeaderAuditRepository();
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              emptyMasterDictionaryFixture(),
              employeePickerDepartmentTreeProvider.overrideWith(
                (ref) async => _auditDepartmentTree,
              ),
              auditLogRepositoryProvider.overrideWithValue(repository),
              currentPermissionsProvider.overrideWithValue({
                Perm.auditLogExport,
              }),
              sharedPreferencesProvider.overrideWithValue(preferences),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: Locale('zh'),
              home: AdminAuditLogPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _selectDefaultAuditScope(tester, eventView: !sessionMode);
        final column = sessionMode ? 'operations' : 'device';
        final header = find.byKey(ValueKey('master-column-filter-$column'));
        await _scrollAuditPageUntilBuilt(
          tester,
          find.byKey(
            Key(sessionMode ? 'audit-session-table' : 'audit-event-table'),
          ),
        );
        if (sessionMode) {
          final table = tester.widget<MasterDataTableView<AuditSessionSummary>>(
            find.byKey(const Key('audit-session-table')),
          );
          final row = table.rowsController!.items.first;
          expect(table.outputSelectionEnabled, isTrue);
          expect(table.selectable, isFalse);
          expect(table.idOf!(row), row.sessionId);
          expect(table.outputSelectorOf!(row), {'sessionId': row.sessionId});
        } else {
          final table = tester.widget<MasterDataTableView<AuditLogEntry>>(
            find.byKey(const Key('audit-event-table')),
          );
          final row = table.rowsController!.items.first;
          expect(table.outputSelectionEnabled, isTrue);
          expect(table.selectable, isFalse);
          expect(table.idOf!(row), row.id.toString());
          expect(table.outputSelectorOf!(row), {'auditId': row.id.toString()});
        }
        await tester.ensureVisible(header.first);
        await tester.pumpAndSettle();
        await tester.tap(header.hitTestable().first);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('uten-column-keyword-input')),
          sessionMode ? '>=2' : '设备 %_',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        final reads = sessionMode
            ? repository.headerSessions
            : repository.headerEvents;
        final filtered = reads
            .where((q) => q['search.$column'] != null)
            .toList();
        expect(filtered.first['page'], 1);
        expect(filtered.first['actorId'], _AuditRepository.actorId);
        final export = tester.widget<UtenExportButton>(
          find.byType(UtenExportButton),
        );
        expect(
          export.queryParams['search.$column'],
          sessionMode ? '>=2' : '设备 %_',
        );
        if (!sessionMode) {
          expect(repository.headerSummaries.last['search.device'], '设备 %_');
        }
        if (sessionMode) {
          await tester.ensureVisible(header.first);
          await tester.pumpAndSettle();
          await tester.tap(header.hitTestable().first);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('uten-column-keyword-input')),
            '>=999',
          );
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('audit-session-table')), findsOneWidget);
          await tester.ensureVisible(header.first);
          await tester.pumpAndSettle();
          await tester.tap(header.hitTestable().first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('所有'));
          await tester.pumpAndSettle();
          expect(repository.headerSessions.last['search.operations'], isNull);
        }
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      },
    );
  }
  auditCacheCases();
  TestWidgetsFlutterBinding.ensureInitialized();

  if (const bool.fromEnvironment('UTEN_CAPTURE_UI')) {
    for (final width in [375.0, 1440.0]) {
      for (final eventView in [false, true]) {
        testWidgets('capture loaded audit $width events=$eventView', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await loadAuditScreenshotFonts(tester);
          final date = ChinaDateTime.formatDate(ChinaDateTime.today());
          final repository = _AuditRepository(
            captureDate: date,
            primaryEntry: AuditLogEntry(
              id: 42,
              actorId: _AuditRepository.actorId,
              actorAccount: 'planner',
              actorName: '王建华',
              actorDisplay: '王建华(P016)',
              actorDepartment: '生产部',
              actorPosition: '计划专员',
              action: 'update',
              actionLabel: '下达车间任务',
              targetType: 'production_execution_segments',
              objectLabel: '车间任务',
              targetId: 'segment-1',
              targetName: '铜接头加工任务',
              summary: '下达车间任务：铜接头加工 120 件',
              result: 'success',
              resultLabel: '成功',
              statusCode: 200,
              createdAt: '${date}T08:20:00+08:00',
            ),
          );
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                emptyMasterDictionaryFixture(),
                employeePickerDepartmentTreeProvider.overrideWith(
                  (ref) async => _auditDepartmentTree,
                ),
                auditLogRepositoryProvider.overrideWithValue(repository),
                sharedPreferencesProvider.overrideWithValue(preferences),
              ],
              child: MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh'),
                theme: auditScreenshotTheme(
                  width < 600 ? buildDarkTheme() : buildLightTheme(),
                ),
                builder: (_, child) =>
                    RepaintBoundary(key: boundaryKey, child: child),
                home: const AdminAuditLogPage(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _selectDefaultAuditScope(tester, eventView: eventView);
          final scrollable = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(CustomScrollView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          scrollable.position.jumpTo(0);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await saveAuditScreenshot(
            tester,
            boundaryKey,
            'audit-loaded-${width.toInt()}-${eventView ? 'events' : 'sessions'}',
          );
        });
      }
    }
  }

  testWidgets(
    'event rows render while summary is pending and survive summary failure',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pending = Completer<AuditSummary>();
      final repository = _AuditRepository(summaryCompleter: pending);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            emptyMasterDictionaryFixture(),
            employeePickerDepartmentTreeProvider.overrideWith(
              (ref) async => _auditDepartmentTree,
            ),
            auditLogRepositoryProvider.overrideWithValue(repository),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: AdminAuditLogPage(
              initialRequestId: '123e4567-e89b-42d3-a456-426614174000',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.summaryCalls, hasLength(1));
      expect(find.textContaining('修改生产执行分段'), findsWidgets);
      expect(repository.lastSummaryOwner, isNotNull);
      expect(repository.lastSummaryOwner!(), isTrue);
      pending.completeError(Exception('aggregate unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('统计暂不可用，操作记录仍可核查'), findsOneWidget);
      expect(find.textContaining('修改生产执行分段'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disabled export button does not open the password dialog', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: Scaffold(
            body: UtenExportButton(
              endpoint: '/admin/audit-logs/export',
              report: 'filtered',
              queryParams: <String, dynamic>{},
              enabled: false,
              label: '导出当前结果',
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('导出当前结果'));
    await tester.pumpAndSettle();

    expect(find.text('导出 Excel'), findsNothing);
  });

  testWidgets('system management can inspect redacted before and after JSON', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emptyMasterDictionaryFixture(),
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _auditDepartmentTree,
          ),
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: AdminAuditLogPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _selectDefaultAuditScope(tester);

    await _scrollAuditPageUntilVisible(tester, find.textContaining('修改生产执行分段'));
    expect(find.textContaining('修改生产执行分段'), findsOneWidget);
    await tester.tap(find.textContaining('修改生产执行分段'));
    await tester.pumpAndSettle();

    expect(find.text('审计详情 #42'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, '数据变更'));
    await tester.pumpAndSettle();

    expect(find.text('status'), findsNothing);
    expect(find.text('状态'), findsWidgets);
    expect(find.text('已就绪'), findsWidgets);
    expect(find.text('已下达'), findsWidgets);
    await tester.ensureVisible(find.text('查看变更前原始数据'));
    await tester.tap(find.text('查看变更前原始数据'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"status": "READY"'), findsOneWidget);
    expect(repository.detailCalls, 1);
  });

  testWidgets('overview card explains the operation in plain Chinese', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emptyMasterDictionaryFixture(),
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _auditDepartmentTree,
          ),
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: AdminAuditLogPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _selectDefaultAuditScope(tester);

    await _scrollAuditPageUntilVisible(tester, find.textContaining('修改生产执行分段'));
    await tester.tap(find.textContaining('修改生产执行分段'));
    await tester.pumpAndSettle();

    // 叙事卡：标题 + 谁 + 何时/在哪 chips + 大字动作句 + 具体变更（字段名 + 新旧值胶囊）。
    expect(find.text('这次操作做了什么'), findsOneWidget);
    expect(find.text('修改生产执行分段：状态由已就绪改为已下达'), findsWidgets);
    expect(find.text('具体变更'), findsOneWidget);
    expect(find.text('状态'), findsWidgets);
    expect(find.text('已就绪'), findsWidgets);
    expect(find.text('已下达'), findsWidgets);
    expect(find.text('成功'), findsWidgets);
    expect(find.textContaining('planner'), findsWidgets);
    expect(find.textContaining('北京时间'), findsWidgets);
    expect(find.text('操作说明'), findsOneWidget);
  });

  testWidgets(
    'selected person defaults to session summaries without inline event fetch',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _AuditRepository();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            emptyMasterDictionaryFixture(),
            employeePickerDepartmentTreeProvider.overrideWith(
              (ref) async => _auditDepartmentTree,
            ),
            auditLogRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: AdminAuditLogPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _selectDefaultAuditScope(tester, eventView: false);

      expect(repository.sessionCalls, hasLength(1));
      expect(repository.listCalls, isEmpty);
      expect(repository.sessionEventCalls, isEmpty);
      expect(find.text('登录会话'), findsWidgets);

      final sessionCard = find.byKey(
        const ValueKey('audit-session-${_AuditRepository.sessionId}'),
      );
      await _scrollAuditPageUntilVisible(tester, sessionCard);
      expect(sessionCard, findsOneWidget);
      expect(find.byKey(const Key('audit-session-table')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('audit-session-event-42')),
        findsNothing,
      );
      expect(repository.sessionEventCalls, isEmpty);
      expect(repository.detailCalls, 0);

      await tester.tapAt(tester.getTopLeft(sessionCard) + const Offset(80, 24));
      await tester.pumpAndSettle();
      expect(find.byType(AdminAuditSessionDetailPage), findsOneWidget);
      expect(
        tester.getRect(find.byType(AdminAuditSessionDetailPage)).right,
        1200,
      );
      expect(
        tester.getRect(find.byType(AdminAuditSessionDetailPage)).left,
        greaterThan(0),
      );
      expect(repository.sessionEventCalls, hasLength(1));
      expect(repository.sessionEventCalls.single['snapshotAuditId'], 9001);
      await tester.tap(
        find.descendant(
          of: find.byType(UtenBackButton).last,
          matching: find.byType(IconButton),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AdminAuditSessionDetailPage), findsNothing);
      expect(find.byKey(const Key('audit-session-table')), findsOneWidget);
      expect(repository.sessionCalls, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  for (final sessions in [false, true]) {
    for (final zoom in [1.0, 1.5]) {
      for (final thumbStyle in [false, true]) {
        testWidgets(
          '${sessions ? 'session' : 'event'} complete table ${thumbStyle ? 'thumb' : 'wheel'} scrolls locally at $zoom x with stable rows and high-water',
          (tester) async {
            final repository = _AuditRepository(
              totalPages: 3,
              sessionTotalPages: 3,
              rowsPerPage: 40,
            );
            final finder = await _mountCacheAudit(
              tester,
              repository,
              sessions: sessions,
              zoom: zoom,
            );
            final table = tester.widget<MasterDataTableView<dynamic>>(finder);
            final calls = sessions
                ? repository.sessionCalls
                : repository.listCalls;
            expect(calls.map((call) => call['page']), [1, 2, 3]);
            expect(calls.every((call) => call['size'] == 100), true);
            expect(
              calls
                  .skip(1)
                  .every(
                    (call) =>
                        call[sessions ? 'snapshotAuditId' : 'snapshotId'] ==
                        9001,
                  ),
              true,
            );
            expect(table.items, hasLength(120));
            expect(table.onLoadMore, isNull);
            expect(table.onPageChange, isNull);
            expect(
              find.byKey(const ValueKey('master-table-page-next')),
              findsNothing,
            );
            final rows = table.items;
            final summaryCalls = repository.summaryCalls.length;
            final scrolling = find.byType(CustomScrollView).first;
            final position = tester
                .widget<CustomScrollView>(scrolling)
                .controller!;
            if (thumbStyle) {
              position.jumpTo(position.position.maxScrollExtent);
              await tester.pumpAndSettle();
              position.jumpTo(0);
            } else {
              await tester.sendEventToBinding(
                PointerScrollEvent(
                  position: tester.getCenter(scrolling),
                  scrollDelta: const Offset(0, 500),
                ),
              );
              await tester.pumpAndSettle();
              await tester.sendEventToBinding(
                PointerScrollEvent(
                  position: tester.getCenter(scrolling),
                  scrollDelta: const Offset(0, -300),
                ),
              );
            }
            await tester.pumpAndSettle();
            await _scrollAuditPageUntilBuilt(tester, finder);
            expect(calls.map((call) => call['page']), [1, 2, 3]);
            expect(repository.summaryCalls, hasLength(summaryCalls));
            expect(
              tester.widget<MasterDataTableView<dynamic>>(finder).items,
              same(rows),
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  testWidgets(
    'session continuation failure retains the accepted complete snapshot and explicit retry restarts at one',
    (tester) async {
      final repository = _AuditRepository(sessionTotalPages: 3);
      final finder = await _mountCacheAudit(tester, repository, sessions: true);
      MasterDataTableView<dynamic> table() =>
          tester.widget<MasterDataTableView<dynamic>>(finder);
      expect(table().items, hasLength(3));
      final original = table().items;
      repository.sessionPageErrors[2] = [
        StateError('controlled continuation failure'),
      ];
      table().onRetry!();
      await tester.pumpAndSettle();
      expect(repository.sessionCalls.map((call) => call['page']), [
        1,
        2,
        3,
        1,
        2,
      ]);
      expect(table().items, same(original));
      expect(table().error, isNotNull);
      table().onRetry!();
      await tester.pumpAndSettle();
      expect(repository.sessionCalls.map((call) => call['page']), [
        1,
        2,
        3,
        1,
        2,
        1,
        2,
        3,
      ]);
      expect(table().items, hasLength(3));
      expect(table().error, isNull);
      expect(table().onLoadMore, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty sessions explain legacy logs and switch to event view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository(emptySessions: true);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emptyMasterDictionaryFixture(),
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _auditDepartmentTree,
          ),
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: AdminAuditLogPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _selectDefaultAuditScope(tester, eventView: false);

    final legacyHint = find.text('旧日志尚无会话标识，可切换事件视图。');
    await _scrollAuditPageUntilVisible(tester, legacyHint);
    expect(legacyHint, findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('audit-session-empty-show-events')),
    );
    await tester.pumpAndSettle();
    expect(repository.listCalls, hasLength(1));
    expect(repository.summaryCalls, hasLength(1));
    expect(find.text('事件明细'), findsWidgets);
  });

  testWidgets(
    'narrow sales history timeline states who when and which document',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const internalId = '123e4567-e89b-42d3-a456-426614174088';
        const internalPath = '/api/sales/orders/$internalId';
        final repository = _AuditRepository(
          primaryEntry: const AuditLogEntry(
            id: 88,
            actorId: _AuditRepository.actorId,
            actorAccount: 'sales01',
            actorName: '王小明',
            actorDepartment: '销售部',
            actorDisplay: '王小明(sales01)',
            action: 'view_sales_order_detail_history',
            actionLabel: '查看销售订单历史单据',
            targetType: 'sales_orders',
            objectLabel: '销售订单',
            targetId: internalId,
            targetName: 'SO-2026-001(旧系统编号 86)',
            summary: '查看 $internalPath',
            pageLabel: '销售管理 · 销售订单',
            result: 'success',
            resultLabel: '成功',
            statusCode: 200,
            requestId: '123e4567-e89b-42d3-a456-426614174089',
            createdAt: '2026-08-29T23:30:00Z',
          ),
          primaryDetail: const AuditLogDetail(
            id: 88,
            actorId: _AuditRepository.actorId,
            actorAccount: 'sales01',
            actorName: '王小明',
            actorDepartment: '销售部',
            actorDisplay: '王小明(sales01)',
            action: 'view_sales_order_detail_history',
            actionLabel: '查看销售订单历史单据',
            targetType: 'sales_orders',
            objectLabel: '销售订单',
            targetId: internalId,
            targetName: 'SO-2026-001(旧系统编号 86)',
            summary: '查看 $internalPath',
            pageLabel: '销售管理 · 销售订单',
            result: 'success',
            resultLabel: '成功',
            statusCode: 200,
            httpMethod: 'GET',
            httpPath: internalPath,
            createdAt: '2026-08-29T23:30:00Z',
          ),
        );
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              emptyMasterDictionaryFixture(),
              employeePickerDepartmentTreeProvider.overrideWith(
                (ref) async => _auditDepartmentTree,
              ),
              auditLogRepositoryProvider.overrideWithValue(repository),
              currentPermissionsProvider.overrideWithValue({
                Perm.auditLogExport,
              }),
              sharedPreferencesProvider.overrideWithValue(preferences),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: Locale('zh'),
              home: AdminAuditLogPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _selectDefaultAuditScope(tester);

        final narrative = find.text('查看了销售订单历史单据：SO-2026-001(旧系统编号 86)');
        await _scrollAuditPageUntilVisible(tester, narrative);

        expect(narrative, findsOneWidget);
        expect(find.textContaining('王小明(sales01)'), findsWidgets);
        expect(find.text('2026-08-30 07:30(北京时间)'), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            RegExp(
              r'王小明\(sales01\).*2026-08-30 07:30\(北京时间\).*'
              r'查看了销售订单历史单据：SO-2026-001\(旧系统编号 86\).*点击查看详情',
            ),
          ),
          findsOneWidget,
        );
        expect(find.textContaining(internalId), findsNothing);
        expect(find.textContaining(internalPath), findsNothing);
        expect(repository.detailCalls, 0);
        expect(repository.listCalls, hasLength(1));
        expect(tester.takeException(), isNull);

        await tester.pump(const Duration(seconds: 3));
        expect(repository.listCalls, hasLength(1));
        expect(repository.detailCalls, 0);

        await tester.tap(narrative);
        await tester.pumpAndSettle();
        expect(repository.detailCalls, 1);
        expect(find.text('审计详情 #88'), findsOneWidget);
        expect(find.text('查看了销售订单历史单据：SO-2026-001(旧系统编号 86)'), findsWidgets);
        expect(find.text('销售订单历史单据 · SO-2026-001(旧系统编号 86)'), findsOneWidget);
        expect(find.textContaining(internalId), findsNothing);
        expect(find.textContaining(internalPath), findsNothing);

        await tester.tap(find.widgetWithText(Tab, '排查信息'));
        await tester.pumpAndSettle();
        final technicalExpansion = find.byKey(
          const ValueKey('audit-technical-expansion'),
        );
        await _scrollAuditDetailUntilVisible(tester, technicalExpansion);
        await tester.tap(technicalExpansion);
        await tester.pumpAndSettle();
        expect(find.text(internalId), findsOneWidget);
        expect(find.text(internalPath), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'related request changes stay lightweight until one group is expanded',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _AuditRepository(includeRelatedDatabase: true);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            emptyMasterDictionaryFixture(),
            employeePickerDepartmentTreeProvider.overrideWith(
              (ref) async => _auditDepartmentTree,
            ),
            auditLogRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: AdminAuditLogPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _selectDefaultAuditScope(tester);

      await _scrollAuditPageUntilVisible(
        tester,
        find.textContaining('修改生产执行分段'),
      );
      await tester.tap(find.textContaining('修改生产执行分段'));
      await tester.pumpAndSettle();

      expect(repository.detailIds, [42]);
      expect(
        repository.listCalls.where(
          (call) =>
              call['requestId'] == _DeviceStore.requestId &&
              call['activityOnly'] == false &&
              call['size'] == 100,
        ),
        hasLength(1),
      );

      await tester.tap(find.widgetWithText(Tab, '数据变更'));
      await tester.pumpAndSettle();
      expect(find.text('本次操作产生 1 组业务变化'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('audit-related-change-43')),
        findsOneWidget,
      );
      expect(repository.detailIds, [42]);

      await tester.tap(find.text('生产执行分段 · 执行分段二'));
      await tester.pumpAndSettle();
      expect(repository.detailIds, [42, 43]);
      expect(find.text('完整字段详情'), findsOneWidget);
    },
  );

  testWidgets('decorated success result keeps a success badge', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository(
      resultCode: 'success;mode=custom/generated',
      resultLabel: '按自定义规则生成成功',
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emptyMasterDictionaryFixture(),
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _auditDepartmentTree,
          ),
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: AdminAuditLogPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _selectDefaultAuditScope(tester);

    await _scrollAuditPageUntilVisible(tester, find.textContaining('修改生产执行分段'));
    await tester.tap(find.textContaining('修改生产执行分段'));
    await tester.pumpAndSettle();

    final badge = tester
        .widgetList<UtenStatusBadge>(find.byType(UtenStatusBadge))
        .singleWhere((item) => item.label == '按自定义规则生成成功');
    expect(badge.type, UtenStatusBadgeType.success);
  });

  testWidgets('risk metric card drills down to risky operations', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emptyMasterDictionaryFixture(),
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _auditDepartmentTree,
          ),
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: AdminAuditLogPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _selectDefaultAuditScope(tester);

    expect(repository.lastRiskLevel, isNull);
    await tester.tap(find.text('风险行为'));
    await tester.pumpAndSettle();

    expect(repository.lastRiskLevel, 'risky');
    final exportButton = tester.widget<UtenExportButton>(
      find.byType(UtenExportButton),
    );
    expect(find.text('导出当前结果'), findsOneWidget);
    expect(exportButton.enabled, isTrue);
    expect(exportButton.queryParams['riskLevel'], 'risky');

    final table = find.byKey(const Key('audit-event-table'));
    await _scrollAuditPageUntilBuilt(tester, table);
    await tester.tap(find.descendant(of: table, matching: find.text('有风险')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高风险').last);
    await tester.pumpAndSettle();
    expect(repository.listCalls.last['riskLevel'], 'high');
    expect(repository.listCalls.last['page'], 1);
    await tester.tap(find.descendant(of: table, matching: find.text('结果')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('失败').last);
    await tester.pumpAndSettle();
    expect(repository.listCalls.last['outcome'], 'failure');
    expect(repository.listCalls.last['riskLevel'], 'high');
    expect(repository.listCalls.last['actorId'], _AuditRepository.actorId);
    final filteredExport = tester.widget<UtenExportButton>(
      find.byType(UtenExportButton),
    );
    expect(filteredExport.queryParams['outcome'], 'failure');
    expect(filteredExport.queryParams['riskLevel'], 'high');
    expect(tester.takeException(), isNull);
  });

  testWidgets('personnel directory search debounces rapid input', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emptyMasterDictionaryFixture(),
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _auditDepartmentTree,
          ),
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: AdminAuditLogPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('audit-select-actor')));
    await tester.pumpAndSettle();
    expect(repository.actorCalls, 1);

    final field = find.descendant(
      of: find.descendant(
        of: find.byType(AuditActorPicker),
        matching: find.byType(UtenSearchBar),
      ),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '计');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(field, '计划');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 299));
    expect(repository.actorCalls, 1);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(repository.actorCalls, 2);
  });

  testWidgets(
    'device evidence compares the server row with the local receipt',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _AuditRepository(earlyAttempt: true);
      final deviceStore = _DeviceStore();
      final api = _Api();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            emptyMasterDictionaryFixture(),
            employeePickerDepartmentTreeProvider.overrideWith(
              (ref) async => _auditDepartmentTree,
            ),
            auditLogRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
            sharedPreferencesProvider.overrideWithValue(preferences),
            deviceAuditStoreProvider.overrideWithValue(deviceStore),
            apiClientProvider.overrideWithValue(api),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: AdminAuditLogPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _selectDefaultAuditScope(tester);

      await _scrollAuditPageUntilVisible(
        tester,
        find.textContaining('修改生产执行分段'),
      );
      await tester.tap(find.textContaining('修改生产执行分段'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, '设备证据'));
      await tester.pumpAndSettle();

      expect(find.text('尚未核查本机回执'), findsOneWidget);
      expect(deviceStore.profileCalls, 0);
      expect(deviceStore.findCalls, 0);

      await _scrollAuditDetailUntilVisible(
        tester,
        find.byKey(const ValueKey('authorize-local-audit-receipt')),
      );
      await tester.tap(find.text('授权并核对本机回执'));
      await tester.pumpAndSettle();

      expect(api.posts, [
        ApiEndpoints.adminAuditLocalReceiptVerification(_DeviceStore.eventId),
      ]);
      expect(deviceStore.profileCalls, 1);
      expect(deviceStore.findCalls, 1);
      expect(find.text('本机回执与服务器记录一致'), findsOneWidget);
      expect(find.text('测试电脑'), findsWidgets);
      expect(find.text('QA-1'), findsWidgets);
      expect(find.text(_DeviceStore.installationId), findsWidgets);
    },
  );

  testWidgets('device evidence authorization failure never reads local data', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository(
      earlyAttempt: true,
      resultLabel: '成功；旧数据',
    );
    final deviceStore = _DeviceStore();
    final api = _Api(postError: StateError('offline'));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emptyMasterDictionaryFixture(),
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _auditDepartmentTree,
          ),
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
          deviceAuditStoreProvider.overrideWithValue(deviceStore),
          apiClientProvider.overrideWithValue(api),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: AdminAuditLogPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _selectDefaultAuditScope(tester);

    await _scrollAuditPageUntilVisible(tester, find.textContaining('修改生产执行分段'));
    await tester.tap(find.textContaining('修改生产执行分段'));
    await tester.pumpAndSettle();
    final failureBadge = tester
        .widgetList<UtenStatusBadge>(find.byType(UtenStatusBadge))
        .singleWhere((item) => item.label == '失败');
    expect(failureBadge.type, UtenStatusBadgeType.danger);
    await tester.tap(find.widgetWithText(Tab, '设备证据'));
    await tester.pumpAndSettle();
    await _scrollAuditDetailUntilVisible(
      tester,
      find.byKey(const ValueKey('authorize-local-audit-receipt')),
    );
    await tester.tap(find.text('授权并核对本机回执'));
    await tester.pumpAndSettle();

    expect(find.text('重新授权并核对'), findsOneWidget);
    expect(find.textContaining('未读取本机回执'), findsOneWidget);
    expect(api.posts, hasLength(1));
    expect(deviceStore.profileCalls, 0);
    expect(deviceStore.findCalls, 0);
  });

  testWidgets(
    'does not load until actor and date are applied, then shares high-water',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _AuditRepository();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            emptyMasterDictionaryFixture(),
            employeePickerDepartmentTreeProvider.overrideWith(
              (ref) async => _auditDepartmentTree,
            ),
            auditLogRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: AdminAuditLogPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(repository.listCalls, isEmpty);
      expect(repository.summaryCalls, isEmpty);
      expect(
        tester.widget<UtenExportButton>(find.byType(UtenExportButton)).enabled,
        isFalse,
      );

      await tester.tap(find.byKey(const ValueKey('audit-select-actor')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey('employee-picker-item-${_AuditRepository.actorId}'),
        ),
      );
      await tester.pumpAndSettle();
      // Confirming the panel applies the actor choice without loading data.
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      await tester.pumpAndSettle();
      expect(repository.listCalls, isEmpty);
      expect(repository.summaryCalls, isEmpty);

      final originalRange = tester
          .widget<AuditQueryScopeComposer>(find.byType(AuditQueryScopeComposer))
          .dateRange;
      // Business-day bounds count dates, independently of DST/time carriers.
      tester
          .widget<AuditQueryScopeComposer>(find.byType(AuditQueryScopeComposer))
          .onDateChanged(
            DateTimeRange(
              start: DateTime.utc(2026, 3, 1, 23),
              end: DateTime.utc(2026, 4),
            ),
          );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AuditQueryScopeComposer>(
              find.byType(AuditQueryScopeComposer),
            )
            .dateRange,
        originalRange,
      );
      tester
          .widget<AuditQueryScopeComposer>(find.byType(AuditQueryScopeComposer))
          .onDateChanged(
            DateTimeRange(
              start: DateTime.utc(2026, 3, 1, 23),
              end: DateTime.utc(2026, 3, 31, 23),
            ),
          );
      await tester.pumpAndSettle();
      final acceptedRange = tester
          .widget<AuditQueryScopeComposer>(find.byType(AuditQueryScopeComposer))
          .dateRange!;
      expect(acceptedRange.start, DateTime.utc(2026, 3));
      expect(acceptedRange.end, DateTime.utc(2026, 3, 31));
      expect(repository.listCalls, isEmpty);
      expect(repository.sessionCalls, isEmpty);

      await tester.tap(find.byKey(const ValueKey('audit-date-today')));
      await tester.pumpAndSettle();
      expect(repository.listCalls, isEmpty);
      expect(repository.summaryCalls, isEmpty);

      await tester.tap(find.byKey(const ValueKey('audit-run-query')));
      await tester.pumpAndSettle();
      expect(repository.sessionCalls, hasLength(1));
      expect(repository.sessionCalls.single['snapshotAuditId'], isNull);
      expect(
        repository.sessionCalls.single['actorId'],
        _AuditRepository.actorId,
      );
      expect(repository.sessionCalls.single['dateFrom'], isNotNull);
      expect(
        repository.sessionCalls.single['dateTo'],
        repository.sessionCalls.single['dateFrom'],
      );
      expect(repository.sessionEventCalls, isEmpty);
      expect(repository.listCalls, isEmpty);
      expect(repository.summaryCalls, isEmpty);

      await tester.tap(find.text('事件明细'));
      await tester.pumpAndSettle();
      expect(repository.listCalls, hasLength(1));
      expect(repository.listCalls.single['snapshotId'], isNull);
      expect(repository.listCalls.single['actorId'], _AuditRepository.actorId);
      expect(repository.listCalls.single['operationKind'], isNull);
      expect(repository.listCalls.single['actorScope'], 'user');
      expect(repository.listCalls.single['activityOnly'], isTrue);
      expect(repository.listCalls.single['dateFrom'], isNotNull);
      expect(
        repository.listCalls.single['dateTo'],
        repository.listCalls.single['dateFrom'],
      );
      expect(repository.summaryCalls.single['snapshotId'], 9001);
      expect(
        repository.summaryCalls.single['actorId'],
        _AuditRepository.actorId,
      );
      expect(repository.summaryCalls.single['operationKind'], isNull);
      expect(repository.summaryCalls.single['actorScope'], 'user');
      expect(repository.summaryCalls.single['activityOnly'], isTrue);

      final exportButton = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      expect(exportButton.enabled, isTrue);
      expect(exportButton.queryParams['snapshotId'], 9001);
      expect(exportButton.queryParams['actorId'], _AuditRepository.actorId);
      expect(exportButton.queryParams['operationKind'], isNull);
      expect(exportButton.queryParams['actorScope'], 'user');
      expect(exportButton.queryParams['activityOnly'], isTrue);
    },
  );

  testWidgets(
    'business object and operation changes start a fresh high-water',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _AuditRepository();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            emptyMasterDictionaryFixture(),
            employeePickerDepartmentTreeProvider.overrideWith(
              (ref) async => _auditDepartmentTree,
            ),
            auditLogRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: AdminAuditLogPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _selectDefaultAuditScope(tester);

      await _expandAuditFilters(tester);
      final createChip = find.byKey(const ValueKey('audit-operation-create'));
      await _scrollAuditPageUntilVisible(tester, createChip);
      await tester.tap(createChip);
      await tester.pumpAndSettle();

      expect(repository.listCalls.last['operationKind'], 'create');
      expect(repository.listCalls.last['snapshotId'], isNull);
      expect(repository.summaryCalls.last['snapshotId'], 9001);

      final goodsChip = find.byKey(const ValueKey('audit-target-goods'));
      await _scrollAuditPageUntilVisible(tester, goodsChip);
      await tester.tap(goodsChip);
      await tester.pumpAndSettle();

      expect(repository.listCalls.last['targetType'], 'goods');
      expect(repository.listCalls.last['operationKind'], 'create');
      expect(repository.listCalls.last['snapshotId'], isNull);
    },
  );

  testWidgets(
    'unidentified access requires a date and never loads system records',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _AuditRepository();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            emptyMasterDictionaryFixture(),
            employeePickerDepartmentTreeProvider.overrideWith(
              (ref) async => _auditDepartmentTree,
            ),
            auditLogRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: AdminAuditLogPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('audit-select-anonymous')));
      await tester.pumpAndSettle();
      expect(repository.listCalls, isEmpty);

      await tester.tap(find.byKey(const ValueKey('audit-date-today')));
      await tester.pumpAndSettle();
      expect(repository.listCalls, isEmpty);

      await tester.tap(find.byKey(const ValueKey('audit-run-query')));
      await tester.pumpAndSettle();

      expect(repository.listCalls.last['actorId'], isNull);
      expect(repository.listCalls.last['actorScope'], 'anonymous');
      expect(repository.listCalls.last['activityOnly'], isTrue);
      expect(repository.listCalls.last['snapshotId'], isNull);
      expect(repository.listCalls.last['dateFrom'], isNotNull);

      await _expandAuditFilters(tester);
      final actionMenu = find.text('动作分类：全部');
      await _scrollAuditPageUntilVisible(tester, actionMenu);
      await tester.tap(actionMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '登录认证'));
      await tester.pumpAndSettle();
      expect(repository.listCalls.last['action'], 'login');
      expect(repository.listCalls.last['actorScope'], 'anonymous');

      final sourceMenu = find.text('事件来源：全部来源');
      await _scrollAuditPageUntilVisible(tester, sourceMenu);
      await tester.tap(sourceMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '安全拦截'));
      await tester.pumpAndSettle();
      expect(repository.listCalls.last['eventSource'], 'security');
      expect(repository.listCalls.last['actorScope'], 'anonymous');

      final securityCategory = find.byKey(
        const ValueKey('audit-category-security'),
      );
      await _scrollAuditPageUntilVisible(tester, securityCategory);
      await tester.tap(securityCategory);
      await tester.pumpAndSettle();
      expect(repository.listCalls.last['eventCategory'], 'security');
      expect(repository.listCalls.last['actorScope'], 'anonymous');

      final authenticationCategory = find.byKey(
        const ValueKey('audit-category-authentication'),
      );
      await tester.tap(authenticationCategory);
      await tester.pumpAndSettle();
      expect(repository.listCalls.last['eventCategory'], 'authentication');
      expect(repository.listCalls.last['actorScope'], 'anonymous');
    },
  );

  testWidgets(
    'system anomaly scope stays unloaded until date and shows a safe empty state',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _AuditRepository();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            emptyMasterDictionaryFixture(),
            employeePickerDepartmentTreeProvider.overrideWith(
              (ref) async => _auditDepartmentTree,
            ),
            auditLogRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: AdminAuditLogPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.listCalls, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('audit-select-system-anomaly')),
      );
      await tester.pumpAndSettle();
      expect(find.text('系统异常'), findsWidgets);
      expect(find.text('仅调查失败的系统异常，不包含日常成功自动任务'), findsNothing);
      final help = find.byWidgetPredicate(
        (widget) =>
            widget is UtenFieldHintIcon &&
            widget.info == '仅调查失败的系统异常，不包含日常成功自动任务',
      );
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(find.text('仅调查失败的系统异常，不包含日常成功自动任务'), findsOneWidget);
      Tooltip.dismissAllToolTips();
      await tester.pumpAndSettle();
      expect(repository.listCalls, isEmpty);

      await tester.tap(find.byKey(const ValueKey('audit-date-today')));
      await tester.pumpAndSettle();
      expect(repository.listCalls, isEmpty);

      await tester.tap(find.byKey(const ValueKey('audit-run-query')));
      await tester.pumpAndSettle();
      expect(repository.listCalls, hasLength(1));
      expect(repository.listCalls.single['actorId'], isNull);
      expect(repository.listCalls.single['actorScope'], 'system');
      expect(repository.listCalls.single['activityOnly'], isTrue);
      expect(repository.listCalls.single['dateFrom'], isNotNull);
      await _scrollAuditPageUntilVisible(tester, find.text('没有符合条件的操作记录'));
      expect(find.text('没有符合条件的操作记录'), findsOneWidget);
      expect(find.text('系统/迁移'), findsNothing);
    },
  );

  testWidgets(
    'every internal event batch reuses captured high-water and one summary without user page controls',
    (tester) async {
      final repository = _AuditRepository(totalPages: 5, rowsPerPage: 40);
      final finder = await _mountCacheAudit(
        tester,
        repository,
        sessions: false,
      );
      expect(repository.listCalls.map((call) => call['page']), [1, 2, 3, 4, 5]);
      expect(repository.listCalls.first['snapshotId'], isNull);
      expect(repository.listCalls.skip(1).map((call) => call['snapshotId']), [
        9001,
        9001,
        9001,
        9001,
      ]);
      expect(repository.listCalls.every((call) => call['size'] == 100), true);
      expect(repository.summaryCalls, hasLength(1));
      expect(repository.summaryCalls.single['snapshotId'], 9001);
      final table = tester.widget<MasterDataTableView<AuditLogEntry>>(finder);
      expect(table.items, hasLength(200));
      expect(table.items.first.id, 100);
      expect(table.items.last.id, 539);
      expect(
        find.byKey(const ValueKey('master-table-page-next')),
        findsNothing,
      );
      expect(table.onPageChange, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Request ID waits for a complete UUID before querying', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emptyMasterDictionaryFixture(),
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _auditDepartmentTree,
          ),
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: AdminAuditLogPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.listCalls, isEmpty);
    await tester.tap(find.byKey(const ValueKey('audit-request-investigation')));
    await tester.pumpAndSettle();
    final requestField = find.descendant(
      of: find.byKey(const ValueKey('audit-request-id-field')),
      matching: find.byType(TextField),
    );
    await tester.ensureVisible(requestField);
    await tester.enterText(requestField, '123e4567');
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.listCalls, isEmpty);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(repository.listCalls, isEmpty);

    await tester.enterText(requestField, _DeviceStore.requestId);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(repository.listCalls.last['requestId'], _DeviceStore.requestId);
    expect(repository.listCalls.last['activityOnly'], isFalse);
    expect(repository.listCalls.last['snapshotId'], isNull);
    expect(find.text('同一操作 操作趋势'), findsNothing);
  });

  testWidgets('Request ID deep link opens the exact evidence investigation', (
    tester,
  ) async {
    final repository = _AuditRepository();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emptyMasterDictionaryFixture(),
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _auditDepartmentTree,
          ),
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: AdminAuditLogPage(initialRequestId: _DeviceStore.requestId),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(repository.listCalls, hasLength(1));
    expect(repository.listCalls.single['requestId'], _DeviceStore.requestId);
    expect(repository.listCalls.single['activityOnly'], isFalse);
    expect(repository.listCalls.single['actorId'], isNull);
    expect(find.text('关联操作排查'), findsOneWidget);
  });

  testWidgets('same operation action locates the exact Request ID', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _AuditRepository();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emptyMasterDictionaryFixture(),
          employeePickerDepartmentTreeProvider.overrideWith(
            (ref) async => _auditDepartmentTree,
          ),
          auditLogRepositoryProvider.overrideWithValue(repository),
          currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: AdminAuditLogPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _selectDefaultAuditScope(tester);

    await _scrollAuditPageUntilVisible(tester, find.textContaining('修改生产执行分段'));
    await tester.tap(find.textContaining('修改生产执行分段'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('audit-locate-same-request')));
    await tester.pumpAndSettle();

    expect(repository.listCalls.last['requestId'], _DeviceStore.requestId);
    expect(repository.listCalls.last['operationKind'], isNull);
    expect(repository.listCalls.last['actorScope'], isNull);
    expect(repository.listCalls.last['activityOnly'], isFalse);
    expect(repository.listCalls.last['snapshotId'], isNull);
  });

  testWidgets(
    'audit filters remain usable without overflow on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repository = _AuditRepository();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            emptyMasterDictionaryFixture(),
            employeePickerDepartmentTreeProvider.overrideWith(
              (ref) async => _auditDepartmentTree,
            ),
            auditLogRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue({Perm.auditLogExport}),
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: AdminAuditLogPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _selectDefaultAuditScope(tester);

      await _expandAuditFilters(tester);
      final targetCategories = find.byWidgetPredicate(
        (widget) =>
            widget is UtenSegmentRow<String?> &&
            widget.segments.any((segment) => segment.value == 'suppliers'),
      );
      await _scrollAuditPageUntilVisible(tester, targetCategories);
      final supplier = find.byKey(const ValueKey('audit-target-suppliers'));
      if (supplier.hitTestable().evaluate().isEmpty) {
        await tester.tap(
          find.descendant(
            of: targetCategories,
            matching: find.byType(OutlinedButton),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          supplier,
          200,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .last,
        );
        await tester.pumpAndSettle();
      }
      expect(supplier.hitTestable(), findsOneWidget);
      expect(find.text('系统/迁移'), findsNothing);
      expect(find.text('数据库变更'), findsNothing);
      expect(find.text('供应商'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _scrollAuditPageUntilVisible(
  WidgetTester tester,
  Finder finder,
) async {
  final pageScrollable = find
      .descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      )
      .first;
  final position = tester.state<ScrollableState>(pageScrollable).position;
  if (finder.evaluate().isEmpty) {
    position.jumpTo(position.minScrollExtent);
    await tester.pumpAndSettle();
  }
  for (var step = 0; step < 60 && finder.evaluate().isEmpty; step++) {
    position.jumpTo(
      (position.pixels + 160).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    await tester.pumpAndSettle();
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _scrollAuditPageUntilBuilt(
  WidgetTester tester,
  Finder finder,
) async {
  final pageScrollable = find
      .descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      )
      .first;
  // Positioning lazy test content must not synthesize a pull-to-refresh.
  final position = tester.state<ScrollableState>(pageScrollable).position;
  if (finder.evaluate().isEmpty) {
    position.jumpTo(position.minScrollExtent);
    await tester.pumpAndSettle();
  }
  for (var step = 0; step < 50 && finder.evaluate().isEmpty; step++) {
    position.jumpTo(
      (position.pixels + 160).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    await tester.pumpAndSettle();
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Rect _auditGlobalRect(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  return Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(box.size.bottomRight(Offset.zero)),
  );
}

Future<void> _scrollAuditDetailUntilVisible(
  WidgetTester tester,
  Finder finder,
) async {
  final detailScrollable = find
      .descendant(
        of: find.byType(TabBarView),
        matching: find.byType(Scrollable),
      )
      .hitTestable()
      .first;
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: detailScrollable,
    maxScrolls: 20,
  );
  await tester.pumpAndSettle();
}

Future<void> _expandAuditFilters(WidgetTester tester) async {
  final control = find.byKey(const ValueKey('audit-event-filters'));
  await _scrollAuditPageUntilVisible(tester, control);
  if (find.byKey(const ValueKey('audit-operation-all')).evaluate().isEmpty) {
    await tester.tap(control);
    await tester.pumpAndSettle();
  }
}

Future<void> _selectDefaultAuditScope(
  WidgetTester tester, {
  bool eventView = true,
}) async {
  final selectActor = find.byKey(const ValueKey('audit-select-actor'));
  await _scrollAuditPageUntilVisible(tester, selectActor);
  await tester.tap(selectActor);
  await tester.pumpAndSettle();

  // The actor directory now opens the employee selection panel: pick the
  // person row (list tiles are keyed by candidate id), then confirm with the
  // shared 确定 action. Tapping the row alone only drafts the selection.
  final actor = find.byKey(
    const ValueKey('employee-picker-item-${_AuditRepository.actorId}'),
  );
  expect(actor, findsOneWidget);
  // The shared candidate table can scroll horizontally: the full row center
  // may lie outside its viewport on narrow or zoomed screens.
  final candidateTable = find.byKey(
    const Key('uten-employee-picker-candidates'),
  );
  final visibleActor = _auditGlobalRect(tester, actor)
      .intersect(_auditGlobalRect(tester, candidateTable))
      .intersect(
        Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio),
      );
  expect(visibleActor.isEmpty, isFalse);
  await tester.tapAt(visibleActor.center);
  await tester.pumpAndSettle();
  final confirm = find.widgetWithText(UtenButton, '确定');
  expect(tester.widget<UtenButton>(confirm).onPressed, isNotNull);
  await tester.tap(confirm);
  await tester.pumpAndSettle();
  expect(find.byType(AuditActorPicker), findsNothing);

  final today = find.byKey(const ValueKey('audit-date-today'));
  await _scrollAuditPageUntilVisible(tester, today);
  await tester.tap(today);
  await tester.pumpAndSettle();

  final runQuery = find.byKey(const ValueKey('audit-run-query'));
  await _scrollAuditPageUntilVisible(tester, runQuery);
  await tester.tap(runQuery);
  await tester.pumpAndSettle();

  if (eventView) {
    final modeSwitch = find.byKey(const ValueKey('audit-view-mode'));
    await _scrollAuditPageUntilBuilt(tester, modeSwitch);
    final eventMode = find.descendant(
      of: modeSwitch,
      matching: find.byIcon(Icons.list_alt_rounded),
    );
    expect(eventMode, findsOneWidget);
    await tester.tap(eventMode);
    await tester.pumpAndSettle();
  }
}

class _Api extends ApiClient {
  _Api({this.postError}) : super(Dio());

  final Object? postError;
  final posts = <String>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    posts.add(path);
    final error = postError;
    if (error != null) throw error;
    return const <String, dynamic>{};
  }
}

class _HeaderAuditRepository extends _AuditRepository
    implements AuditHeaderSessionRepository, AuditHeaderEventRepository {
  _HeaderAuditRepository({super.totalPages = 1, super.sessionTotalPages = 1});
  final headerSessions = <Map<String, dynamic>>[];
  final headerEvents = <Map<String, dynamic>>[];
  final headerSummaries = <Map<String, dynamic>>[];
  @override
  Future<AuditSessionPage> sessionHeaderPage(Map<String, dynamic> query) async {
    headerSessions.add(Map.of(query));
    if (query['search.operations'] == '>=999') {
      return const AuditSessionPage(
        items: [],
        page: 1,
        size: 10,
        total: 0,
        totalPages: 0,
        snapshotAuditId: 9001,
      );
    }
    return super.sessions(
      actorId: query['actorId'] as String,
      dateFrom: query['dateFrom'] as String,
      dateTo: query['dateTo'] as String,
      page: query['page'] as int,
      snapshotAuditId: query['snapshotAuditId'] as int?,
    );
  }

  @override
  Future<AuditLogPage> eventHeaderPage(Map<String, dynamic> query) {
    headerEvents.add(Map.of(query));
    return super.list(
      page: query['page'] as int,
      actorId: query['actorId'] as String?,
      dateFrom: query['dateFrom'] as String?,
      dateTo: query['dateTo'] as String?,
      snapshotId: query['snapshotId'] as int?,
      activityOnly: query['activityOnly'] as bool,
    );
  }

  @override
  Future<AuditSummary> eventHeaderSummary(Map<String, dynamic> query) {
    headerSummaries.add(Map.of(query));
    return super.summary(
      actorId: query['actorId'] as String?,
      dateFrom: query['dateFrom'] as String?,
      dateTo: query['dateTo'] as String?,
      snapshotId: query['snapshotId'] as int?,
      activityOnly: query['activityOnly'] as bool,
    );
  }
}

class _AuditRepository implements AuditLogRepository {
  _AuditRepository({
    this.earlyAttempt = false,
    this.summaryCompleter,
    this.captureDate,
    this.totalPages = 1,
    this.includeRelatedDatabase = false,
    this.resultCode = 'success',
    this.resultLabel = '成功',
    this.primaryEntry,
    this.primaryDetail,
    this.emptySessions = false,
    this.sessionTotalPages = 1,
    this.rowsPerPage = 1,
  });

  final bool earlyAttempt;
  final Completer<AuditSummary>? summaryCompleter;
  final String? captureDate;
  final int totalPages;
  final bool includeRelatedDatabase;
  final String resultCode;
  final String resultLabel;
  final AuditLogEntry? primaryEntry;
  final AuditLogDetail? primaryDetail;
  final bool emptySessions;
  final int sessionTotalPages;
  final int rowsPerPage;
  Object? nextEventError;
  Object? nextSessionError;
  final sessionPageErrors = <int, List<Object>>{};
  final eventPageGates = <int, Completer<void>>{};
  final sessionPageGates = <int, Completer<void>>{};
  int highWaterMark = 9001;
  bool emptyCurrentEvents = false, emptyCurrentSessions = false;
  final firstEventOwners = <bool Function()?>[];
  final firstSessionOwners = <bool Function()?>[];
  String? readScopeVersion;
  int detailCalls = 0;
  int actorCalls = 0;
  String? lastRiskLevel;
  bool Function()? lastSummaryOwner;
  final listCalls = <Map<String, Object?>>[];
  final summaryCalls = <Map<String, Object?>>[];
  final detailIds = <int>[];
  final sessionCalls = <Map<String, Object?>>[];
  final sessionEventCalls = <Map<String, Object?>>[];

  static const actorId = '123e4567-e89b-42d3-a456-426614174099';
  static const sessionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

  @override
  Future<AuditSessionPage> sessions({
    required String actorId,
    required String dateFrom,
    required String dateTo,
    int page = 1,
    int size = 10,
    int? snapshotAuditId,
  }) async {
    sessionCalls.add({
      'actorId': actorId,
      'dateFrom': dateFrom,
      'dateTo': dateTo,
      'page': page,
      'size': size,
      'snapshotAuditId': snapshotAuditId,
    });
    if (page == 1) firstSessionOwners.add(PagedReadIntent.currentRead);
    final responseSnapshot = snapshotAuditId ?? highWaterMark;
    await sessionPageGates.remove(page)?.future;
    final pageErrors = sessionPageErrors[page];
    if (pageErrors != null && pageErrors.isNotEmpty) {
      throw pageErrors.removeAt(0);
    }
    if (nextSessionError case final failure?) {
      nextSessionError = null;
      throw failure;
    }
    final entry = primaryEntry;
    return AuditSessionPage(
      items: emptySessions || emptyCurrentSessions
          ? const []
          : [
              for (var index = 0; index < rowsPerPage; index++)
                AuditSessionSummary(
                  sessionId: rowsPerPage > 1
                      ? '$sessionId-$page-$index'
                      : page == 1
                      ? sessionId
                      : '$sessionId-$page',
                  actorId: _AuditRepository.actorId,
                  actorAccount: entry?.actorAccount ?? 'planner',
                  actorDisplay: entry?.actorDisplay ?? '计划员(planner)',
                  actorDepartment: entry?.actorDepartment ?? '生产部',
                  actorPosition: entry?.actorPosition ?? '计划专员',
                  startAction: 'login',
                  startLabel: '员工登录',
                  loginAt: captureDate == null
                      ? '2026-08-29T23:30:00Z'
                      : '${captureDate}T07:30:00+08:00',
                  firstActivityAt: captureDate == null
                      ? '2026-08-29T23:31:00Z'
                      : '${captureDate}T07:31:00+08:00',
                  lastActivityAt: captureDate == null
                      ? '2026-08-30T01:00:00Z'
                      : '${captureDate}T09:00:00+08:00',
                  logoutAt: captureDate == null
                      ? '2026-08-30T01:30:00Z'
                      : '${captureDate}T09:30:00+08:00',
                  status: 'logged_out',
                  statusLabel: '已退出',
                  operationCount: 2,
                  eventCount: 3,
                  successCount: 2,
                  failureCount: 1,
                  deviceLabel: '测试电脑',
                  devicePlatform: 'Windows',
                ),
            ],
      page: page,
      size: rowsPerPage,
      total: emptySessions || emptyCurrentSessions
          ? 0
          : sessionTotalPages * rowsPerPage,
      totalPages: emptySessions || emptyCurrentSessions ? 0 : sessionTotalPages,
      snapshotAuditId: responseSnapshot,
      readScopeVersion: readScopeVersion,
    );
  }

  @override
  Future<AuditSessionSummary> sessionSummary({
    required String sessionId,
    int? snapshotAuditId,
  }) async {
    final entry = primaryEntry;
    return AuditSessionSummary(
      sessionId: sessionId,
      actorId: actorId,
      actorAccount: entry?.actorAccount ?? 'planner',
      actorDisplay: entry?.actorDisplay ?? '计划员(planner)',
      actorDepartment: entry?.actorDepartment ?? '生产部',
      actorPosition: entry?.actorPosition ?? '计划专员',
      startAction: 'login',
      startLabel: '员工登录',
      loginAt: '2026-08-29T23:30:00Z',
      firstActivityAt: '2026-08-29T23:31:00Z',
      lastActivityAt: '2026-08-30T01:00:00Z',
      logoutAt: '2026-08-30T01:30:00Z',
      status: 'normal_logout',
      statusLabel: '正常退出',
      operationCount: 2,
      eventCount: 3,
      successCount: 2,
      failureCount: 1,
      deviceLabel: '测试电脑',
      devicePlatform: 'Windows',
      snapshotAuditId: snapshotAuditId ?? 9001,
    );
  }

  @override
  Future<AuditSessionEventPage> sessionEvents({
    required String sessionId,
    int size = 20,
    String? cursorAt,
    int? cursorId,
    int? snapshotAuditId,
  }) async {
    sessionEventCalls.add({
      'sessionId': sessionId,
      'size': size,
      'cursorAt': cursorAt,
      'cursorId': cursorId,
      'snapshotAuditId': snapshotAuditId,
    });
    final first =
        primaryEntry ??
        AuditLogEntry(
          id: 42,
          actorId: _AuditRepository.actorId,
          actorAccount: 'planner',
          actorName: '计划员',
          actorDisplay: '计划员(planner)',
          action: 'update',
          actionLabel: '修改',
          targetType: 'production_execution_segments',
          objectLabel: '生产执行分段',
          targetId: 'segment-1',
          targetName: '执行分段一',
          summary: '修改生产执行分段：状态由已就绪改为已下达',
          result: resultCode,
          resultLabel: resultLabel,
          statusCode: 200,
          createdAt: '2026-08-30T00:00:00Z',
        );
    return AuditSessionEventPage(
      items: [first],
      hasMore: false,
      snapshotAuditId: snapshotAuditId ?? 9001,
    );
  }

  @override
  Future<AuditActorPage> actors({
    int page = 1,
    int size = 20,
    String? keyword,
    String? departmentId,
    bool includeSubtree = false,
    String? actorType,
    bool unassignedOnly = false,
  }) async {
    actorCalls++;
    final entry = primaryEntry;
    return AuditActorPage(
      items: [
        AuditActorOption(
          actorId: _AuditRepository.actorId,
          account: entry?.actorAccount ?? 'planner',
          actorType: 'user',
          displayName: entry?.actorDisplay ?? '计划员(planner)',
          name: entry?.actorName ?? '计划员',
          departmentId: 'audit-production',
          department: entry?.actorDepartment ?? '生产部',
          position: entry?.actorPosition ?? '计划专员',
          lastActivityAt: '2026-07-31T06:00:00+08:00',
        ),
      ],
      page: 1,
      size: 20,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<AuditLogPage> list({
    int page = 1,
    int size = 20,
    String? action,
    String? actorId,
    String? actorAccount,
    String? keyword,
    String? targetType,
    String? targetId,
    String? eventSource,
    String? requestId,
    String? operationKind,
    String? actorScope,
    bool activityOnly = true,
    int? snapshotId,
    String? riskLevel,
    String? eventCategory,
    String? outcome,
    String? dateFrom,
    String? dateTo,
  }) async {
    lastRiskLevel = riskLevel;
    listCalls.add({
      'page': page,
      'size': size,
      'action': action,
      'actorId': actorId,
      'actorAccount': actorAccount,
      'keyword': keyword,
      'targetType': targetType,
      'targetId': targetId,
      'eventSource': eventSource,
      'requestId': requestId,
      'operationKind': operationKind,
      'actorScope': actorScope,
      'activityOnly': activityOnly,
      'snapshotId': snapshotId,
      'riskLevel': riskLevel,
      'eventCategory': eventCategory,
      'outcome': outcome,
      'dateFrom': dateFrom,
      'dateTo': dateTo,
    });
    if (page == 1) firstEventOwners.add(PagedReadIntent.currentRead);
    final responseSnapshot = snapshotId ?? highWaterMark;
    await eventPageGates.remove(page)?.future;
    if (nextEventError case final failure?) {
      nextEventError = null;
      throw failure;
    }
    final defaultEntry = AuditLogEntry(
      id: 41 + page,
      actorId: _AuditRepository.actorId,
      actorAccount: 'planner',
      actorName: '计划员',
      actorDisplay: '计划员(planner)',
      action: 'update',
      actionLabel: '修改',
      targetType: 'production_execution_segments',
      objectLabel: '生产执行分段',
      targetId: 'segment-1',
      targetName: '执行分段一',
      summary: '修改生产执行分段：状态由已就绪改为已下达',
      result: resultCode,
      resultLabel: resultLabel,
      statusCode: 200,
      createdAt: '2026-07-31T06:00:00+08:00',
    );
    final noEvents = actorScope == 'system' || emptyCurrentEvents;
    final items = noEvents
        ? <AuditLogEntry>[]
        : <AuditLogEntry>[
            if (rowsPerPage == 1)
              primaryEntry ?? defaultEntry
            else
              for (var index = 0; index < rowsPerPage; index++)
                AuditLogEntry(
                  id: page * 100 + index,
                  actorId: _AuditRepository.actorId,
                  actorDisplay: '分页操作员',
                  action: 'update',
                  actionLabel: '修改',
                  summary: '分页操作 $page-$index',
                  result: 'success',
                  resultLabel: '成功',
                  createdAt: '2026-07-31T06:00:00+08:00',
                ),
            if (includeRelatedDatabase && requestId != null && !activityOnly)
              const AuditLogEntry(
                id: 43,
                actorId: _AuditRepository.actorId,
                actorAccount: 'planner',
                actorName: '计划员',
                actorDisplay: '计划员(planner)',
                action: 'update',
                actionLabel: '修改',
                targetType: 'production_execution_segments',
                objectLabel: '生产执行分段',
                targetId: 'segment-2',
                targetName: '执行分段二',
                summary: '修改生产执行分段：状态由已就绪改为已下达',
                changeSummary: '状态：READY → DISPATCHED',
                result: 'success',
                resultLabel: '成功',
                eventSource: 'database',
                requestId: _DeviceStore.requestId,
                createdAt: '2026-07-31T06:00:00+08:00',
              ),
          ];
    return AuditLogPage(
      items: items,
      page: page,
      size: rowsPerPage,
      total: noEvents
          ? 0
          : totalPages * rowsPerPage +
                (includeRelatedDatabase && requestId != null && !activityOnly
                    ? 1
                    : 0),
      totalPages: noEvents ? 0 : totalPages,
      snapshotId: responseSnapshot,
      readScopeVersion: readScopeVersion,
    );
  }

  @override
  Future<AuditSummary> summary({
    String? action,
    String? actorId,
    String? actorAccount,
    String? keyword,
    String? targetType,
    String? targetId,
    String? eventSource,
    String? requestId,
    String? operationKind,
    String? actorScope,
    bool activityOnly = true,
    int? snapshotId,
    String? eventCategory,
    String? dateFrom,
    String? dateTo,
  }) async {
    lastSummaryOwner = PagedReadIntent.currentRead;
    summaryCalls.add({
      'action': action,
      'actorId': actorId,
      'actorAccount': actorAccount,
      'keyword': keyword,
      'targetType': targetType,
      'targetId': targetId,
      'eventSource': eventSource,
      'requestId': requestId,
      'operationKind': operationKind,
      'actorScope': actorScope,
      'activityOnly': activityOnly,
      'snapshotId': snapshotId,
      'eventCategory': eventCategory,
      'dateFrom': dateFrom,
      'dateTo': dateTo,
    });
    if (summaryCompleter != null) return summaryCompleter!.future;
    return const AuditSummary(
      total: 1,
      riskCount: 1,
      criticalCount: 0,
      failedCount: 0,
      dataChangeCount: 1,
      dailyTrend: [],
    );
  }

  @override
  Future<AuditLogDetail> detail(int id) async {
    detailCalls++;
    detailIds.add(id);
    final injectedDetail = primaryDetail;
    if (injectedDetail != null && injectedDetail.id == id) {
      return injectedDetail;
    }
    if (id == 43) {
      return const AuditLogDetail(
        id: 43,
        actorAccount: 'planner',
        action: 'update',
        targetType: 'production_execution_segments',
        targetId: 'segment-2',
        targetName: '执行分段二',
        actionLabel: '修改',
        objectLabel: '生产执行分段',
        summary: '修改生产执行分段：状态由已就绪改为已下达',
        resultLabel: '成功',
        changeSummary: '状态：READY → DISPATCHED',
        beforeJson: '{"status":"READY"}',
        afterJson: '{"status":"DISPATCHED"}',
        requestId: _DeviceStore.requestId,
        eventSource: 'database',
        result: 'success',
        createdAt: '2026-07-31T06:00:00+08:00',
      );
    }
    return AuditLogDetail(
      id: 42,
      actorAccount: 'planner',
      action: 'update',
      targetType: 'production_execution_segments',
      targetId: 'segment-1',
      actionLabel: '修改',
      objectLabel: '生产执行分段',
      summary: '修改生产执行分段：状态由已就绪改为已下达',
      resultLabel: resultLabel,
      changeSummary: '状态：READY → DISPATCHED',
      beforeJson: '{"status":"READY"}',
      afterJson: '{"status":"DISPATCHED"}',
      requestId: earlyAttempt
          ? _DeviceStore.earlyRequestId
          : _DeviceStore.requestId,
      clientEventId: _DeviceStore.eventId,
      device: const AuditDeviceEvidence(
        clientEventId: _DeviceStore.eventId,
        installationId: _DeviceStore.installationId,
        deviceName: '测试电脑',
        manufacturer: 'Uten',
        model: 'QA-1',
        platform: 'windows',
        osVersion: 'Windows Test',
        appVersion: '1.0.0',
        appBuild: 'test',
        formFactor: 'desktop',
        locale: 'zh_CN',
        timeZone: 'China Standard Time',
        timeZoneOffsetMinutes: 480,
        physicalDevice: true,
        clientEventAt: '2026-07-31T05:59:59+08:00',
        captureStatus: 'present',
        profileHash: 'device-profile-hash',
        clientDeclared: true,
      ),
      httpMethod: 'PATCH',
      httpPath: '/api/production/execution-segments/segment-1',
      statusCode: earlyAttempt ? 401 : 200,
      result: earlyAttempt ? 'failure' : resultCode,
      createdAt: '2026-07-31T06:00:00+08:00',
    );
  }
}

class _DeviceStore implements DeviceAuditStore {
  static const eventId = '123e4567-e89b-42d3-a456-426614174010';
  static const installationId = '123e4567-e89b-42d3-a456-426614174011';
  static const requestId = '123e4567-e89b-42d3-a456-426614174012';
  static const earlyRequestId = '123e4567-e89b-42d3-a456-426614174013';

  static const _profile = DeviceAuditProfile(
    installationId: installationId,
    deviceName: '测试电脑',
    manufacturer: 'Uten',
    model: 'QA-1',
    platform: 'windows',
    osVersion: 'Windows Test',
    appVersion: '1.0.0',
    appBuild: 'test',
    formFactor: 'desktop',
    locale: 'zh_CN',
    timeZone: 'China Standard Time',
    timeZoneOffsetMinutes: 480,
    isPhysicalDevice: true,
  );

  int profileCalls = 0;
  int findCalls = 0;

  @override
  Future<DeviceAuditProfile> profile() async {
    profileCalls++;
    return _profile;
  }

  @override
  Future<LocalAuditReceipt?> findReceipt(String clientEventId) async {
    findCalls++;
    if (clientEventId != eventId) return null;
    return const LocalAuditReceipt(
      clientEventId: eventId,
      installationId: installationId,
      method: 'PATCH',
      path: '/api/production/execution-segments/segment-1',
      startedAt: '2026-07-31T05:59:59+08:00',
      completedAt: '2026-07-31T06:00:00+08:00',
      statusCode: 200,
      serverRequestId: requestId,
      outcome: 'success',
      device: _profile,
      integrityVerified: true,
      previousAttempts: [
        LocalAuditAttempt(
          method: 'PATCH',
          path: '/api/production/execution-segments/segment-1',
          startedAt: '2026-07-31T05:59:59+08:00',
          completedAt: '2026-07-31T05:59:59.500+08:00',
          statusCode: 401,
          serverRequestId: earlyRequestId,
          outcome: 'failure',
        ),
      ],
    );
  }

  @override
  Future<void> beginReceipt({
    required String clientEventId,
    required String method,
    required String path,
    required DateTime startedAt,
    required DeviceAuditProfile device,
  }) async {}

  @override
  Future<void> completeReceipt({
    required String clientEventId,
    required String outcome,
    required DateTime completedAt,
    int? statusCode,
    String? serverRequestId,
  }) async {}

  @override
  Future<void> updateRetentionMonths(int months) async {}
}
