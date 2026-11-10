import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_gauge_ring.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/components/feedback/uten_live_pulse_dot.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/layout/uten_collapsible_section.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/admin/models/server_status.dart';
import 'package:uten_imp/features/admin/models/server_storage.dart';
import 'package:uten_imp/features/admin/pages/server_status_page.dart';
import 'package:uten_imp/features/admin/providers/server_status_snapshot_cache.dart';
import 'package:uten_imp/features/admin/repositories/server_status_repository.dart';
import 'package:uten_imp/features/admin/repositories/server_storage_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/dashboard/providers/workbench_layout_provider.dart';
import 'package:uten_imp/features/dashboard/widgets/workbench_module_area.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';

import '../../helpers/badge_summary_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sampledAt = DateTime.utc(2026, 9, 8, 12);

  testWidgets(
    'background retirement releases the pending status owner and resumes without its result',
    (tester) async {
      final first = Completer<ServerStatusSnapshot>();
      bool Function()? firstOwner;
      var calls = 0;
      final repository = _Repository(() {
        if (++calls == 1) {
          firstOwner = PagedReadIntent.currentRead;
          return first.future;
        }
        return Future.value(_sample(sampledAt.add(const Duration(seconds: 1))));
      });
      final container = await _pump(tester, repository, settle: false);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(firstOwner?.call(), isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, 2);
      first.complete(_sample(sampledAt));
      await tester.pumpAndSettle();
      expect(
        container.read(serverStatusSnapshotCacheProvider)!.sampledAt,
        sampledAt.add(const Duration(seconds: 1)),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  setUpAll(() async {
    final loader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await loader.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final interaction in ['hover', 'tap']) {
    testWidgets(
      'overview guidance opens by $interaction without hiding current alerts',
      (tester) async {
        await withClock(Clock.fixed(sampledAt), () async {
          await _pump(tester, _Repository(() async => _sample(sampledAt)));
          await tester.pumpAndSettle();
          expect(find.text('根据服务器最近一次采集的数据展示运行情况。'), findsNothing);
          expect(find.text('每 15 秒自动刷新，离开页面后暂停'), findsNothing);
          expect(
            find.byKey(const Key('server-status-freshness')),
            findsNothing,
          );
          expect(_hintContaining('尚未接入备份结果'), findsOneWidget);
          final help = find.byWidgetPredicate(
            (widget) =>
                widget is UtenFieldHintIcon &&
                (widget.info?.contains('根据服务器最近一次采集的数据展示运行情况。') ?? false),
          );
          final message = tester.widget<UtenFieldHintIcon>(help).info!;
          if (interaction == 'hover') {
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: const Offset(1400, 1400));
            await mouse.moveTo(tester.getCenter(help));
            await tester.pump(const Duration(milliseconds: 300));
            await tester.pumpAndSettle();
            expect(find.text(message), findsOneWidget);
            await mouse.removePointer();
          } else {
            await tester.tap(help);
            await tester.pumpAndSettle();
            expect(find.text(message), findsOneWidget);
          }
          expect(_hintContaining('尚未接入备份结果'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      },
    );
  }

  test(
    'unknown capacity stays null and stale samples are not current health',
    () {
      final snapshot = ServerStatusSnapshot.fromJson({
        'sampledAt': sampledAt.toIso8601String(),
        'status': 'NORMAL',
        'refreshAfterSeconds': 15,
        'metrics': [
          {'key': 'cpu', 'value': 0, 'unit': 'PERCENT', 'status': 'NORMAL'},
          {
            'key': 'memory',
            'value': null,
            'unit': 'PERCENT',
            'status': 'UNKNOWN',
          },
        ],
      });
      expect(snapshot.metrics.first.value, 0);
      expect(snapshot.metrics.last.value, isNull);
      expect(snapshot.metrics.last.totalBytes, isNull);
      expect(snapshot.database.connections, isNull);
      expect(snapshot.backup.lastSuccessAt, isNull);
      expect(
        snapshot.isStale(sampledAt.add(const Duration(seconds: 29))),
        isFalse,
      );
      expect(
        snapshot.isStale(sampledAt.add(const Duration(seconds: 31))),
        isTrue,
      );
    },
  );

  for (final compact in [false, true]) {
    testWidgets(
      '${compact ? "compact dark" : "desktop light"} shows actual measurements and unknown reasons without overflow',
      (tester) async {
        await withClock(Clock.fixed(sampledAt), () async {
          final repository = _Repository(() async => _sample(sampledAt));
          await _pump(tester, repository, compact: compact);
          await tester.pumpAndSettle();
          final memory = find.byKey(const Key('server-metric-memory'));
          final pool = find.byKey(const Key('server-metric-db_pool'));
          expect(
            find.descendant(of: memory, matching: find.text('85')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: memory, matching: find.text('32 GiB')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: pool, matching: find.text('—')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: pool,
              matching: find.byType(LinearProgressIndicator),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: pool,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is UtenFieldHintIcon &&
                    (widget.info?.contains('连接池暂不提供数据') ?? false),
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is UtenFieldHintIcon &&
                  (widget.info?.contains('尚未接入备份结果') ?? false),
            ),
            findsOneWidget,
          );
          expect(find.text('需处理'), findsWidgets);
          expect(find.text('留意'), findsWidgets);
          expect(find.text('重启'), findsNothing);
          expect(repository.calls, 1);
          expect(tester.takeException(), isNull);
          await _capture(
            tester,
            compact ? 'compact-dark-fixture.png' : 'desktop-light-fixture.png',
          );
          await tester.pumpWidget(const SizedBox.shrink());
        });
      },
    );
  }

  testWidgets(
    'view permission is independent from system administration and prevents any unauthorized request',
    (tester) async {
      expect(requiredAnyPermFor(RouteName.adminServerStatus), [
        Perm.serverStatusView,
        Perm.serverUpdate,
        Perm.serverCleanup,
      ]);
      expect(
        requiredAnyPermFor('${RouteName.adminServerStatus}?from=dashboard'),
        [Perm.serverStatusView, Perm.serverUpdate, Perm.serverCleanup],
        // Delegated operators can view local state without authorization:manage.
      );
      final repository = _Repository(() async => _sample(sampledAt));
      await _pump(tester, repository, permissions: {Perm.authorizationManage});
      await tester.pumpAndSettle();
      expect(find.text('没有服务器状态查看权限'), findsOneWidget);
      expect(repository.calls, 0);
      await tester.pump(const Duration(seconds: 45));
      expect(repository.calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final layout in [
    (width: 1800.0, scale: 1.0, columns: 3),
    (width: 900.0, scale: 1.0, columns: 2),
    (width: 390.0, scale: 1.35, columns: 1),
    (width: 320.0, scale: 2.0, columns: 1),
  ]) {
    testWidgets(
      'storage accounting adapts at ${layout.width}, text ${layout.scale}',
      (tester) async {
        await withClock(Clock.fixed(sampledAt), () async {
          final repository = _Repository(() async => _sample(sampledAt));
          await _pump(
            tester,
            repository,
            size: Size(layout.width, 1600),
            textScale: layout.scale,
            storage: _StorageRepository(() async => _accountingStorage()),
          );
          final data = find.byKey(const Key('server-storage-zone-data'));
          final media = find.byKey(const Key('server-storage-zone-media'));
          final system = find.byKey(const Key('server-storage-zone-system'));
          final first = tester.getRect(data);
          final second = tester.getRect(media);
          final third = tester.getRect(system);
          if (layout.columns > 1) {
            expect(first.top, second.top);
            expect(second.left, greaterThan(first.right));
          } else {
            expect(first.left, second.left);
            expect(second.top, greaterThan(first.bottom));
          }
          if (layout.columns == 3) {
            expect(third.top, first.top);
            expect(third.left, greaterThan(second.right));
          }
          expect(first.width, lessThanOrEqualTo(layout.width));
          final details = find.descendant(
            of: data,
            matching: find.byType(UtenCollapsibleSection),
          );
          expect(
            tester.widget<UtenCollapsibleSection>(details).expanded,
            isFalse,
          );
          expect(
            find.descendant(of: data, matching: find.text('展开明细')),
            findsOneWidget,
          );
          await tester.ensureVisible(data);
          await tester.pumpAndSettle();
          await _capture(
            tester,
            'storage-collapsed-${layout.width.toInt()}.png',
          );
          await _toggleStorageDetails(tester, data, expand: true);
          expect(tester.getSize(data).height, greaterThan(first.height));
          expect(
            tester
                .widget<UtenCollapsibleSection>(
                  find.descendant(
                    of: media,
                    matching: find.byType(UtenCollapsibleSection),
                  ),
                )
                .expanded,
            isFalse,
          );
          expect(repository.calls, 1);
          expect(
            find.descendant(of: data, matching: find.text('8 KiB')),
            findsNWidgets(2),
          );
          expect(
            find.descendant(of: data, matching: find.text('1016 KiB')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: data, matching: find.text('0 B')),
            findsOneWidget,
          );
          expect(find.text('重复统计（已扣除）'), findsOneWidget);
          expect(find.text('400.3 KiB'), findsNothing);
          expect(find.text('409939'), findsNothing);
          expect(_hintContaining('未定位到存储卷'), findsOneWidget);
          expect(
            find.descendant(of: data, matching: find.text('—')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(data);
          await tester.pumpAndSettle();
          await _capture(
            tester,
            'storage-accounting-${layout.width.toInt()}.png',
          );
          await tester.pump(const Duration(seconds: 15));
          await tester.pumpAndSettle();
          expect(
            tester.widget<UtenCollapsibleSection>(details).expanded,
            isTrue,
          );
          final readCalls = repository.calls;
          tester.view.physicalSize = Size(
            layout.width > 1000 ? 390 : 1800,
            1600,
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<UtenCollapsibleSection>(details).expanded,
            isTrue,
          );
          for (var repeat = 0; repeat < 3; repeat++) {
            await _toggleStorageDetails(tester, data, expand: false);
            expect(
              tester.widget<UtenCollapsibleSection>(details).expanded,
              isFalse,
            );
            await _toggleStorageDetails(tester, data, expand: true);
          }
          await _toggleStorageDetails(tester, data, expand: false);
          expect(repository.calls, readCalls);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      },
    );
  }

  testWidgets(
    'manual refresh waits for storage, bypasses cache and guards repeated clicks',
    (tester) async {
      await withClock(Clock.fixed(sampledAt), () async {
        var storageCalls = 0;
        final storageRead = Completer<ServerStorageSummary>();
        final statusRead = Completer<ServerStatusSnapshot>();
        final repository = _Repository(() async => _sample(sampledAt));
        await _pump(
          tester,
          repository,
          storage: _StorageRepository(() async {
            storageCalls++;
            return storageCalls == 1
                ? _accountingStorage()
                : storageRead.future;
          }),
        );
        repository.handler = () => statusRead.future;
        final refresh = find.byKey(const Key('server-status-refresh'));
        final callback = tester
            .widget<UtenAppBarActionButton>(refresh)
            .onPressed!;
        await tester.tap(refresh);
        await tester.pump();
        expect(find.byType(UtenBusyOverlay), findsWidgets);
        expect(repository.calls, 2);
        // The request has started; direct repeated callbacks are guarded as well.
        await callback();
        expect(repository.calls, 2);
        statusRead.complete(_sample(sampledAt));
        await tester.pump();
        await tester.pump();
        expect(storageCalls, 2);
        expect(find.byType(UtenBusyOverlay), findsWidgets);
        storageRead.complete(_accountingStorage());
        await tester.pumpAndSettle();
        expect(find.byType(UtenBusyOverlay), findsNothing);
        expect(repository.peak, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'compact refresh joins the read resumed while closing its actions panel',
    (tester) async {
      await withClock(Clock.fixed(sampledAt), () async {
        final statusRead = Completer<ServerStatusSnapshot>();
        final storageRead = Completer<ServerStorageSummary>();
        var storageCalls = 0;
        final repository = _Repository(() async => _sample(sampledAt));
        await _pump(
          tester,
          repository,
          compact: true,
          storage: _StorageRepository(
            () async =>
                ++storageCalls == 1 ? _accountingStorage() : storageRead.future,
          ),
        );
        repository.handler = () => statusRead.future;
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('刷新').hitTestable());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byTooltip('关闭操作面板'), findsNothing);
        expect(find.byType(UtenBusyOverlay), findsWidgets);
        expect(repository.calls, 2);
        statusRead.complete(_sample(sampledAt));
        await tester.pump();
        await tester.pump();
        expect(storageCalls, 2);
        expect(find.byType(UtenBusyOverlay), findsWidgets);
        storageRead.complete(_accountingStorage());
        await tester.pumpAndSettle();
        expect(find.byType(UtenBusyOverlay), findsNothing);
        expect(repository.peak, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );

  testWidgets('zero pool usage retains its measured connection counts', (
    tester,
  ) async {
    await withClock(Clock.fixed(sampledAt), () async {
      final json = _json(sampledAt);
      final metrics = (json['metrics'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      metrics.removeWhere((row) => row['key'] == 'db_pool');
      metrics.add({
        'key': 'db_pool',
        'label': '数据库连接池',
        'value': 0,
        'unit': 'PERCENT',
        'status': 'NORMAL',
        'activeConnections': 0,
        'maxConnections': 50,
        'idleConnections': 10,
        'waitingThreads': 0,
        'detail': '采样时没有正在使用的连接，空闲连接仍可用。',
      });
      json['metrics'] = metrics;
      await _pump(
        tester,
        _Repository(() async => ServerStatusSnapshot.fromJson(json)),
      );
      final pool = find.byKey(const Key('server-metric-db_pool'));
      expect(
        find.descendant(of: pool, matching: find.text('0 个')),
        findsNWidgets(2),
      );
      expect(
        find.descendant(of: pool, matching: find.text('50 个')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: pool, matching: find.text('10 个')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('failed storage refresh withdraws the old inventory', (
    tester,
  ) async {
    await withClock(Clock.fixed(sampledAt), () async {
      var calls = 0;
      await _pump(
        tester,
        _Repository(() async => _sample(sampledAt)),
        storage: _StorageRepository(() async {
          if (++calls == 1) return _accountingStorage();
          throw NetworkException();
        }),
      );
      expect(find.byKey(const Key('server-storage-zone-data')), findsOneWidget);
      await tester.tap(find.byKey(const Key('server-status-refresh')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byKey(const Key('server-storage-zone-data')), findsNothing);
      expect(
        find.byKey(Key('server-disk-${_sample(sampledAt).disks.first.key}')),
        findsOneWidget,
      );
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('storage section groups volumes by where content is stored', (
    tester,
  ) async {
    await withClock(Clock.fixed(sampledAt), () async {
      final repository = _Repository(() async => _sample(sampledAt));
      // 2026-11-10 迁移后的实际布局：备份并入 /data；上传附件在独立媒体卷。
      final storage = _StorageRepository(
        () async => ServerStorageSummary.fromJson({
          'revision': 'r1',
          'status': 'NORMAL',
          'capabilities': {'available': true, 'canCleanup': false},
          'volumes': [
            {
              'id': 'v-data',
              'label': '存储卷 1',
              'mount': '/data',
              'totalBytes': 1800000000000,
              'usedBytes': 208000000000,
              'freeBytes': 1592000000000,
            },
            {
              'id': 'v-media',
              'label': '存储卷 2',
              'mount': '/var/lib/uten-imp-media',
              'totalBytes': 200000000000,
              'usedBytes': 389000000,
              'freeBytes': 199611000000,
            },
          ],
          'categories': [
            {
              'kind': 'DATABASE',
              'label': '数据库目录',
              'status': 'NORMAL',
              'logicalBytes': 19000000000,
              'allocatedBytes': 19000000000,
              'volumeId': 'v-data',
            },
            {
              'kind': 'PAIRED_BACKUPS',
              'label': '数据库与上传文件配套备份',
              'status': 'NORMAL',
              'logicalBytes': 165000000000,
              'allocatedBytes': 165000000000,
              'volumeId': 'v-data',
            },
            {
              // 覆盖整个系统根的概览类不进分区明细。
              'kind': 'SYSTEM',
              'label': '系统目录',
              'status': 'NORMAL',
              'logicalBytes': 33000000000,
              'volumeId': 'v-data',
            },
            {
              'kind': 'UPLOADS',
              'label': '当前上传目录',
              'status': 'NORMAL',
              'logicalBytes': 389000000,
              'allocatedBytes': 389000000,
              'volumeId': 'v-media',
            },
          ],
        }),
      );
      await _pump(tester, repository, storage: storage);
      await tester.pumpAndSettle();
      // 分区名按挂载点落位，不露「存储卷 1」这类泛称。
      expect(find.text('数据库与备份区'), findsOneWidget);
      expect(find.text('上传文件区'), findsOneWidget);
      expect(find.text('存储卷 1'), findsNothing);
      // 剩余量与占用明细按通俗单位展示。
      expect(find.text('剩余 1.4 TiB'), findsOneWidget);
      expect(find.text('剩余 185.9 GiB'), findsOneWidget);
      await _toggleStorageDetails(
        tester,
        find.byKey(const Key('server-storage-zone-v-data')),
        expand: true,
      );
      await _toggleStorageDetails(
        tester,
        find.byKey(const Key('server-storage-zone-v-media')),
        expand: true,
      );
      expect(find.text('配套备份（数据库＋附件）'), findsOneWidget);
      expect(find.text('153.7 GiB'), findsOneWidget);
      expect(find.text('上传的附件'), findsOneWidget);
      expect(find.text('371.0 MiB'), findsOneWidget);
      // SYSTEM 概览类与数据库卷里的重叠，不单独占一行。
      expect(find.text('系统目录'), findsNothing);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'storage-zones-fixture.png');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets(
    'overall unknown preserves fresh metric states and backup check failure wording',
    (tester) async {
      await withClock(Clock.fixed(sampledAt), () async {
        final data = _sample(sampledAt);
        final repository = _Repository(
          () async => ServerStatusSnapshot(
            status: ServerHealthStatus.unknown,
            sampledAt: data.sampledAt,
            refreshAfterSeconds: 15,
            environment: data.environment,
            applicationVersion: data.applicationVersion,
            uptimeSeconds: data.uptimeSeconds,
            metrics: data.metrics,
            disks: data.disks,
            database: data.database,
            alerts: const [],
            backup: const ServerBackup(
              status: ServerHealthStatus.warning,
              lastSuccessAt: null,
              ageHours: null,
              warningAfterHours: 30,
              criticalAfterHours: 48,
              detail: '检查未通过',
            ),
          ),
        );
        await _pump(tester, repository);
        final cpu = find.byKey(const Key('server-metric-cpu'));
        final backup = find.byKey(const Key('server-backup'));
        expect(
          find.descendant(of: cpu, matching: find.text('正常')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: backup, matching: find.text('留意')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: backup, matching: _hintContaining('检查未通过')),
          findsOneWidget,
        );
        expect(find.text('备份失败'), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('server-status-overall')),
            matching: find.text('未知'),
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );

  testWidgets(
    'system management shows the status card only to its viewer and opens the page',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = _Repository(() async => _sample(clock.now()));
      final router = GoRouter(
        initialLocation: '/dashboard',
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (_, _) => const Scaffold(
              body: SingleChildScrollView(child: WorkbenchModuleArea()),
            ),
          ),
          GoRoute(
            path: RouteName.adminServerStatus,
            builder: (_, _) => const ServerStatusPage(),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            currentPermissionsProvider.overrideWithValue({
              Perm.serverStatusView,
            }),
            isSuperAdminProvider.overrideWithValue(false),
            workbenchLayoutProvider.overrideWith(_Layout.new),
            serverStatusRepositoryProvider.overrideWithValue(repository),
            serverStorageRepositoryProvider.overrideWithValue(
              _StorageRepository(
                () async => ServerStorageSummary.fromJson(const {
                  'capabilities': {'available': false},
                }),
              ),
            ),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('系统管理'), findsOneWidget);
      expect(find.text('服务器状态'), findsOneWidget);
      // 「服务器更新」卡 2026-10-22 退役：更新入口并入服务器状态页。
      expect(find.text('服务器更新'), findsNothing);
      expect(find.text('权限管理'), findsNothing);
      expect(find.text('系统设置'), findsNothing);
      await tester.tap(find.text('服务器状态'));
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        RouteName.adminServerStatus,
      );
      expect(find.byType(ServerStatusPage), findsOneWidget);
      // 1 次 = 页面自己拉一次。工作台那张卡的告警徽章(2026-09-11 新增)自 2026-09-23 起
      // 随徽章汇总带回(ADR-108), 不再单独请求这个端点; 数字钉死在 1, 谁再加一个轮询源
      // 会立刻被这里拦下。
      expect(repository.calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  // 2026-10-22：「服务器更新」卡从工作台退役后，服务器状态页内的更新按钮是
  // 常驻入口；待更新版本数（徽章汇总 serverOperations.updates，只对有更新权限
  // 的人有数）直接标在按钮上，不点进去也知道该更新了。
  testWidgets('服务器更新按钮按待更新数显示徽章，无数时不占位', (tester) async {
    await withClock(Clock.fixed(sampledAt), () async {
      final repository = _Repository(() async => _sample(sampledAt));
      final container = await _pump(
        tester,
        repository,
        badgeSummary: badgeSummaryFixture(
          entries: {BadgeEntry.serverUpdateAvailable: (2, 0)},
        ),
      );
      expect(
        tester
            .widget<UtenNotificationBadge>(
              find.byKey(const Key('server-update-pending-badge')),
            )
            .count,
        2,
      );
      // 没有待更新版本时按钮回到纯文字，不渲染徽章(同一作用域推一份空汇总)。
      (container.read(badgeSummaryProvider.notifier)
              as FixedBadgeSummaryNotifier)
          .emit(badgeSummaryFixture());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('server-update-pending-badge')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets(
    'slow reads never overlap and polling pauses off-route, in background and after disposal',
    (tester) async {
      var now = sampledAt;
      await withClock(Clock(() => now), () async {
        final first = Completer<ServerStatusSnapshot>();
        final second = Completer<ServerStatusSnapshot>();
        final third = Completer<ServerStatusSnapshot>();
        final retired = Completer<ServerStatusSnapshot>();
        bool Function()? secondOwner;
        final repository = _Repository(() => first.future);
        await _pump(tester, repository, settle: false);
        expect(repository.calls, 1);
        expect(
          tester
              .widget<UtenAppBarActionButton>(
                find.byKey(const Key('server-status-refresh')),
              )
              .onPressed,
          isNull,
        );
        now = now.add(const Duration(seconds: 45));
        await tester.pump(const Duration(seconds: 45));
        expect(repository.calls, 1);
        first.complete(_sample(now));
        await tester.pumpAndSettle();
        repository.handler = () {
          secondOwner = PagedReadIntent.currentRead;
          return Future.any([second.future, retired.future]);
        };
        now = now.add(const Duration(seconds: 15));
        await tester.pump(const Duration(seconds: 15));
        expect(repository.calls, 2);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(secondOwner?.call(), isFalse);
        // The real ApiClient aborts this transport when its owner retires.
        retired.completeError(ApiException('REQUEST_STALE', 'fixture retired'));
        now = now.add(const Duration(seconds: 45));
        await tester.pump(const Duration(seconds: 45));
        expect(repository.active, 0);
        repository.handler = () => third.future;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(repository.calls, 3);
        second.complete(_sample(now));
        third.complete(_sample(now));
        await tester.pumpAndSettle();
        repository.handler = () async => _sample(now);
        final navigator = Navigator.of(
          tester.element(find.byType(ServerStatusPage)),
        );
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('another page')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        now = now.add(const Duration(seconds: 45));
        await tester.pump(const Duration(seconds: 45));
        expect(repository.calls, 3);
        navigator.pop();
        await tester.pumpAndSettle();
        expect(repository.calls, 4);
        expect(repository.peak, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 60));
        expect(repository.calls, 4);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'stale data and refresh failure immediately lose old healthy colors',
    (tester) async {
      var now = sampledAt;
      await withClock(Clock(() => now), () async {
        final delayed = Completer<ServerStatusSnapshot>();
        final repository = _Repository(() async => _sample(sampledAt));
        await _pump(tester, repository);
        repository.handler = () => delayed.future;
        now = now.add(const Duration(seconds: 31));
        await tester.pump(const Duration(seconds: 31));
        await tester.pump();
        expect(find.text('数据已过期，正在等待新的采集结果。'), findsWidgets);
        expect(
          tester
              .widgetList<UtenStatusBadge>(find.byType(UtenStatusBadge))
              .every((badge) => badge.type == UtenStatusBadgeType.neutral),
          isTrue,
        );
        delayed.completeError(NetworkException());
        await tester.pumpAndSettle();
        expect(find.text('暂时无法更新。上次数据仅供参考，请稍后刷新。'), findsWidgets);
        expect(
          tester
              .widgetList<UtenStatusBadge>(find.byType(UtenStatusBadge))
              .every((badge) => badge.type == UtenStatusBadgeType.neutral),
          isTrue,
        );
        expect(repository.peak, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );

  testWidgets(
    'extra counters pick ring or number by unit and scheduled jobs list their last run',
    (tester) async {
      await withClock(Clock.fixed(sampledAt), () async {
        await _pump(tester, _Repository(() async => _withExtras(sampledAt)));
        await tester.pumpAndSettle();
        final threads = find.byKey(const ValueKey('server-extra-threads'));
        final sessions = find.byKey(const ValueKey('server-extra-sessions'));
        final volume = find.byKey(const ValueKey('server-extra-attachments'));
        expect(
          find.descendant(of: threads, matching: find.byType(UtenGaugeRing)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: threads, matching: find.text('120')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: sessions, matching: find.byType(UtenGaugeRing)),
          findsNothing,
          reason: '没有告警阈值的计数不画环，避免编造上限',
        );
        expect(
          find.descendant(of: sessions, matching: find.text('9')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: volume, matching: find.byType(UtenGaugeRing)),
          findsNothing,
        );
        expect(
          find.descendant(of: volume, matching: find.text('5 GiB')),
          findsOneWidget,
        );
        expect(find.byType(MasterDataTableView<ServerJob>), findsOneWidget);
        expect(find.text('OutboxScheduler.drain'), findsOneWidget);
        expect(find.text('CelebrationScheduler.publishDaily'), findsOneWidget);
        expect(find.text('IllegalStateException'), findsOneWidget);
        expect(find.text('已超过 2 个周期未执行'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );

  testWidgets('job headers filter health and order runs by date', (
    tester,
  ) async {
    await withClock(Clock.fixed(sampledAt), () async {
      await _pump(tester, _Repository(() async => _withExtras(sampledAt)));
      final table = find.byType(MasterDataTableView<ServerJob>);
      final status = find.descendant(of: table, matching: find.text('状态'));
      await tester.ensureVisible(status);
      await tester.pumpAndSettle();
      await tester.tap(status);
      await tester.pumpAndSettle();
      await tester.tap(find.text('留意 (1)'));
      await tester.pumpAndSettle();
      expect(find.text('CelebrationScheduler.publishDaily'), findsOneWidget);
      expect(find.text('OutboxScheduler.drain'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(tester, _Repository(() async => _withExtras(sampledAt)));
      final start = find.descendant(of: table, matching: find.text('上次开始'));
      await tester.ensureVisible(start);
      await tester.pumpAndSettle();
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.tap(find.text('从近到远'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('OutboxScheduler.drain')).dy,
        lessThan(
          tester.getTopLeft(find.text('CelebrationScheduler.publishDaily')).dy,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('stale samples grey every ring and the live pulse dot', (
    tester,
  ) async {
    var now = sampledAt;
    await withClock(Clock(() => now), () async {
      final delayed = Completer<ServerStatusSnapshot>();
      final repository = _Repository(() async => _withExtras(sampledAt));
      await _pump(tester, repository);
      expect(
        tester
            .widget<UtenLivePulseDot>(
              find.byKey(const Key('server-status-pulse')),
            )
            .stale,
        isFalse,
      );
      expect(
        tester
            .widget<UtenGaugeRing>(find.byKey(const Key('server-status-ring')))
            .value,
        95,
        reason: '总览环取最差的百分比指标（应用内存 95% > 磁盘 91%）',
      );
      repository.handler = () => delayed.future;
      now = now.add(const Duration(seconds: 31));
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(
        tester
            .widgetList<UtenGaugeRing>(find.byType(UtenGaugeRing))
            .every(
              (ring) =>
                  ring.status == UtenGaugeStatus.unknown && ring.value == null,
            ),
        isTrue,
        reason: '过期后不保留旧的绿色环',
      );
      expect(
        tester
            .widget<UtenLivePulseDot>(
              find.byKey(const Key('server-status-pulse')),
            )
            .stale,
        isTrue,
      );
      expect(find.text('数据已过期，正在等待新的采集结果。'), findsWidgets);
      delayed.complete(_withExtras(now));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // 2026-09-12 用户反馈：「运行总览的动画要等好一会才出现」。根因是快照只存在页面
  // State 里，每次进页面都从 null 起步，总览环必须等一整趟请求回来才有读数。
  // 现在页面把快照写进 serverStatusSnapshotCacheProvider，下次进页面第一帧先用。
  testWidgets('进页面第一帧就用共享缓存画出总览，不等自己那趟请求回来', (tester) async {
    await withClock(Clock.fixed(sampledAt), () async {
      final pending = Completer<ServerStatusSnapshot>();
      final repository = _Repository(() => pending.future);
      await _pump(
        tester,
        repository,
        settle: false,
        cached: _withExtras(sampledAt),
      );
      expect(
        tester
            .widget<UtenGaugeRing>(find.byKey(const Key('server-status-ring')))
            .value,
        95,
        reason: '请求还挂着，读数必须已经来自缓存，而不是停在虚线占位',
      );
      expect(repository.active, 1, reason: '缓存只是先画一帧，后台照样去拉新的');
      pending.complete(_withExtras(sampledAt));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('过期的缓存不入画：宁可占位，也不摆一个下一帧就被标成已过期的读数', (tester) async {
    await withClock(Clock.fixed(sampledAt), () async {
      final pending = Completer<ServerStatusSnapshot>();
      final repository = _Repository(() => pending.future);
      await _pump(
        tester,
        repository,
        settle: false,
        // 过期窗口是 sampledAt + pollSeconds×2 = 30s，31s 前的采样已经作废。
        cached: _withExtras(sampledAt.subtract(const Duration(seconds: 31))),
      );
      final ring = tester.widget<UtenGaugeRing>(
        find.byKey(const Key('server-status-ring')),
      );
      expect(ring.value, isNull);
      expect(ring.status, UtenGaugeStatus.unknown);
      pending.complete(_withExtras(sampledAt));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('页面自己拉到的快照会回写缓存，供下次进页面第一帧复用', (tester) async {
    await withClock(Clock.fixed(sampledAt), () async {
      final repository = _Repository(() async => _withExtras(sampledAt));
      final container = await _pump(tester, repository);
      expect(
        container.read(serverStatusSnapshotCacheProvider)?.sampledAt,
        sampledAt,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repository repository, {
  bool compact = false,
  bool settle = true,
  Set<String> permissions = const {Perm.serverStatusView},
  ServerStatusSnapshot? cached,
  BadgeSummary? badgeSummary,
  ServerStorageRepository? storage,
  Size? size,
  double? textScale,
}) async {
  tester.view.physicalSize =
      size ?? (compact ? const Size(390, 1000) : const Size(1500, 1450));
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        sharedPreferencesProvider.overrideWithValue(preferences),
        serverStatusRepositoryProvider.overrideWithValue(repository),
        // 存储分区视图默认模拟「主机清单不可用」，页面退回逐盘圆环卡。
        serverStorageRepositoryProvider.overrideWithValue(
          storage ??
              _StorageRepository(
                () async => ServerStorageSummary.fromJson(const {
                  'revision': 'r0',
                  'status': 'UNKNOWN',
                  'capabilities': {'available': false},
                  'volumes': <Object?>[],
                  'categories': <Object?>[],
                }),
              ),
        ),
        if (badgeSummary != null) fixedBadgeSummaryOverride(badgeSummary),
        // 模拟「工作台那张卡的告警徽章刚刚拉过一次」——共享缓存里已有读数。
        if (cached != null)
          serverStatusSnapshotCacheProvider.overrideWith((ref) => cached),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          colorSchemeSeed: UtenColors.teal600,
          useMaterial3: true,
          brightness: compact ? Brightness.dark : Brightness.light,
          fontFamily: 'NotoSansSC',
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale ?? (compact ? 1.35 : 1)),
          ),
          child: child!,
        ),
        home: const RepaintBoundary(
          key: Key('server-status-capture'),
          child: ServerStatusPage(),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp)),
    listen: false,
  );
}

/// 只在显式要求时落盘（`UTEN_UI_FIXTURES=1 flutter test ...`）：默认跑测试不写文件。
Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['UTEN_UI_FIXTURES'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('server-status-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('.codex-tmp/server-status-ui')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Finder _hintContaining(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is UtenFieldHintIcon && (widget.info?.contains(text) ?? false),
);

Future<void> _toggleStorageDetails(
  WidgetTester tester,
  Finder card, {
  required bool expand,
}) async {
  final toggle = find.descendant(
    of: card,
    matching: find.text(expand ? '展开明细' : '收起明细'),
  );
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

ServerStorageSummary _accountingStorage() => ServerStorageSummary.fromJson({
  'revision': 'accounting',
  'status': 'NORMAL',
  'capabilities': {'available': true},
  'volumes': [
    for (final volume in [
      ('data', '/data'),
      ('media', '/var/lib/uten-imp-media'),
      ('system', '/'),
    ])
      {
        'id': volume.$1,
        'mount': volume.$2,
        'label': volume.$1,
        'totalBytes': 1073741824,
        'usedBytes': 1048576,
        'freeBytes': 1072693248,
        'reconciliation': {
          'status': 'PARTIAL',
          'classifiedBytes': 8192,
          'otherBytes': 1040384,
          'reservedBytes': 0,
          'overlapBytes': volume.$1 == 'data' ? 4096 : 0,
          'detail': '已统计内容已去重；其他占用含未完成统计的目录。',
        },
      },
  ],
  'categories': [
    {'kind': 'LOGS', 'status': 'UNKNOWN', 'detail': '日志目录暂时无法定位'},
    {
      'kind': 'DATABASE',
      'status': 'NORMAL',
      'logicalBytes': 409939,
      'allocatedBytes': 8192,
      'volumeId': 'data',
    },
    {
      'kind': 'LEGACY_UPLOADS',
      'status': 'WARNING',
      'logicalBytes': 100,
      'allocatedBytes': 4096,
      'volumeId': 'data',
    },
    {
      'kind': 'PAIRED_BACKUPS',
      'status': 'UNKNOWN',
      'logicalBytes': 500,
      'volumeId': 'data',
      'detail': '扫描未完成',
    },
  ],
});

class _Repository extends ServerStatusRepository {
  _Repository(this.handler) : super(ApiClient(Dio()));
  Future<ServerStatusSnapshot> Function() handler;
  int calls = 0, active = 0, peak = 0;
  @override
  Future<ServerStatusSnapshot> load() async {
    calls++;
    active++;
    if (active > peak) peak = active;
    try {
      return await handler();
    } finally {
      active--;
    }
  }
}

/// 状态页存储分区视图用的最小桩：只有 summary 会被调用。
class _StorageRepository implements ServerStorageRepository {
  _StorageRepository(this.summaryHandler);
  final Future<ServerStorageSummary> Function() summaryHandler;

  @override
  Future<ServerStorageSummary> summary() => summaryHandler();
  @override
  Future<ServerStorageResources> resources(String kind, {String? cursor}) =>
      throw UnimplementedError();
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

class _Layout extends WorkbenchLayoutNotifier {
  @override
  WorkbenchLayoutState build() =>
      const WorkbenchLayoutState(order: ['system'], collapsed: {});
}

/// 带新增探针（附加计数 + 定时任务）的采样，用于验证环/数字卡的分流与任务表。
ServerStatusSnapshot _withExtras(DateTime at) => ServerStatusSnapshot.fromJson({
  ..._json(at),
  'extras': [
    {
      'key': 'threads',
      'label': '平台线程数',
      'value': 120,
      'unit': 'COUNT',
      'warningThreshold': 400,
      'criticalThreshold': 800,
      'status': 'NORMAL',
      'detail': '平台 Java 进程当前线程数',
    },
    {
      'key': 'sessions',
      'label': '在线会话',
      'value': 9,
      'unit': 'COUNT',
      'status': 'NORMAL',
      'detail': '员工 7 · 访客 2',
    },
    {
      'key': 'attachments',
      'label': '附件占用',
      'value': 5368709120,
      'unit': 'BYTES',
      'status': 'NORMAL',
      'detail': '共 1200 个附件',
      'usedBytes': 5368709120,
    },
  ],
  'jobs': [
    {
      'key': 'CelebrationScheduler.publishDaily',
      'label': 'CelebrationScheduler.publishDaily',
      'lastStartAt': at.subtract(const Duration(minutes: 10)).toIso8601String(),
      'lastEndAt': at.subtract(const Duration(minutes: 9)).toIso8601String(),
      'lastDurationMs': 60000,
      'periodSeconds': 60,
      'status': 'WARNING',
      'detail': '已超过 2 个周期未执行',
    },
    {
      'key': 'OutboxScheduler.drain',
      'label': 'OutboxScheduler.drain',
      'lastStartAt': at.subtract(const Duration(seconds: 5)).toIso8601String(),
      'lastEndAt': at.subtract(const Duration(seconds: 4)).toIso8601String(),
      'lastDurationMs': 1000,
      'periodSeconds': 5,
      'lastErrorType': 'IllegalStateException',
      'status': 'CRITICAL',
      'detail': '最近连续 3 次执行失败',
    },
  ],
});

ServerStatusSnapshot _sample(DateTime at) =>
    ServerStatusSnapshot.fromJson(_json(at));

Map<String, dynamic> _json(DateTime at) => {
  'sampledAt': at.toIso8601String(),
  'refreshAfterSeconds': 15,
  'status': 'CRITICAL',
  'environment': '公司内网',
  'applicationVersion': '0.1.0',
  'uptimeSeconds': 96300,
  'metrics': [
    {
      'key': 'cpu',
      'label': 'CPU',
      'value': 42.5,
      'unit': 'PERCENT',
      'warningThreshold': 80,
      'criticalThreshold': 95,
      'status': 'NORMAL',
      'detail': '处理器负载平稳',
    },
    {
      'key': 'memory',
      'label': '系统内存',
      'value': 85,
      'unit': 'PERCENT',
      'warningThreshold': 80,
      'criticalThreshold': 90,
      'status': 'WARNING',
      'detail': '内存使用较高',
      'totalBytes': 34359738368,
      'usedBytes': 29205777612,
      'freeBytes': 5153960756,
    },
    {
      'key': 'jvm_memory',
      'label': '应用内存',
      'value': 95,
      'unit': 'PERCENT',
      'warningThreshold': 80,
      'criticalThreshold': 90,
      'status': 'CRITICAL',
      'detail': '应用内存接近上限',
      'totalBytes': 2147483648,
      'usedBytes': 2040109465,
      'freeBytes': 107374183,
    },
    {
      'key': 'db_pool',
      'label': '连接池',
      'value': null,
      'unit': 'PERCENT',
      'status': 'UNKNOWN',
      'detail': '连接池暂不提供数据',
    },
  ],
  'disks': [
    {
      'key': 'main',
      'label': '系统与附件磁盘',
      'totalBytes': 107374182400,
      'usedBytes': 97710505984,
      'freeBytes': 9663676416,
      'usedPercent': 91,
      'warningThreshold': 80,
      'criticalThreshold': 90,
      'status': 'CRITICAL',
      'detail': '可用空间不足 10%',
    },
  ],
  'database': {
    'status': 'NORMAL',
    'responseMs': 3.2,
    'connections': 12,
    'maxConnections': 100,
    'detail': '数据库能够正常响应',
  },
  'backup': {
    'status': 'UNKNOWN',
    'lastSuccessAt': null,
    'ageHours': null,
    'warningAfterHours': 30,
    'criticalAfterHours': 48,
    'detail': '尚未接入备份结果',
  },
  'alerts': [
    {
      'key': 'disk',
      'status': 'CRITICAL',
      'message': '磁盘空间需要处理',
      'suggestion': '请联系管理员检查存储空间。',
    },
  ],
};
