import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
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
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/audit_screenshot_support.dart';

void main() {
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
}) async {
  tester.view.physicalSize = compact
      ? const Size(375, 1000)
      : const Size(1440, 1100);
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
        serverOperationsRepositoryProvider.overrideWithValue(_Operations()),
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
              textScale ?? AlwaysStoppedAnimation(compact ? 1.4 : 1),
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
  await tester.pumpAndSettle();
}

class _Operations implements ServerOperationsRepository {
  @override
  Future<ServerOperationsStatus> status() async =>
      ServerOperationsStatus.fromJson({
        'available': true,
        'manualOnly': true,
        'timerActive': false,
        'currentVersion': 'v2.5.17',
        'sourceRevision': 'configured-r1',
        'sourceConfigured': true,
        'latestVersion': 'v2.5.18',
        'updateAvailable': true,
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
