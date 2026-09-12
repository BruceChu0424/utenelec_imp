import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/data_display/uten_gauge_ring.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/components/feedback/uten_live_pulse_dot.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/admin/models/server_status.dart';
import 'package:uten_imp/features/admin/pages/server_status_page.dart';
import 'package:uten_imp/features/admin/repositories/server_status_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/dashboard/providers/workbench_layout_provider.dart';
import 'package:uten_imp/features/dashboard/widgets/workbench_module_area.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sampledAt = DateTime.utc(2026, 9, 8, 12);

  setUpAll(() async {
    final loader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await loader.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

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
            find.descendant(of: pool, matching: find.text('连接池暂不提供数据')),
            findsOneWidget,
          );
          expect(find.text('尚未接入备份结果'), findsOneWidget);
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
      ]);
      expect(
        requiredAnyPermFor('${RouteName.adminServerStatus}?from=dashboard'),
        [Perm.serverStatusView],
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
          find.descendant(of: backup, matching: find.text('检查未通过')),
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
      expect(find.text('权限管理'), findsNothing);
      expect(find.text('系统设置'), findsNothing);
      await tester.tap(find.text('服务器状态'));
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        RouteName.adminServerStatus,
      );
      expect(find.byType(ServerStatusPage), findsOneWidget);
      // 2 次 = 页面自己拉一次 + 工作台那张卡的告警徽章拉一次（2026-09-11 新增）。
      // 两者共用同一个只读端点，服务端有 15s 采样缓存，多这一次是 HTTP 往返而已；
      // 数字钉死在 2，多出第三次（比如谁又加了一个轮询源）会立刻被这里拦下。
      expect(repository.calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'slow reads never overlap and polling pauses off-route, in background and after disposal',
    (tester) async {
      var now = sampledAt;
      await withClock(Clock(() => now), () async {
        final first = Completer<ServerStatusSnapshot>();
        final second = Completer<ServerStatusSnapshot>();
        final repository = _Repository(() => first.future);
        await _pump(tester, repository, settle: false);
        expect(repository.calls, 1);
        expect(
          tester
              .widget<IconButton>(
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
        repository.handler = () => second.future;
        now = now.add(const Duration(seconds: 15));
        await tester.pump(const Duration(seconds: 15));
        expect(repository.calls, 2);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        now = now.add(const Duration(seconds: 45));
        await tester.pump(const Duration(seconds: 45));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        expect(repository.calls, 2);
        second.complete(_sample(now));
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
        expect(repository.calls, 2);
        navigator.pop();
        await tester.pumpAndSettle();
        expect(repository.calls, 3);
        expect(repository.peak, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 60));
        expect(repository.calls, 3);
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
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository, {
  bool compact = false,
  bool settle = true,
  Set<String> permissions = const {Perm.serverStatusView},
}) async {
  tester.view.physicalSize = compact
      ? const Size(390, 1000)
      : const Size(1500, 1450);
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
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(compact ? 1.35 : 1)),
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
