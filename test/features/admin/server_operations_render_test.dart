import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_inline_notice.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/admin/models/server_operations.dart';
import 'package:uten_imp/features/admin/models/server_storage.dart';
import 'package:uten_imp/features/admin/pages/server_operations_page.dart';
import 'package:uten_imp/features/admin/pages/server_storage_page.dart';
import 'package:uten_imp/features/admin/providers/server_operations_access.dart';
import 'package:uten_imp/features/admin/providers/server_storage_request_store.dart';
import 'package:uten_imp/features/admin/repositories/server_operations_repository.dart';
import 'package:uten_imp/features/admin/repositories/server_storage_repository.dart';
import 'package:uten_imp/features/admin/widgets/server_update_overview.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/audit_screenshot_support.dart';

void main() {
  for (final fixture in [
    ('1440-current', const Size(1440, 1000), 1.0, false),
    ('768-current', const Size(768, 1000), 1.0, false),
    ('375-current-dark-2x', const Size(375, 1000), 2.0, true),
    ('844-landscape-light-2x', const Size(844, 390), 2.0, false),
    ('1440-current-dark-2x', const Size(1440, 1100), 2.0, true),
    ('375-current-light-2x', const Size(375, 1000), 2.0, false),
    ('844-landscape-dark-2x', const Size(844, 390), 2.0, true),
  ]) {
    testWidgets(
      '${fixture.$1} full width current version with reachable actions',
      (tester) async {
        await loadAuditScreenshotFonts(tester);
        final key = GlobalKey();
        await _pump(
          tester,
          key,
          fixture.$4,
          const ServerOperationsPage(),
          size: fixture.$2,
          scale: fixture.$3,
          operations: _Operations(updateAvailable: false),
        );
        expect(find.text('v2.5.20'), findsNWidgets(2));
        final check = find.byKey(const ValueKey('server-update-start'));
        await tester.ensureVisible(check);
        await tester.pumpAndSettle();
        expect(tester.widget<UtenButton>(check).onPressed, isNotNull);
        final storage = find.text('存储管理');
        await tester.ensureVisible(storage);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // Capture the actual first viewport, rather than a stitched mockup.
        final scroll = find.byType(SingleChildScrollView).first;
        tester
            .state<ScrollableState>(
              find
                  .descendant(of: scroll, matching: find.byType(Scrollable))
                  .first,
            )
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        await _capture(tester, key, fixture.$1);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final state in [
    'QUEUED',
    'RUNNING',
    'SCHEDULED',
    'CANCELLED',
    'FAILED',
    'RECOVERY_REQUIRED',
    'SUCCEEDED',
  ]) {
    testWidgets(
      '$state diagnosis remains usable in a narrow large-text viewport',
      (tester) async {
        final job = <String, dynamic>{
          'id': 'safe-job-id',
          'requestId': 'safe-request-id',
          'actorId': 'operator',
          'mode': 'CHECK_AND_UPDATE',
          'state': state,
          'phase': state == 'RECOVERY_REQUIRED' ? 'MIGRATING' : 'CHECKING',
          'currentVersion': 'v2.5.20',
          'targetVersion': 'v2.5.21',
          'message':
              '<Error>raw provider credentials Authorization: Bearer PRIVATE</Error>',
          if (state == 'FAILED' || state == 'RECOVERY_REQUIRED')
            'failure': _failure(recovery: state == 'RECOVERY_REQUIRED'),
        };
        final key = GlobalKey();
        await _pump(
          tester,
          key,
          true,
          const ServerOperationsPage(),
          scale: 2,
          operations: _Operations(job: job),
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('server-update-job-state')),
        );
        await tester.pump();
        expect(find.textContaining('PRIVATE'), findsNothing);
        expect(find.textContaining('<Error>'), findsNothing);
        if (state == 'FAILED' || state == 'RECOVERY_REQUIRED') {
          final summary = find.byKey(
            const ValueKey('server-update-failure-summary'),
          );
          await tester.ensureVisible(summary);
          final details = find.text('失败详情');
          await tester.ensureVisible(details);
          await tester.tap(details);
          await tester.pump(const Duration(milliseconds: 400));
          final copy = find.byKey(
            const ValueKey('server-update-copy-diagnostics'),
          );
          await tester.ensureVisible(copy);
          await tester.pump();
          expect(copy, findsOneWidget);
          expect(find.textContaining('SOURCE_FORBIDDEN'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('safe failed job details actual desktop capture', (tester) async {
    await loadAuditScreenshotFonts(tester);
    final key = GlobalKey();
    await _pump(
      tester,
      key,
      false,
      const ServerOperationsPage(),
      operations: _Operations(
        job: {
          'id': 'safe-job-id',
          'requestId': 'safe-request-id',
          'state': 'FAILED',
          'phase': 'CHECKING',
          'mode': 'CHECK_ONLY',
          'failure': _failure(),
        },
      ),
    );
    final details = find.text('失败详情');
    await tester.ensureVisible(details);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('server-update-copy-diagnostics')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _capture(tester, key, 'failure-details-1440-light');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'legacy generic failure honestly reports missing diagnosis without revealing raw message',
    (tester) async {
      await _pump(
        tester,
        GlobalKey(),
        false,
        const ServerOperationsPage(),
        operations: _Operations(
          job: {
            'id': 'legacy-job',
            'requestId': 'legacy-request',
            'state': 'FAILED',
            'phase': 'UNKNOWN',
            'mode': 'CHECK_AND_UPDATE',
            'message': '<Error>Authorization: Bearer raw-secret</Error>',
          },
        ),
      );
      expect(find.textContaining('旧版本未记录可展示的失败详情'), findsOneWidget);
      expect(find.textContaining('raw-secret'), findsNothing);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('server-update-available')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final compact in [false, true]) {
    testWidgets(
      'unsupported platform uses an informational notice without update actions, compact=$compact',
      (tester) async {
        await loadAuditScreenshotFonts(tester);
        final key = GlobalKey();
        await _pump(
          tester,
          key,
          compact,
          const ServerOperationsPage(),
          scale: 2,
          operations: _Operations(
            available: false,
            failure: {
              'code': 'HOST_PLATFORM_UNSUPPORTED',
              'title': '当前平台不支持服务器运维助手',
              'reason': '服务器更新与存储清理助手仅支持 Linux，当前后端运行平台不支持此功能。',
              'suggestion': '本地开发环境可继续使用其他功能；正式部署请在 Linux 服务器安装并核验配套运维助手。',
            },
          ),
        );
        final notice = find.byKey(
          const ValueKey('server-update-platform-unsupported'),
        );
        expect(
          tester.widget<UtenInlineNotice>(notice).level,
          UtenInlineNoticeLevel.info,
        );
        expect(find.byKey(const ValueKey('server-update-start')), findsNothing);
        expect(
          find.byKey(const ValueKey('server-update-available')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('server-source-editor')),
          findsNothing,
        );
        expect(find.text('失败详情'), findsNothing);
        expect(find.textContaining('请安装'), findsNothing);
        expect(find.text('存储管理'), findsOneWidget);
        expect(find.text('查看数据库、附件登记与后端内存'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          key,
          'platform-unsupported-${compact ? '375-dark' : '1440-light'}-2x',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'unsupported platform keeps the original unknown request and job diagnosis visible',
    (tester) async {
      final status = await _Operations(
        available: false,
        failure: {
          'code': 'HOST_PLATFORM_UNSUPPORTED',
          'title': '当前环境不支持服务器在线运维',
          'reason': '当前环境不提供服务器在线更新与主机清理。',
        },
      ).status();
      final job = ServerUpdateJob.fromJson({
        'id': 'original-job-id',
        'requestId': 'original-request-id',
        'state': 'FAILED',
        'phase': 'CHECKING',
        'mode': 'CHECK_ONLY',
        'failure': _failure(),
      });
      final receipt = ServerUpdateJob.fromJson({
        'id': 'original-receipt-id',
        'requestId': 'original-receipt-request',
        'state': 'RUNNING',
        'phase': 'CHECKING',
      });
      await _pump(
        tester,
        GlobalKey(),
        true,
        Scaffold(
          body: SingleChildScrollView(
            child: ServerUpdateOverview(
              status: status,
              job: job,
              receipt: receipt,
              uncertainRequestId: 'original-unknown-request',
              loading: false,
              starting: false,
              writable: true,
              onCheck: () {},
              onReview: () {},
              onRefresh: () {},
              onCancel: null,
            ),
          ),
        ),
        scale: 2,
      );
      expect(find.textContaining('original-unknown-request'), findsOneWidget);
      expect(find.textContaining('original-receipt-request'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('server-update-original-receipt')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('server-update-failure-summary')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('server-update-start')), findsNothing);
      expect(
        find.byKey(const ValueKey('server-update-available')),
        findsNothing,
      );
      expect(
        tester
            .widget<UtenInlineNotice>(
              find.byKey(const ValueKey('server-update-platform-unsupported')),
            )
            .level,
        UtenInlineNoticeLevel.info,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenInlineNotice &&
              widget.level == UtenInlineNoticeLevel.warning,
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unavailable host shows curated diagnosis rather than guessing helper installation',
    (tester) async {
      await _pump(
        tester,
        GlobalKey(),
        false,
        const ServerOperationsPage(),
        operations: _Operations(
          available: false,
          failure: {
            'code': 'HOST_HELPER_UNAVAILABLE',
            'phase': 'CHECKING',
            'title': '更新助手响应需要核对',
            'reason': '暂未取得有效的本机更新状态。',
            'suggestion': '请维护人员检查本机更新助手。',
            'nextAction': 'CONTACT_ADMIN',
          },
        ),
      );
      expect(find.text('更新助手响应需要核对'), findsOneWidget);
      expect(
        tester
            .widget<UtenInlineNotice>(
              find.byKey(const ValueKey('server-update-unavailable')),
            )
            .level,
        UtenInlineNoticeLevel.warning,
      );
      expect(find.text('失败详情'), findsOneWidget);
      expect(find.textContaining('未安装'), findsNothing);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('server-update-start')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [const Size(1440, 1100), const Size(844, 390)]) {
    testWidgets(
      'source dialog surface is centered in safe keyboard canvas $size',
      (tester) async {
        await loadAuditScreenshotFonts(tester);
        final key = GlobalKey();
        await _pump(
          tester,
          key,
          false,
          const ServerOperationsPage(),
          size: size,
          scale: size.height < 500 ? 2 : 1,
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('server-source-editor')),
        );
        await tester.tap(find.byKey(const ValueKey('server-source-editor')));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 150);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await _capture(
          tester,
          key,
          'source-${size.width.toInt()}-initial-keyboard-surface',
        );
        final surfaces = find.descendant(
          of: find.byType(Dialog),
          matching: find.byWidgetPredicate(
            (widget) => widget is Material && widget.type == MaterialType.card,
          ),
        );
        expect(surfaces, findsOneWidget);
        final surface = tester.getRect(surfaces);
        final canvas = Rect.fromLTWH(0, 0, size.width, size.height - 150);
        // In short windows the shared shell scrolls the whole form. The visible
        // surface, not the full-height shell LayoutBuilder, is centered.
        final outerScroll = find.ancestor(
          of: surfaces,
          matching: find.byType(Scrollable),
        );
        final visible = surface
            .intersect(
              outerScroll.evaluate().isEmpty
                  ? canvas
                  : tester.getRect(outerScroll.first),
            )
            .intersect(canvas);
        expect(visible.center.dx, closeTo(canvas.center.dx, 1));
        expect(visible.center.dy, closeTo(canvas.center.dy, 1));
        final endpoint = find.byKey(const ValueKey('server-source-endpoint'));
        await tester.ensureVisible(endpoint);
        await tester.pumpAndSettle();
        expect(endpoint.hitTestable(), findsOneWidget);
        await _capture(
          tester,
          key,
          'source-${size.width.toInt()}-keyboard-input',
        );
        final save = find.byKey(const ValueKey('server-source-save'));
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        expect(save.hitTestable(), findsOneWidget);
        final close = find.byKey(const ValueKey('server-source-close'));
        await tester.ensureVisible(close);
        await tester.pumpAndSettle();
        expect(close.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          key,
          size.height < 500
              ? 'source-844-landscape-keyboard-2x'
              : 'source-1440-keyboard',
        );
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('open update appointment survives a narrow large-text resize', (
    tester,
  ) async {
    final scale = ValueNotifier<double>(1);
    addTearDown(scale.dispose);
    await _pump(
      tester,
      GlobalKey(),
      false,
      const ServerOperationsPage(),
      textScale: scale,
    );
    await tester.longPress(
      find.byKey(const ValueKey('server-operations-refresh')),
    );
    await tester.tap(find.byKey(const ValueKey('server-update-available')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('server-update-schedule')));
    await tester.pumpAndSettle();
    expect(find.text('预约服务器更新'), findsOneWidget);
    tester.view.physicalSize = const Size(260, 900);
    scale.value = 2;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('预约服务器更新'), findsOneWidget);
    expect(find.byKey(const ValueKey('server-schedule-hour')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('server-schedule-hour')),
    );
    await tester.pumpAndSettle();
    expect(find.text('02:00'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('server-schedule-hour')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('凌晨 03:00').last);
    await tester.pumpAndSettle();
    expect(find.text('03:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(1440, 1100);
    scale.value = 1;
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('预约服务器更新'), findsNothing);
    expect(find.byType(ServerOperationsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'storage action panel survives resize with resource details open',
    (tester) async {
      final scale = ValueNotifier<double>(1);
      addTearDown(scale.dispose);
      await _pump(
        tester,
        GlobalKey(),
        false,
        const ServerStoragePage(),
        textScale: scale,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('storage-category-LOGS')),
      );
      await tester.tap(find.byKey(const ValueKey('storage-category-LOGS')));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(375, 900);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('uten-app-bar-more-actions')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭操作面板'), findsOneWidget);
      tester.view.physicalSize = const Size(260, 900);
      scale.value = 2;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('关闭操作面板'), findsOneWidget);
      tester.view.physicalSize = const Size(1440, 1100);
      scale.value = 1;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('关闭操作面板'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('storage-category-LOGS')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final compact in [false, true]) {
    testWidgets(
      '${compact ? '375 dark large' : '1440 light'} server operations real render',
      (tester) async {
        await loadAuditScreenshotFonts(tester);
        final key = GlobalKey();
        await _pump(tester, key, compact, const ServerOperationsPage());
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          key,
          compact ? 'operations-375-dark-large' : 'operations-1440-light',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('server-update-available')),
        );
        await tester.tap(find.byKey(const ValueKey('server-update-available')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          key,
          compact ? 'discovery-375-dark-large' : 'discovery-1440-light',
        );
        await tester.tap(find.byKey(const ValueKey('server-update-schedule')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('server-schedule-confirm')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          key,
          compact ? 'schedule-375-dark-large' : 'schedule-1440-light',
        );
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('server-source-editor')),
        );
        await tester.tap(find.text('发布源与凭据'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('server-source-save')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          key,
          compact ? 'source-375-dark-large' : 'source-1440-light',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
    testWidgets(
      '${compact ? '375 dark large' : '1440 light'} storage real render',
      (tester) async {
        await loadAuditScreenshotFonts(tester);
        final key = GlobalKey();
        await _pump(tester, key, compact, const ServerStoragePage());
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          key,
          compact ? 'storage-375-dark-large' : 'storage-1440-light',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('storage-category-LOGS')),
        );
        await tester.tap(find.byKey(const ValueKey('storage-category-LOGS')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('正在使用的日志文件'));
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          key,
          compact ? 'resources-375-dark-large' : 'resources-1440-light',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (Platform.environment['UTEN_UI_FIXTURES'] != '1') return;
  await saveAuditScreenshot(tester, key, 'server-settings-$name');
}

Future<void> _pump(
  WidgetTester tester,
  GlobalKey key,
  bool compact,
  Widget page, {
  ValueNotifier<double>? textScale,
  Size? size,
  double? scale,
  ServerOperationsRepository? operations,
}) async {
  tester.view.physicalSize =
      size ?? (compact ? const Size(375, 1000) : const Size(1440, 1100));
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        serverStorageRequestOwnerProvider.overrideWithValue('company/operator'),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'operator'),
        ),
        isSuperAdminProvider.overrideWithValue(true),
        serverOperationsOwnerProvider.overrideWithValue('company/operator'),
        serverOperationsVisibleProvider.overrideWithValue(true),
        serverOperationsWritableProvider.overrideWithValue(true),
        serverSourceVisibleProvider.overrideWithValue(true),
        serverOperationsRepositoryProvider.overrideWithValue(
          operations ?? _Operations(),
        ),
        serverStorageRepositoryProvider.overrideWithValue(_Storage()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: auditScreenshotTheme(
          compact ? buildDarkTheme() : buildLightTheme(),
        ),
        builder: (context, child) => ValueListenableBuilder<double>(
          valueListenable:
              textScale ?? AlwaysStoppedAnimation(scale ?? (compact ? 1.4 : 1)),
          builder: (context, scale, _) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: key, child: child!),
          ),
        ),
        home: page,
      ),
    ),
  );
  if (operations is _Operations &&
      const [
        'RUNNING',
        'QUEUED',
      ].contains(operations.latestJobJson?['state'])) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  } else {
    await tester.pumpAndSettle();
  }
}

class _Operations implements ServerOperationsRepository {
  _Operations({
    this.updateAvailable = true,
    this.available = true,
    this.failure,
    Map<String, dynamic>? job,
  }) : latestJobJson = job;
  final bool updateAvailable;
  final bool available;
  final Map<String, dynamic>? failure;
  final Map<String, dynamic>? latestJobJson;
  @override
  Future<ServerOperationsStatus> status() async =>
      ServerOperationsStatus.fromJson({
        'available': available,
        'failure': failure,
        'manualOnly': true,
        'timerActive': false,
        'currentVersion': 'v2.5.20',
        'sourceRevision': 'configured-r1',
        'sourceConfigured': true,
        'latestVersion': updateAvailable ? 'v2.5.21' : 'v2.5.20',
        'updateAvailable': updateAvailable,
        'latestJob': latestJobJson,
        'lastCheckedAt': '2026-10-15T12:30:00Z',
        'serverTimeZone': 'Asia/Shanghai',
        'serverTime': '2026-10-15T20:35:00+08:00',
        'canUpdate': true,
        'canCleanup': true,
        'canConfigureSource': true,
      });
  @override
  Future<ServerUpdateSource> source() async => ServerUpdateSource.fromJson({
    'revision': 'configured-r1',
    'endpoint': 'oss-cn-hangzhou.aliyuncs.com',
    'bucket': 'company-release',
    'objectPrefix': 'uten-imp/releases',
    'accessKeyConfigured': true,
    'accessKeyIdHint': '••••7f21',
    'signingPublicKey': '公钥保存在此公司服务器，仅用于验证正式发布签名。',
    'signingKeyFingerprint': 'SHA256: 5b82…e91c',
    'applied': true,
  });
  @override
  Future<ServerUpdateSchedulePreview> schedulePreview({
    required String localDate,
    required int hour,
  }) async => ServerUpdateSchedulePreview.fromJson({
    'scheduledAt': '2026-10-15T18:00:00Z',
    'serverTimeZone': 'Asia/Shanghai',
    'displayLocalTime': '2026-10-16 02:00',
  });
  @override
  Future<ServerUpdateJob> startUpdate({
    required String requestId,
    required String expectedSourceRevision,
    required String expectedCurrentVersion,
    String mode = 'CHECK_ONLY',
    String? targetVersion,
    String? scheduledAt,
  }) => throw UnimplementedError();
  @override
  Future<ServerUpdateJob> cancel(String jobId, {required String requestId}) =>
      throw UnimplementedError();
  @override
  Future<ServerUpdateJob> job(String id) => throw UnimplementedError();
  @override
  Future<ServerUpdateJob?> latestJob() async => null;
  @override
  Future<ServerUpdateSource> saveSource(Map<String, dynamic> command) =>
      throw UnimplementedError();
}

Map<String, dynamic> _failure({bool recovery = false}) => {
  'code': 'SOURCE_FORBIDDEN',
  'phase': 'CHECKING',
  'title': '发布源拒绝访问',
  'reason': '服务器无法读取正式发布文件。',
  'suggestion': recovery
      ? '联系维护人员核查恢复点，完成恢复前不要再次更新。'
      : '请超级管理员核对发布源读取权限，再手动检查。',
  'retrySafe': !recovery,
  'recoveryRequired': recovery,
  'originalServicePreserved': !recovery,
  'nextAction': recovery ? 'VERIFY_RECOVERY' : 'CHECK_SOURCE',
};

class _Storage implements ServerStorageRepository {
  @override
  Future<ServerStorageSummary> summary() async =>
      ServerStorageSummary.fromJson({
        'sampledAt': '2026-10-15T12:35:00Z',
        'revision': 'inventory-r1',
        'status': 'NORMAL',
        'capabilities': {'available': true, 'canCleanup': true},
        'process': {
          'rssBytes': 335544320,
          'heapUsedBytes': 134217728,
          'heapMaxBytes': 536870912,
          'detail': '常驻内存包含 Java 堆、线程和本地内存；Java 堆另列。',
        },
        'database': {'sizeBytes': 989855744, 'status': 'NORMAL'},
        'uploads': {
          'count': 1832,
          'logicalBytes': 1430257664,
          'storedBytes': 1363148800,
          'status': 'NORMAL',
          'detail': '附件登记量包含保留历史，与去重后的磁盘占用分别计量。',
        },
        'volumes': [
          {
            'id': 'data',
            'label': '数据卷',
            'totalBytes': 107374182400,
            'usedBytes': 37580963840,
            'freeBytes': 69793218560,
          },
        ],
        'categories': [
          for (final row in [
            ('DATABASE', '数据库', 989855744),
            ('UPLOADS', '当前上传目录', 1363148800),
            ('LEGACY_UPLOADS', '兼容旧上传目录', 268435456),
            ('PAIRED_BACKUPS', '配套恢复备份', 2147483648),
            ('RELEASES', '发布版本', 734003200),
            ('RELEASE_STAGING', '未完成的下载', 104857600),
            ('LOGS', '运行日志', 52428800),
          ])
            {
              'kind': row.$1,
              'label': row.$2,
              'status': 'NORMAL',
              'logicalBytes': row.$3,
              'allocatedBytes': row.$3,
              'reclaimableBytes': row.$1 == 'LOGS' ? 20971520 : 0,
              'count': row.$1 == 'UPLOADS' ? 1832 : 3,
              'canList': true,
              'detail': row.$1 == 'LEGACY_UPLOADS'
                  ? '兼容旧上传原件永不清理。同卷或目录重叠时不能直接相加。'
                  : '当前版本、有效恢复点和受业务引用的资源始终保留。',
            },
        ],
      });
  @override
  Future<ServerStorageResources> resources(
    String kind, {
    String? cursor,
  }) async => ServerStorageResources.fromJson({
    'sampledAt': '2026-10-15T12:35:00Z',
    'revision': 'inventory-r1',
    'kind': kind,
    'total': 2,
    'items': [
      {
        'id': 'closed-log',
        'label': '超过保留期的已闭合日志',
        'kind': 'LOGS',
        'logicalBytes': 20971520,
        'allocatedBytes': 20971520,
        'reclaimableBytes': 20971520,
        'canDelete': true,
        'modifiedAt': '2026-10-01T02:00:00Z',
        'protectionReasons': <String>[],
      },
      {
        'id': 'open-log',
        'label': '正在使用的日志文件',
        'kind': 'LOGS',
        'logicalBytes': 1048576,
        'allocatedBytes': 1048576,
        'reclaimableBytes': 0,
        'canDelete': false,
        'protectionReasons': ['文件仍由运行中的服务使用，不能删除。'],
      },
    ],
  });
  @override
  Future<ServerStoragePreview> preview(List<String> resourceIds) =>
      throw UnimplementedError();
  @override
  Future<ServerStorageCleanupReceipt> cleanup({
    required String previewId,
    required String requestId,
  }) => throw UnimplementedError();
  @override
  Future<ServerStorageCleanupReceipt> receipt(String requestId) =>
      throw UnimplementedError();
}
