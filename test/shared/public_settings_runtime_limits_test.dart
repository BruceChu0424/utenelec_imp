// 公共运行时设置是前端规则的唯一来源 (ADR-110)：附件单文件上限、
// 徽章轮询间隔都按服务端下发的值走；拉取失败时回到与服务端出厂默认一致的兜底值。
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/security/input_validators.dart';
import 'package:uten_imp/features/shell/widgets/idle_timeout_guard.dart';
import 'package:uten_imp/shared/attachments/attachment_file_rules.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_controller.dart';
import 'package:uten_imp/shared/repositories/public_settings_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/idle_timeout_controller.dart';

final _scope = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'current'),
);
final _api = StateProvider<ApiClient>((ref) => throw UnimplementedError());

class _SettingsApi extends ApiClient {
  _SettingsApi() : super(Dio());
  final requests = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) {
    final request = Completer<Map<String, dynamic>>();
    requests.add(request);
    return request.future;
  }
}

ProviderContainer _container(_SettingsApi api) => ProviderContainer(
  overrides: [
    _api.overrideWith((ref) => api),
    apiClientProvider.overrideWith((ref) => ref.watch(_api)),
    authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
  ],
);

void main() {
  tearDown(AttachmentLimits.reset);

  test('模式快照读取异常时展示未知，不让保全说明崩溃或声称已启用', () {
    final container = ProviderContainer(
      overrides: [
        publicSettingsSnapshotProvider.overrideWith((ref) {
          throw StateError('snapshot unavailable');
        }),
      ],
    );
    addTearDown(container.dispose);
    expect(
      container.read(auditArchivePurgeModeProvider),
      AuditArchivePurgeMode.unknown,
    );
  });

  test('审计保全只认服务器能力，缺字段和未知值不假称已保护', () {
    expect(
      PublicSettings.fromJson(const {
        'auditArchivePurgeMode': 'PRESERVE_UNCLASSIFIED',
      }).auditArchivePurgeMode,
      AuditArchivePurgeMode.preserveUnclassified,
    );
    expect(
      PublicSettings.fromJson(const {
        'auditArchivePurgeMode': 'LEGACY_PURGE',
      }).auditArchivePurgeMode,
      AuditArchivePurgeMode.legacyPurge,
    );
    for (final value in [null, 'preserve', true, 1, 'FUTURE_MODE']) {
      expect(
        PublicSettings.fromJson({
          'auditArchivePurgeMode': value,
          'auditReceiptRetentionMonths': 360,
        }).auditArchivePurgeMode,
        AuditArchivePurgeMode.unknown,
      );
    }
    expect(
      PublicSettings.fromJson(const {}).auditArchivePurgeMode,
      AuditArchivePurgeMode.unknown,
    );
  });

  test('公共设置失败撤下已核实保全，但保留其它已知运行阈值', () async {
    final api = _SettingsApi();
    final container = _container(api);
    addTearDown(container.dispose);
    final repository = container.read(publicSettingsRepositoryProvider);
    final first = repository.fetch();
    api.requests.last.complete({
      'auditArchivePurgeMode': 'PRESERVE_UNCLASSIFIED',
      'idleTimeoutMinutes': 90,
      'auditReceiptRetentionMonths': 42,
      'badgePollSeconds': 120,
      'attachmentMaxBytes': 10,
    });
    await first;
    expect(
      container.read(publicSettingsSnapshotProvider)?.auditArchivePurgeMode,
      AuditArchivePurgeMode.preserveUnclassified,
    );
    final failed = repository.fetch();
    final rejected = expectLater(failed, throwsStateError);
    api.requests.last.completeError(StateError('offline'));
    await rejected;
    final snapshot = container.read(publicSettingsSnapshotProvider)!;
    expect(snapshot.auditArchivePurgeMode, AuditArchivePurgeMode.unknown);
    expect(snapshot.idleTimeoutMinutes, 90);
    expect(snapshot.auditReceiptRetentionMonths, 42);
    expect(snapshot.badgePollSeconds, 120);
    expect(snapshot.attachmentMaxBytes, 10);
    expect(AttachmentLimits.maxFileBytes, 10);
  });

  for (final change in ['identity', 'server', 'logout']) {
    test('切换$change后旧设置读取失败不能撤下新主体保全能力', () async {
      final api = _SettingsApi();
      final container = _container(api);
      addTearDown(container.dispose);
      final pending = container.read(publicSettingsRepositoryProvider).fetch();
      final rejected = expectLater(pending, throwsStateError);
      final nextApi = change == 'server' ? _SettingsApi() : api;
      if (change == 'server') {
        container.read(_api.notifier).state = nextApi;
      } else {
        container.read(_scope.notifier).state = change == 'logout'
            ? null
            : const AuthenticatedScope(userId: 'next');
      }
      expect(container.read(publicSettingsSnapshotProvider), isNull);
      if (change != 'logout') {
        final next = container.read(publicSettingsRepositoryProvider).fetch();
        nextApi.requests.last.complete({
          'auditArchivePurgeMode': 'PRESERVE_UNCLASSIFIED',
        });
        await next;
      }
      api.requests.first.completeError(StateError('old server unavailable'));
      await rejected;
      expect(
        container.read(publicSettingsSnapshotProvider)?.auditArchivePurgeMode,
        change == 'logout'
            ? isNull
            : AuditArchivePurgeMode.preserveUnclassified,
      );
    });
  }

  test('公共设置并发读取只请求一次，完成后下一次读取能更新快照', () async {
    final api = _SettingsApi();
    final container = _container(api);
    addTearDown(container.dispose);
    final repository = container.read(publicSettingsRepositoryProvider);
    final first = repository.fetch();
    final second = repository.fetch();
    expect(identical(first, second), isTrue);
    expect(api.requests, hasLength(1));
    api.requests.single.complete({
      'badgePollSeconds': 90,
      'attachmentMaxBytes': 10,
    });
    await first;
    expect(
      container.read(publicSettingsSnapshotProvider)?.badgePollSeconds,
      90,
    );
    expect(AttachmentLimits.maxFileBytes, 10);
    final third = repository.fetch();
    expect(api.requests, hasLength(2));
    api.requests.last.complete({'badgePollSeconds': 120});
    await third;
    expect(
      container.read(publicSettingsSnapshotProvider)?.badgePollSeconds,
      120,
    );
  });

  test('设置读取失败后能重试并保留最近成功快照', () async {
    final api = _SettingsApi();
    final container = _container(api);
    addTearDown(container.dispose);
    final repository = container.read(publicSettingsRepositoryProvider);
    final first = repository.fetch();
    api.requests.last.complete({'badgePollSeconds': 90});
    await first;
    final failed = repository.fetch();
    final rejected = expectLater(failed, throwsStateError);
    api.requests.last.completeError(StateError('offline'));
    await rejected;
    expect(
      container.read(publicSettingsSnapshotProvider)?.badgePollSeconds,
      90,
    );
    final retry = repository.fetch();
    api.requests.last.complete({'badgePollSeconds': 15});
    await retry;
    expect(api.requests, hasLength(3));
    expect(
      container.read(publicSettingsSnapshotProvider)?.badgePollSeconds,
      15,
    );
  });

  for (final change in ['identity', 'server', 'logout']) {
    test('切换$change后旧设置响应不能覆盖新快照或附件上限', () async {
      final api = _SettingsApi();
      final container = _container(api);
      addTearDown(container.dispose);
      final pending = container.read(publicSettingsRepositoryProvider).fetch();
      final nextApi = change == 'server' ? _SettingsApi() : api;
      if (change == 'server') {
        container.read(_api.notifier).state = nextApi;
      } else {
        container.read(_scope.notifier).state = change == 'logout'
            ? null
            : const AuthenticatedScope(userId: 'next');
      }
      expect(container.read(publicSettingsSnapshotProvider), isNull);
      if (change != 'logout') {
        final next = container.read(publicSettingsRepositoryProvider).fetch();
        nextApi.requests.last.complete({
          'badgePollSeconds': 15,
          'attachmentMaxBytes': 100,
        });
        await next;
      }
      api.requests.first.complete({
        'badgePollSeconds': 600,
        'attachmentMaxBytes': 1,
      });
      await pending;
      expect(
        container.read(publicSettingsSnapshotProvider)?.badgePollSeconds,
        change == 'logout' ? isNull : 15,
      );
      expect(
        AttachmentLimits.maxFileBytes,
        change == 'logout' ? kAttachmentMaxFileBytes : 100,
      );
    });
  }

  testWidgets('空闲守卫不应用换身份前的迟到阈值', (tester) async {
    final api = _SettingsApi();
    final container = _container(api);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: IdleTimeoutGuard(child: SizedBox())),
      ),
    );
    expect(api.requests, hasLength(1));
    container.read(_scope.notifier).state = const AuthenticatedScope(
      userId: 'next',
    );
    container.read(idleThresholdVersionProvider.notifier).state++;
    await tester.pump();
    expect(api.requests, hasLength(2));
    api.requests.last.complete({'idleTimeoutMinutes': 90});
    await tester.pump();
    expect(container.read(idleTimeoutProvider).thresholdMinutes, 90);
    api.requests.first.complete({'idleTimeoutMinutes': 1});
    await tester.pump();
    expect(container.read(idleTimeoutProvider).thresholdMinutes, 90);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存设置发生在旧读取途中时必须再读取新值', (tester) async {
    final api = _SettingsApi();
    final container = _container(api);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: IdleTimeoutGuard(child: SizedBox())),
      ),
    );
    container.read(idleThresholdVersionProvider.notifier).state++;
    await tester.pump();
    final requestsAfterSave = api.requests.length;
    api.requests.first.complete({
      'badgePollSeconds': 60,
      'idleTimeoutMinutes': 1,
    });
    await tester.pump();
    final staleThreshold = container.read(idleTimeoutProvider).thresholdMinutes;
    final staleSnapshot = container.read(publicSettingsSnapshotProvider);
    if (api.requests.length > 1) {
      api.requests.last.complete({
        'badgePollSeconds': 90,
        'idleTimeoutMinutes': 90,
      });
      await tester.pump();
    }
    final threshold = container.read(idleTimeoutProvider).thresholdMinutes;
    final settings = container.read(publicSettingsSnapshotProvider);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    expect(requestsAfterSave, 2);
    expect(staleThreshold, 30);
    expect(staleSnapshot, isNull);
    expect(threshold, 90);
    expect(settings?.badgePollSeconds, 90);
  });

  test('解析新增的公共设置字段，缺省时回到出厂默认', () {
    final parsed = PublicSettings.fromJson(const {
      'idleTimeoutMinutes': 20,
      'auditReceiptRetentionMonths': 36,
      'attachmentMaxBytes': 10485760,
      'badgePollSeconds': 90,
    });
    expect(parsed.attachmentMaxBytes, 10485760);
    expect(parsed.badgePollSeconds, 90);

    final fallback = PublicSettings.fromJson(const {});
    expect(fallback.attachmentMaxBytes, kAttachmentMaxFileBytes);
    expect(fallback.badgePollSeconds, 60);
  });

  test('拉到公共设置后，新建单据的附件暂存按服务端上限预检', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: const {'attachmentMaxBytes': 10},
          ),
        ),
      ),
    );

    await DioPublicSettingsRepository(ApiClient(dio)).fetch();

    final controller = PendingAttachmentController();
    expect(controller.maxFileBytes, 10);
    final tooBig = PlatformFile(
      name: '合同.pdf',
      size: 11,
      bytes: Uint8List.fromList(List.filled(11, 1)),
    );
    expect(controller.add(tooBig), contains('超过单文件'));
  });

  test('非正数的上限视为无效，保持原值', () {
    AttachmentLimits.apply(0);
    expect(AttachmentLimits.maxFileBytes, kAttachmentMaxFileBytes);
  });

  test('密码只要求非空，不限制长度或字符组合', () {
    for (final password in ['1', 'a', '密', '!', 'x' * 129, ' 1 ']) {
      expect(InputValidators.password(password), isNull);
    }
    for (final password in [null, '', ' \t\n']) {
      expect(InputValidators.password(password), '密码不能为空');
    }
  });
}
