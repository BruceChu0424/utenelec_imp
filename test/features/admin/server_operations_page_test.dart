import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/admin/models/server_operations.dart';
import 'package:uten_imp/features/admin/pages/server_operations_page.dart';
import 'package:uten_imp/features/admin/providers/server_operations_access.dart';
import 'package:uten_imp/features/admin/repositories/server_operations_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

void main() {
  testWidgets(
    'only the original operator can cancel a pending appointment and cancellation is explicit',
    (tester) async {
      final repository = _Repository()
        ..statusValue = _status(
          job: _job('existing', state: 'SCHEDULED', mode: 'SCHEDULE_UPDATE'),
        );
      await _pump(tester, repository, actorId: 'other-operator');
      expect(find.byKey(const ValueKey('server-update-cancel')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await _pump(tester, repository, actorId: 'operator');
      await tester.ensureVisible(
        find.byKey(const ValueKey('server-update-cancel')),
      );
      await tester.tap(find.byKey(const ValueKey('server-update-cancel')));
      await tester.pumpAndSettle();
      expect(repository.cancels, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('server-update-cancel-confirm')),
      );
      await tester.pumpAndSettle();
      expect(repository.cancels, hasLength(1));
      expect(repository.starts, isEmpty);
      expect(find.text('预约已取消'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'a newly checked version offers explicit immediate update without automatic activation',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.tap(find.byKey(const ValueKey('server-update-start')));
      await tester.pump();
      final checkRequest = repository.starts.single['requestId']!;
      repository.statusValue = _status(
        updateAvailable: true,
        job: _job(checkRequest, state: 'SUCCEEDED', phase: 'DONE'),
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 v2.5.18'), findsWidgets);
      expect(
        find.byKey(const ValueKey('server-update-confirm')),
        findsOneWidget,
      );
      expect(repository.starts, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('server-update-confirm')));
      await tester.pump();
      expect(repository.starts, hasLength(2));
      expect(repository.starts[1]['mode'], 'CHECK_AND_UPDATE');
      expect(repository.starts[1]['targetVersion'], 'v2.5.18');
      expect(repository.starts[1]['expectedSourceRevision'], 'source-r1');
      expect(repository.starts[1]['requestId'], isNot(checkRequest));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scheduled update submits the host-resolved instant and never device timezone math',
    (tester) async {
      final repository = _Repository()
        ..statusValue = _status(updateAvailable: true);
      await _pump(tester, repository);
      expect(repository.starts, isEmpty);
      await tester.tap(find.byKey(const ValueKey('server-update-available')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('server-update-schedule')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('server-schedule-confirm')));
      await tester.pumpAndSettle();
      expect(repository.scheduleChecks.single, {
        'localDate': '2026-10-16',
        'hour': 2,
      });
      expect(repository.starts, isEmpty);
      expect(find.text('2026-10-16 02:00（Asia/Shanghai）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('server-schedule-confirm')));
      await tester.pumpAndSettle();
      expect(repository.starts.single['mode'], 'SCHEDULE_UPDATE');
      expect(repository.starts.single['scheduledAt'], '2026-10-15T18:00:00Z');
      expect(repository.starts.single['targetVersion'], 'v2.5.18');
      expect(find.text('更新已预约'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'delegated operations routes do not require authorization management',
    () {
      for (final route in [
        RouteName.adminServerOperations,
        RouteName.adminServerStorage,
        RouteName.adminServerStatus,
      ]) {
        expect(requiredAnyPermFor(route), [
          Perm.serverStatusView,
          Perm.serverUpdate,
          Perm.serverCleanup,
        ]);
        expect(
          requiredAnyPermFor(route),
          isNot(contains(Perm.authorizationManage)),
        );
      }
    },
  );

  testWidgets('entry and refresh only read local status, never start updates', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository);
    expect(repository.statusCalls, 1);
    expect(repository.starts, isEmpty);
    expect(repository.sourceCalls, 0);
    await tester.tap(find.byKey(const ValueKey('server-operations-refresh')));
    await tester.pumpAndSettle();
    expect(repository.statusCalls, 2);
    expect(repository.starts, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'manual check binds source revision and current version; running job resumes by GET',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.tap(find.byKey(const ValueKey('server-update-start')));
      await tester.pump();
      expect(repository.starts.single['mode'], 'CHECK_ONLY');
      expect(repository.starts.single['expectedSourceRevision'], 'source-r1');
      expect(repository.starts.single['expectedCurrentVersion'], 'v2.5.16');
      expect(
        repository.starts.single['requestId'],
        matches(RegExp(r'^[0-9a-f-]{36}$')),
      );
      expect(find.text('正在更新'), findsOneWidget);
      final button = tester.widget<UtenButton>(
        find.byKey(const ValueKey('server-update-start')),
      );
      expect(button.onPressed, isNull);
      repository.statusValue = _status(
        job: _job(
          repository.starts.single['requestId']!,
          state: 'SUCCEEDED',
          phase: 'DONE',
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(repository.starts, hasLength(1));
      expect(find.text('版本检查完成'), findsOneWidget);
      expect(
        find.text('备份'),
        findsNothing,
        reason: 'check-only never claims backup/migration ran',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'lost submission response queries original durable request without POST replay',
    (tester) async {
      final repository = _Repository()
        ..startError = NetworkException('connection interrupted');
      await _pump(tester, repository);
      await tester.tap(find.byKey(const ValueKey('server-update-start')));
      await tester.pumpAndSettle();
      expect(repository.starts, hasLength(1));
      expect(find.text('正在核对原作业'), findsOneWidget);
      repository.statusValue = _status(
        job: _job(
          repository.starts.single['requestId']!,
          state: 'SUCCEEDED',
          phase: 'DONE',
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('版本检查完成'), findsOneWidget);
      expect(repository.starts, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pending job survives page entry, recovery-required blocks new updates',
    (tester) async {
      final repository = _Repository()
        ..statusValue = _status(
          job: _job('existing', state: 'RECOVERY_REQUIRED'),
        );
      await _pump(tester, repository);
      expect(find.text('需要恢复处理'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('server-update-start')),
            )
            .onPressed,
        isNull,
      );
      expect(repository.starts, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('unauthorized page sends no requests', (tester) async {
    final repository = _Repository();
    await _pump(tester, repository, visible: false);
    expect(repository.statusCalls, 0);
    expect(find.text('没有服务器运维查看权限'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('readonly operation and unavailable host cannot start updates', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository, writable: false);
    expect(
      tester
          .widget<UtenButton>(find.byKey(const ValueKey('server-update-start')))
          .onPressed,
      isNull,
    );
    expect(repository.starts, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'endpoint/identity change retires earlier status and late response',
    (tester) async {
      final owner = StateProvider<Object?>((ref) => 'company-a/operator');
      final first = Completer<ServerOperationsStatus>();
      final repository = _Repository()..statusHandler = () => first.future;
      final container = await _pump(
        tester,
        repository,
        owner: owner,
        settle: false,
      );
      repository.statusHandler = () async => _status(version: 'v9.1.0');
      container.read(owner.notifier).state = 'company-b/operator';
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('当前版本：v9.1.0'), findsOneWidget);
      first.complete(_status(version: 'v1.0.0'));
      await tester.pumpAndSettle();
      expect(find.text('当前版本：v1.0.0'), findsNothing);
      expect(find.text('当前版本：v9.1.0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'source secrets are never read back; blank retains and replacement requires secret',
    (tester) async {
      final repository = _Repository()..statusValue = _status(configure: true);
      await _pump(tester, repository, source: true);
      await tester.ensureVisible(
        find.byKey(const ValueKey('server-source-editor')),
      );
      await tester.tap(find.text('发布源与凭据'));
      await tester.pumpAndSettle();
      expect(repository.sourceCalls, 1);
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const ValueKey('server-source-secret')),
                matching: find.byType(TextField),
              ),
            )
            .obscureText,
        isTrue,
      );
      expect(find.text('not-readable-secret'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('server-source-save')),
      );
      await tester.tap(find.byKey(const ValueKey('server-source-save')));
      await tester.pumpAndSettle();
      expect(repository.saves.single.containsKey('accessKeySecret'), isFalse);
      expect(repository.saves.single.containsKey('accessKeyId'), isFalse);
      expect(repository.saves.single['clearCredentials'], false);
      expect(repository.saves.single['expectedRevision'], 'source-r1');
      await tester.enterText(
        find.byKey(const ValueKey('server-source-key-id')),
        'new-id',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('server-source-save')),
      );
      await tester.tap(find.byKey(const ValueKey('server-source-save')));
      await tester.pumpAndSettle();
      expect(repository.saves, hasLength(1));
      expect(find.text('更换访问密钥 ID 时，请同时填写新密钥。'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('server-source-key-id')),
        '',
      );
      await tester.enterText(
        find.byKey(const ValueKey('server-source-endpoint')),
        'https://oss-cn-hangzhou.aliyuncs.com',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('server-source-save')),
      );
      await tester.tap(find.byKey(const ValueKey('server-source-save')));
      await tester.pumpAndSettle();
      expect(repository.saves, hasLength(1));
      final endpointHint = find.descendant(
        of: find.byKey(const ValueKey('server-source-endpoint')),
        matching: find.byType(UtenFieldHintIcon),
      );
      await tester.ensureVisible(endpointHint);
      await tester.tap(endpointHint);
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          '请填写区域域名，例如 oss-cn-hangzhou.aliyuncs.com，不含 https://',
        ),
        findsOneWidget,
      );
      Tooltip.dismissAllToolTips();
      await tester.enterText(
        find.byKey(const ValueKey('server-source-endpoint')),
        'oss-cn-hangzhou.aliyuncs.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('server-source-key-id')),
        'newid',
      );
      await tester.enterText(
        find.byKey(const ValueKey('server-source-secret')),
        'typed-secret',
      );
      await tester.ensureVisible(find.text('明确清除已保存的访问凭据'));
      await tester.tap(find.text('明确清除已保存的访问凭据'));
      await tester.pump();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('server-source-secret')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('server-source-key-id')),
            )
            .controller!
            .text,
        isEmpty,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('server-source-save')),
      );
      await tester.tap(find.byKey(const ValueKey('server-source-save')));
      await tester.pumpAndSettle();
      expect(repository.saves.last['clearCredentials'], true);
      expect(repository.saves.last.containsKey('accessKeySecret'), false);
      expect(repository.saves.last.containsKey('signingPublicKey'), false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('compact enlarged layout is usable and does not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _Repository()
      ..statusValue = _status(
        job: _job('existing', state: 'SUCCEEDED', phase: 'DONE'),
      );
    await _pump(tester, repository, textScale: 1.4);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repository repository, {
  bool visible = true,
  bool writable = true,
  bool source = false,
  String? actorId,
  StateProvider<Object?>? owner,
  bool settle = true,
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        authenticatedScopeProvider.overrideWithValue(
          actorId == null ? null : AuthenticatedScope(userId: actorId),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        serverOperationsOwnerProvider.overrideWith(
          (ref) => owner == null ? 'company/operator' : ref.watch(owner),
        ),
        serverOperationsVisibleProvider.overrideWithValue(visible),
        serverOperationsWritableProvider.overrideWithValue(writable),
        serverSourceVisibleProvider.overrideWithValue(source),
        serverOperationsRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const ServerOperationsPage(),
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

Map<String, dynamic> _job(
  String requestId, {
  String state = 'RUNNING',
  String phase = 'CHECKING',
  String mode = 'CHECK_ONLY',
}) => {
  'id': 'job-1',
  'actorId': 'operator',
  'requestId': requestId,
  'state': state,
  'phase': phase,
  'mode': mode,
  'currentVersion': 'v2.5.16',
  'targetVersion': 'v2.5.18',
  'message': '安全作业摘要',
};
ServerOperationsStatus _status({
  String version = 'v2.5.16',
  Map<String, dynamic>? job,
  bool configure = false,
  bool updateAvailable = false,
}) => ServerOperationsStatus.fromJson({
  'available': true,
  'manualOnly': true,
  'currentVersion': version,
  'sourceRevision': 'source-r1',
  'sourceConfigured': true,
  'canUpdate': true,
  'canCleanup': true,
  'canConfigureSource': configure,
  'latestJob': job,
  'updateAvailable': updateAvailable,
  'latestVersion': 'v2.5.18',
  'serverTimeZone': 'Asia/Shanghai',
  'serverTime': '2026-10-15T20:00:00+08:00',
});
ServerUpdateSource _source() => ServerUpdateSource.fromJson({
  'revision': 'source-r1',
  'endpoint': 'oss-cn-hangzhou.aliyuncs.com',
  'bucket': 'release',
  'objectPrefix': 'releases',
  'accessKeyConfigured': true,
  'accessKeyIdHint': '••••abcd',
  'signingPublicKey': 'public-key',
  'applied': true,
});

class _Repository implements ServerOperationsRepository {
  ServerOperationsStatus statusValue = _status();
  Future<ServerOperationsStatus> Function()? statusHandler;
  Object? startError;
  int statusCalls = 0, sourceCalls = 0;
  final starts = <Map<String, String>>[], saves = <Map<String, dynamic>>[];
  @override
  Future<ServerOperationsStatus> status() async {
    statusCalls++;
    return statusHandler == null ? statusValue : statusHandler!();
  }

  @override
  Future<ServerUpdateJob> startUpdate({
    required String requestId,
    required String expectedSourceRevision,
    required String expectedCurrentVersion,
    String mode = 'CHECK_ONLY',
    String? targetVersion,
    String? scheduledAt,
  }) async {
    starts.add({
      'requestId': requestId,
      'expectedSourceRevision': expectedSourceRevision,
      'expectedCurrentVersion': expectedCurrentVersion,
      'mode': mode,
      'targetVersion': ?targetVersion,
      'scheduledAt': ?scheduledAt,
    });
    if (startError != null) throw startError!;
    return ServerUpdateJob.fromJson(
      _job(
        requestId,
        mode: mode,
        state: mode == 'SCHEDULE_UPDATE' ? 'SCHEDULED' : 'RUNNING',
      ),
    );
  }

  @override
  Future<ServerUpdateJob> job(String id) async =>
      ServerUpdateJob.fromJson(_job('existing'));
  @override
  Future<ServerUpdateJob?> latestJob() async => statusValue.latestJob;
  @override
  Future<ServerUpdateSource> source() async {
    sourceCalls++;
    return _source();
  }

  @override
  Future<ServerUpdateSource> saveSource(Map<String, dynamic> command) async {
    saves.add(Map.of(command));
    return _source();
  }

  final scheduleChecks = <Map<String, Object>>[];
  final cancels = <String>[];
  @override
  Future<ServerUpdateJob> cancel(
    String jobId, {
    required String requestId,
  }) async {
    cancels.add(requestId);
    return ServerUpdateJob.fromJson(
      _job('scheduled-request', state: 'CANCELLED', mode: 'SCHEDULE_UPDATE'),
    );
  }

  @override
  Future<ServerUpdateSchedulePreview> schedulePreview({
    required String localDate,
    required int hour,
  }) async {
    scheduleChecks.add({'localDate': localDate, 'hour': hour});
    return ServerUpdateSchedulePreview.fromJson({
      'scheduledAt': '2026-10-15T18:00:00Z',
      'serverTimeZone': 'Asia/Shanghai',
      'displayLocalTime': '2026-10-16 02:00',
    });
  }
}
