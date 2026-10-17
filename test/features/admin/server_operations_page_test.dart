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
      expect(find.text('正在检查版本'), findsOneWidget);
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
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('server-update-job-state')))
            .data,
        '需要恢复处理',
      );
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
      expect(find.text('v9.1.0'), findsOneWidget);
      first.complete(_status(version: 'v1.0.0'));
      await tester.pumpAndSettle();
      expect(find.text('v1.0.0'), findsNothing);
      expect(find.text('v9.1.0'), findsOneWidget);
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

  testWidgets(
    'lost ACK resolves the exact request while a newer host job keeps writes locked',
    (tester) async {
      final repository = _Repository()
        ..startError = NetworkException()
        ..statusValue = _status(configure: true);
      await _pump(tester, repository, source: true);
      await _tap(tester, 'server-update-start');
      final original = repository.starts.single['requestId']!;
      repository.statusValue = _status(
        configure: true,
        job: _job('newer-host-job'),
      );
      repository.jobHandler = (id) async =>
          ServerUpdateJob.fromJson(_job(id, state: 'SUCCEEDED', phase: 'DONE'));
      await _tap(tester, 'server-operations-refresh');
      expect(repository.jobReads, [original]);
      expect(repository.latestCalls, 0);
      expect(
        find.byKey(const ValueKey('server-update-original-receipt')),
        findsOneWidget,
      );
      expect(_checkButton(tester).onPressed, isNull);
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('server-source-editor')),
            )
            .onTap,
        isNull,
      );
      final reads = repository.statusCalls;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(repository.statusCalls, greaterThan(reads));
      expect(repository.starts, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final state in [
    'RUNNING',
    'NOT_FOUND',
    'RECOVERY_REQUIRED',
    'SUCCEEDED',
  ]) {
    testWidgets(
      'exact original receipt $state cannot be replaced by a later terminal job',
      (tester) async {
        final repository = _Repository()
          ..startError = NetworkTimeoutException()
          ..statusValue = _status(configure: true);
        await _pump(tester, repository, source: true);
        await _tap(tester, 'server-update-start');
        final original = repository.starts.single['requestId']!;
        repository.statusValue = _status(
          configure: true,
          job: _job('later-terminal', state: 'SUCCEEDED', phase: 'DONE'),
        );
        repository.jobHandler = (id) async {
          if (state == 'NOT_FOUND') {
            throw ApiException(
              'NOT_FOUND',
              '原作业暂未查到',
              httpStatus: 404,
              hasResponseCode: true,
            );
          }
          return ServerUpdateJob.fromJson(_job(id, state: state));
        };
        await _tap(tester, 'server-operations-refresh');
        expect(repository.jobReads, [original]);
        expect(repository.latestCalls, 0);
        expect(_checkButton(tester).onPressed == null, state != 'SUCCEEDED');
        expect(
          tester
                  .widget<ListTile>(
                    find.byKey(const ValueKey('server-source-editor')),
                  )
                  .onTap ==
              null,
          state != 'SUCCEEDED',
        );
        if (state == 'NOT_FOUND') {
          expect(find.textContaining('暂未确认原作业结果'), findsOneWidget);
        }
        if (state == 'RECOVERY_REQUIRED') {
          expect(find.textContaining('需要恢复处理'), findsWidgets);
        }
        expect(repository.starts, hasLength(1));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'definitive cancel rejection refreshes host state without inventing an unknown acknowledgement',
    (tester) async {
      final repository = _Repository()
        ..statusValue = _status(
          job: _job('appointment', state: 'SCHEDULED', mode: 'SCHEDULE_UPDATE'),
        )
        ..cancelHandler = (id) async => throw ApiException(
          'FORBIDDEN',
          '当前操作人不能取消此预约，请刷新状态。',
          httpStatus: 403,
          hasResponseCode: true,
        );
      await _pump(tester, repository, actorId: 'operator');
      await _tap(tester, 'server-update-cancel');
      repository.statusValue = _status(
        job: _job('appointment', mode: 'SCHEDULE_UPDATE'),
      );
      await _tap(tester, 'server-update-cancel-confirm');
      expect(repository.statusCalls, 2);
      expect(find.textContaining('当前操作人不能取消'), findsOneWidget);
      expect(find.textContaining('取消结果尚未确认'), findsNothing);
      expect(repository.jobReads, isEmpty);
      expect(repository.cancels, hasLength(1));
      expect(find.byKey(const ValueKey('server-update-cancel')), findsNothing);
      expect(_checkButton(tester).onPressed, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unknown cancel queries its original appointment when latest points to another job',
    (tester) async {
      final repository = _Repository()
        ..statusValue = _status(
          job: _job('appointment', state: 'SCHEDULED', mode: 'SCHEDULE_UPDATE'),
        )
        ..cancelHandler = (id) async => throw NetworkTimeoutException();
      await _pump(tester, repository, actorId: 'operator');
      await _tap(tester, 'server-update-cancel');
      await _tap(tester, 'server-update-cancel-confirm');
      repository.statusValue = _status(
        job: _job('newer', state: 'SUCCEEDED', phase: 'DONE'),
      );
      repository.jobHandler = (id) async => ServerUpdateJob.fromJson(
        _job(id, state: 'CANCELLED', mode: 'SCHEDULE_UPDATE'),
      );
      await _tap(tester, 'server-operations-refresh');
      expect(repository.jobReads, ['appointment']);
      expect(repository.latestCalls, 0);
      expect(find.textContaining('取消结果尚未确认'), findsNothing);
      expect(repository.cancels, hasLength(1));
      expect(_checkButton(tester).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'source unknown save can close safely and a resized reopened editor requires fresh readback',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository()
        ..statusValue = _status(configure: true)
        ..saveError = NetworkTimeoutException();
      await _pump(tester, repository, source: true);
      await _tap(tester, 'server-source-editor');
      await tester.enterText(
        find.byKey(const ValueKey('server-source-key-id')),
        'temporary-id',
      );
      await tester.enterText(
        find.byKey(const ValueKey('server-source-secret')),
        'private-test-secret',
      );
      tester.view.physicalSize = const Size(375, 1000);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('server-source-secret')),
            )
            .controller!
            .text,
        'private-test-secret',
      );
      await _tap(tester, 'server-source-save');
      expect(repository.saves, hasLength(1));
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
            .widget<UtenButton>(
              find.byKey(const ValueKey('server-source-save')),
            )
            .onPressed,
        isNull,
      );
      await _tap(tester, 'server-source-close');
      expect(find.byKey(const ValueKey('server-source-dialog')), findsNothing);
      expect(find.textContaining('保存结果待确认'), findsOneWidget);
      final readback = Completer<ServerUpdateSource>();
      repository.sourceHandler = () => readback.future;
      tester.view.physicalSize = const Size(1440, 1100);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('server-source-editor')),
      );
      await tester.tap(find.byKey(const ValueKey('server-source-editor')));
      await tester.pump();
      expect(repository.sourceCalls, 2);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('server-source-save')),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('private-test-secret'), findsNothing);
      expect(repository.saves, hasLength(1));
      readback.complete(_source());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('server-source-save')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        repository.saves,
        hasLength(1),
        reason: 'a fresh read must never replay the previous secret write',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'schedule DST rejection cannot confirm and changing hour invalidates the old preview',
    (tester) async {
      final repository = _Repository()
        ..statusValue = _status(updateAvailable: true)
        ..previewError = ApiException(
          'VALIDATION',
          '服务器当地时间不存在，请重新选择。',
          httpStatus: 400,
          hasResponseCode: true,
        );
      await _pump(tester, repository);
      await _tap(tester, 'server-update-available');
      await _tap(tester, 'server-update-schedule');
      await _tap(tester, 'server-schedule-confirm');
      expect(find.textContaining('当地时间不存在'), findsOneWidget);
      expect(find.text('确认预约更新'), findsNothing);
      expect(repository.starts, isEmpty);
      repository.previewError = null;
      await _tap(tester, 'server-schedule-confirm');
      expect(find.text('确认预约更新'), findsOneWidget);
      await _tap(tester, 'server-schedule-hour');
      await tester.tap(find.text('凌晨 03:00').last);
      await tester.pumpAndSettle();
      expect(find.text('确认预约更新'), findsNothing);
      expect(repository.starts, isEmpty);
      await _tap(tester, 'server-schedule-confirm');
      expect(repository.scheduleChecks.last['hour'], 3);
      expect(repository.starts, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'company ABA during an open pending schedule retires that dialog and ignores its late preview',
    (tester) async {
      final owner = StateProvider<Object?>((ref) => 'a/operator');
      final preview = Completer<ServerUpdateSchedulePreview>();
      final repository = _Repository()
        ..statusValue = _status(updateAvailable: true)
        ..previewHandler = () => preview.future;
      final container = await _pump(tester, repository, owner: owner);
      await _tap(tester, 'server-update-available');
      await _tap(tester, 'server-update-schedule');
      await tester.tap(find.byKey(const ValueKey('server-schedule-confirm')));
      await tester.pump();
      container.read(owner.notifier).state = 'b/operator';
      await tester.pump();
      container.read(owner.notifier).state = 'a/operator';
      await tester.pumpAndSettle();
      preview.complete(
        ServerUpdateSchedulePreview.fromJson({
          'scheduledAt': '2026-10-15T18:00:00Z',
          'serverTimeZone': 'Asia/Shanghai',
          'displayLocalTime': '2026-10-16 02:00',
        }),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('server-schedule-confirm')),
        findsNothing,
      );
      expect(repository.starts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'initial loading and unconfigured host never enable a write or start a network check',
    (tester) async {
      final load = Completer<ServerOperationsStatus>();
      final repository = _Repository()..statusHandler = () => load.future;
      await _pump(tester, repository, settle: false);
      expect(_checkButton(tester).onPressed, isNull);
      expect(repository.starts, isEmpty);
      load.complete(_status(configured: false));
      await tester.pumpAndSettle();
      expect(find.text('发布源尚未配置'), findsOneWidget);
      expect(_checkButton(tester).onPressed, isNull);
      expect(repository.sourceCalls, 0);
      expect(repository.starts, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unsupported platform never exposes source configuration or starts operations',
    (tester) async {
      final repository = _Repository()
        ..statusValue = ServerOperationsStatus.fromJson({
          'available': false,
          'canUpdate': true,
          'canCleanup': true,
          'canConfigureSource': true,
          'sourceConfigured': true,
          'sourceRevision': 'saved-source',
          'updateAvailable': true,
          'latestVersion': 'v2.5.18',
          'failure': {
            'code': 'HOST_PLATFORM_UNSUPPORTED',
            'title': '当前环境不支持服务器在线运维',
            'reason': '在线更新与主机清理仅适用于 Linux 服务器。',
            'suggestion': '当前环境可继续使用业务功能和只读存储信息。',
          },
        });
      await _pump(tester, repository, source: true);
      expect(find.text('当前环境不支持服务器在线运维'), findsOneWidget);
      expect(find.byKey(const ValueKey('server-source-editor')), findsNothing);
      expect(find.byKey(const ValueKey('server-update-start')), findsNothing);
      expect(
        find.byKey(const ValueKey('server-update-available')),
        findsNothing,
      );
      expect(find.text('失败详情'), findsNothing);
      expect(repository.sourceCalls, 0);
      expect(repository.starts, isEmpty);
      expect(repository.saves, isEmpty);
      expect(find.text('存储管理'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final code in ['BUSY', 'CONFLICT']) {
    testWidgets(
      'trusted $code rejection shows a safe reason and only explicit refresh unlocks another check',
      (tester) async {
        final repository = _Repository()
          ..startError = ApiException(
            code,
            '当前服务器状态已变化，请刷新核对。',
            httpStatus: 409,
            hasResponseCode: true,
          );
        await _pump(tester, repository);
        await _tap(tester, 'server-update-start');
        expect(find.textContaining('当前服务器状态已变化'), findsOneWidget);
        expect(find.text('正在核对原作业'), findsNothing);
        expect(_checkButton(tester).onPressed, isNull);
        await _tap(tester, 'server-operations-refresh');
        expect(repository.jobReads, isEmpty);
        expect(repository.starts, hasLength(1));
        expect(_checkButton(tester).onPressed, isNotNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'failed local status read displays a safe fallback and never infers an uninstalled helper',
    (tester) async {
      final repository = _Repository()
        ..statusHandler = () async => throw NetworkException(
          '<Error>Authorization: Bearer raw-secret</Error>',
        );
      await _pump(tester, repository);
      expect(find.textContaining('无法读取服务器更新状态'), findsOneWidget);
      expect(find.textContaining('raw-secret'), findsNothing);
      expect(find.textContaining('未安装'), findsNothing);
      expect(_checkButton(tester).onPressed, isNull);
      expect(repository.starts, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'source permission revocation closes only that editor and retires its saved callback',
    (tester) async {
      final writable = StateProvider<bool>((ref) => true);
      final repository = _Repository()..statusValue = _status(configure: true);
      final container = await _pump(
        tester,
        repository,
        source: true,
        writableState: writable,
      );
      await _tap(tester, 'server-source-editor');
      final staleSave = tester
          .widget<UtenButton>(find.byKey(const ValueKey('server-source-save')))
          .onPressed!;
      final context = tester.element(
        find.byKey(const ValueKey('server-source-dialog')),
      );
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(title: Text('独立安全提示')),
        ),
      );
      await tester.pumpAndSettle();
      container.read(writable.notifier).state = false;
      await tester.pumpAndSettle();
      expect(find.text('独立安全提示'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('server-source-dialog'), skipOffstage: false),
        findsNothing,
      );
      staleSave();
      await tester.pumpAndSettle();
      expect(repository.saves, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

UtenButton _checkButton(WidgetTester tester) => tester.widget<UtenButton>(
  find.byKey(const ValueKey('server-update-start')),
);
Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repository repository, {
  bool visible = true,
  bool writable = true,
  bool source = false,
  String? actorId,
  StateProvider<Object?>? owner,
  StateProvider<bool>? writableState,
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
        serverOperationsWritableProvider.overrideWith(
          (ref) => writableState == null ? writable : ref.watch(writableState),
        ),
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
  'id': requestId,
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
  bool configured = true,
}) => ServerOperationsStatus.fromJson({
  'available': true,
  'manualOnly': true,
  'currentVersion': version,
  'sourceRevision': 'source-r1',
  'sourceConfigured': configured,
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
  Future<ServerUpdateSource> Function()? sourceHandler;
  Future<ServerUpdateJob> Function(String)? jobHandler, cancelHandler;
  Future<ServerUpdateSchedulePreview> Function()? previewHandler;
  Object? startError, saveError, previewError;
  int statusCalls = 0, sourceCalls = 0, latestCalls = 0;
  final jobReads = <String>[];
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
  Future<ServerUpdateJob> job(String id) async {
    jobReads.add(id);
    return jobHandler == null
        ? ServerUpdateJob.fromJson(_job(id))
        : jobHandler!(id);
  }

  @override
  Future<ServerUpdateJob?> latestJob() async {
    latestCalls++;
    return statusValue.latestJob;
  }

  @override
  Future<ServerUpdateSource> source() async {
    sourceCalls++;
    return sourceHandler == null ? _source() : sourceHandler!();
  }

  @override
  Future<ServerUpdateSource> saveSource(Map<String, dynamic> command) async {
    saves.add(Map.of(command));
    if (saveError != null) throw saveError!;
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
    if (cancelHandler != null) return cancelHandler!(jobId);
    return ServerUpdateJob.fromJson(
      _job(jobId, state: 'CANCELLED', mode: 'SCHEDULE_UPDATE'),
    );
  }

  @override
  Future<ServerUpdateSchedulePreview> schedulePreview({
    required String localDate,
    required int hour,
  }) async {
    scheduleChecks.add({'localDate': localDate, 'hour': hour});
    if (previewError != null) throw previewError!;
    if (previewHandler != null) return previewHandler!();
    return ServerUpdateSchedulePreview.fromJson({
      'scheduledAt': '2026-10-15T18:00:00Z',
      'serverTimeZone': 'Asia/Shanghai',
      'displayLocalTime': '2026-10-16 02:00',
    });
  }
}
