import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_repository.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_models.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_overlay.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  test('capabilities fail closed and identifiers cannot supply routes', () {
    expect(AiChatCapabilities.fromJson({}).canChat, isFalse);
    expect(AiChatCapabilities.fromJson({'canChat': 'true'}).canChat, isFalse);
    final action = AiChatAction.fromJson({
      'type': 'OPEN_SALES_ORDER_DRAFT',
      'jobId': '../admin?grant=true',
      'route': '/admin/permissions',
    });
    expect(action.jobId, isNull);
    expect(checkedAiChatId('valid-job-1'), 'valid-job-1');
  });

  test('page context strips values and rejects foreign or malformed paths', () {
    expect(
      safeAiChatRoute('/sales/orders/new?customer=secret#amount'),
      '/sales/orders/new',
    );
    for (final unsafe in [
      'https://evil.test/admin',
      '//evil.test/admin',
      'admin',
      '/sales/../admin',
      '/sales/%2Fadmin',
      '/sales//admin',
    ]) {
      expect(safeAiChatRoute(unsafe), isNull, reason: unsafe);
    }
  });

  test(
    'repository sends only supported context and server job references',
    () async {
      final api = _RecordingApi();
      final repository = DioAiChatRepository(api);
      await repository.send(
        message: 'How do I fill this in?',
        previousJobId: 'previous-1',
        currentRoute: '/sales/orders/new?amount=private',
      );
      expect(api.path, '/ai/chat/messages');
      expect(api.body, {
        'message': 'How do I fill this in?',
        'previousJobId': 'previous-1',
        'pageContext': {'route': '/sales/orders/new'},
      });
      await expectLater(
        repository.send(message: 'test', previousJobId: '../../other'),
        throwsFormatException,
      );
      await repository.confirmPermissionGrant('opaque.signed-token');
      expect(api.path, '/ai/chat/permission-grants/confirm');
      expect(api.body, {'proposalId': 'opaque.signed-token'});
    },
  );

  testWidgets('no signed-in identity leaves the business surface unchanged', (
    tester,
  ) async {
    final harness = await _pump(tester, signedOut: true);
    expect(find.byKey(const ValueKey('business-surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-chat-launcher')), findsNothing);
    expect(harness.repository.capabilityCalls, 0);
  });

  testWidgets(
    'launcher moves vertically and chat fits a narrow keyboard viewport',
    (tester) async {
      await _pump(tester, size: const Size(360, 740));
      final launcher = find.byKey(const ValueKey('ai-chat-launcher'));
      final before = tester.getCenter(launcher);
      await tester.drag(launcher, const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(tester.getCenter(launcher).dy, lessThan(before.dy - 80));
      await tester.tap(launcher);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-chat-panel')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('ai-chat-panel'))).width,
        328,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 360);
      await tester.pumpAndSettle();
      expect(
        tester.getBottomRight(find.byKey(const ValueKey('ai-chat-panel'))).dy,
        lessThanOrEqualTo(380),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.5, 2.0]) {
    testWidgets(
      'narrow keyboard viewport remains usable at text scale $scale',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final harness = await _pump(tester, size: const Size(360, 740));
        await _open(tester);
        tester.view.viewInsets = const FakeViewPadding(bottom: 360);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getBottomRight(find.byKey(const ValueKey('ai-chat-panel'))).dy,
          lessThanOrEqualTo(380),
        );
        expect(
          find.byKey(const ValueKey('ai-chat-accessible-scroll')),
          findsOneWidget,
        );
        await tester.ensureVisible(find.byKey(const ValueKey('ai-chat-input')));
        await _send(tester, 'How do I fill in this page?');
        expect(
          harness.repository.messages.single['message'],
          'How do I fill in this page?',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final change in [
    'user',
    'actor',
    'permissions',
    'server',
    'epoch',
    'readonly',
  ]) {
    testWidgets('$change boundary clears text and discards a late reply', (
      tester,
    ) async {
      final pending = Completer<AiJobSnapshot>();
      final repository = _FakeChatRepository()..pending = pending;
      final harness = await _pump(tester, repository: repository);
      await _open(tester);
      await _send(tester, 'Private production question');
      expect(repository.messages, hasLength(1));
      final next = switch (change) {
        'user' => _identity(user: 'bob'),
        'actor' => _identity(actor: 'admin'),
        'permissions' => _identity(permissions: 'ai:use'),
        'server' => _identity(server: 'https://other.test/api'),
        'epoch' => _identity(epoch: 2),
        _ => _identity(readOnly: true),
      };
      harness.container.read(harness.identity.notifier).state = next;
      await tester.pumpAndSettle();
      pending.complete(_success('Private old answer'));
      await tester.pumpAndSettle();
      await _open(tester);
      expect(find.text('Private production question'), findsNothing);
      expect(find.text('Private old answer'), findsNothing);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'page follows navigation and can be disabled without sending form values',
    (tester) async {
      final harness = await _pump(tester);
      await _open(tester);
      await _send(tester, 'First question');
      expect(
        harness.repository.messages.last['currentRoute'],
        '/sales/orders/new',
      );
      harness.container.read(harness.route.notifier).state =
          '/production/plans/new?private=value';
      await tester.pumpAndSettle();
      await _send(tester, 'Second question');
      expect(
        harness.repository.messages.last['currentRoute'],
        '/production/plans/new',
      );
      expect(harness.repository.messages.last['previousJobId'], 'chat-job-1');
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await _send(tester, 'Third question');
      expect(harness.repository.messages.last['currentRoute'], isNull);
    },
  );

  testWidgets(
    'permission grants require a concrete review and a separate confirm',
    (tester) async {
      final repository = _FakeChatRepository()..actions = [_grant()];
      await _pump(
        tester,
        repository: repository,
        initial: _identity(superAdmin: true),
      );
      await _open(tester);
      await _send(tester, 'Grant access to the employee');
      final review = find.text('Review authorization');
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(repository.confirmations, isEmpty);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('Warehouse employee'), findsWidgets);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(repository.confirmations, isEmpty);
      await tester.tap(review);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm').last);
      await tester.pumpAndSettle();
      expect(repository.confirmations, ['opaque.signed.token']);
      expect(find.text('Permission granted'), findsOneWidget);
    },
  );

  testWidgets('identity change closes an open authorization confirmation', (
    tester,
  ) async {
    final repository = _FakeChatRepository()..actions = [_grant()];
    final harness = await _pump(
      tester,
      repository: repository,
      initial: _identity(superAdmin: true),
    );
    await _open(tester);
    await _send(tester, 'Grant access');
    final review = find.text('Review authorization');
    await tester.ensureVisible(review);
    await tester.tap(review);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    harness.container.read(harness.identity.notifier).state = _identity(
      user: 'bob',
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('Warehouse employee'), findsNothing);
    expect(repository.confirmations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown actions and malicious job routes cannot navigate', (
    tester,
  ) async {
    final repository = _FakeChatRepository()
      ..actions = [
        {
          'type': 'EXECUTE_SQL',
          'title': 'Unexpected command',
          'route': '/admin',
          'summary': 'Ignored',
        },
        {
          'type': 'OPEN_SALES_ORDER_DRAFT',
          'title': 'Unsafe draft',
          'jobId': '../admin',
        },
      ];
    await _pump(tester, repository: repository);
    await _open(tester);
    await _send(tester, 'Test');
    expect(find.text('Review and create order'), findsNothing);
    expect(repository.confirmations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'file to order keeps its source and uses the existing review route',
    (tester) async {
      final file = PlatformFile(
        name: 'quotation.xlsx',
        size: 4,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      FilePicker.platform = _Picker(file);
      addTearDown(() => FilePicker.platform = _Picker(null));
      final repository = _FakeChatRepository()
        ..actions = [
          {
            'type': 'OPEN_SALES_ORDER_DRAFT',
            'title': 'Prepare order',
            'summary': 'Review the imported lines.',
            'jobId': 'file-job-1',
            'route': '/admin/permissions',
          },
        ];
      final jobs = _FakeJobRepository();
      Object? handedFile;
      Uri? destination;
      final harness = await _pump(
        tester,
        repository: repository,
        jobs: jobs,
        onDraftOpened: (uri, extra) {
          destination = uri;
          handedFile = extra;
        },
      );
      await _open(tester);
      await tester.tap(find.byTooltip('Attach a quotation'));
      await tester.pumpAndSettle();
      expect(find.text('quotation.xlsx'), findsOneWidget);
      await _send(tester, 'Prepare an order');
      expect(jobs.requests, hasLength(1));
      expect(jobs.requests.single.kind, 'SALES_DOCUMENT_INTAKE');
      expect(jobs.requests.single.params, {'docType': 'order'});
      expect(jobs.requests.single.bytes, file.bytes);
      expect(
        harness.repository.messages.single['attachmentJobId'],
        'file-job-1',
      );
      final review = find.text('Review and create order');
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(destination?.path, '/sales/orders/new');
      expect(destination?.queryParameters, {'aiJobId': 'file-job-1'});
      expect(handedFile, same(file));
      expect(repository.confirmations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

Map<String, dynamic> _grant() => {
  'type': 'CONFIRM_PERMISSION_GRANT',
  'proposalId': 'opaque.signed.token',
  'title': 'Grant one permission',
  'summary': 'Review the proposal',
  'targetName': 'Warehouse employee',
  'permissionCode': 'stock:view',
  'permissionName': 'View inventory',
  'scopeSummary': 'Existing warehouse scope',
  'expiresAt': DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
};

AiChatIdentity _identity({
  String user = 'alice',
  String? actor,
  bool readOnly = false,
  int epoch = 1,
  String server = 'https://example.test/api',
  String permissions = 'ai:use\nsales_order:create',
  bool superAdmin = false,
}) => (
  scope: AuthenticatedScope(
    userId: user,
    actorId: actor,
    readOnly: readOnly,
    epoch: epoch,
  ),
  server: server,
  permissions: permissions,
  superAdmin: superAdmin,
);

AiJobSnapshot _success(
  String reply, {
  String id = 'chat-job-1',
  List<Map<String, dynamic>> actions = const [],
}) => AiJobSnapshot(
  id: id,
  kind: 'ERP_CHAT',
  status: AiJobStatus.succeeded,
  result: {'reply': reply, 'actions': actions},
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('ai-chat-launcher')));
  await tester.pumpAndSettle();
}

Future<void> _send(WidgetTester tester, String message) async {
  await tester.enterText(find.byKey(const ValueKey('ai-chat-input')), message);
  await tester.pump();
  await tester.ensureVisible(find.byKey(const ValueKey('ai-chat-send')));
  await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
  // Pending requests have a progress ticker, so do not pumpAndSettle here.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<_Harness> _pump(
  WidgetTester tester, {
  AiChatIdentity? initial,
  bool signedOut = false,
  _FakeChatRepository? repository,
  _FakeJobRepository? jobs,
  void Function(Uri, Object?)? onDraftOpened,
  Size size = const Size(1000, 850),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  final actualInitial = signedOut ? null : initial ?? _identity();
  final identity = StateProvider<AiChatIdentity?>((ref) => actualInitial);
  final route = StateProvider<String>((ref) => '/sales/orders/new');
  final repo = repository ?? _FakeChatRepository();
  final container = ProviderContainer(
    overrides: [
      aiChatIdentityProvider.overrideWith((ref) => ref.watch(identity)),
      aiChatRepositoryProvider.overrideWithValue(repo),
      aiJobRunnerProvider.overrideWithValue(
        AiJobRunner(jobs ?? _FakeJobRepository()),
      ),
      currentPermissionsProvider.overrideWith(
        (ref) => (ref.watch(identity)?.permissions ?? '').split('\n').toSet(),
      ),
    ],
  );
  addTearDown(container.dispose);
  final home = Consumer(
    builder: (context, ref, _) => AiChatOverlay(
      currentRoute: ref.watch(route),
      child: const Scaffold(body: SizedBox(key: ValueKey('business-surface'))),
    ),
  );
  final router = onDraftOpened == null
      ? null
      : GoRouter(
          routes: [
            GoRoute(path: '/', builder: (context, state) => home),
            GoRoute(
              path: '/sales/orders/new',
              builder: (context, state) {
                onDraftOpened(state.uri, state.extra);
                return const Scaffold(body: Text('Order review handoff'));
              },
            ),
          ],
        );
  if (router != null) addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: router != null
          ? MaterialApp.router(
              routerConfig: router,
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            )
          : MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: home,
            ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(container, identity, route, repo);
}

class _Harness {
  const _Harness(this.container, this.identity, this.route, this.repository);
  final ProviderContainer container;
  final StateProvider<AiChatIdentity?> identity;
  final StateProvider<String> route;
  final _FakeChatRepository repository;
}

class _FakeChatRepository implements AiChatRepository {
  final messages = <Map<String, String?>>[];
  final confirmations = <String>[];
  List<Map<String, dynamic>> actions = [];
  Completer<AiJobSnapshot>? pending;
  int capabilityCalls = 0;

  @override
  Future<AiChatCapabilities> capabilities() async {
    capabilityCalls++;
    return const AiChatCapabilities(
      canChat: true,
      available: true,
      canUploadSalesOrder: true,
      canManagePermissions: true,
      scopeSummary: 'Only data permitted for this account.',
    );
  }

  @override
  Future<AiJobSnapshot> send({
    required String message,
    String? previousJobId,
    String? attachmentJobId,
    String? currentRoute,
  }) async {
    messages.add({
      'message': message,
      'previousJobId': previousJobId,
      'attachmentJobId': attachmentJobId,
      'currentRoute': currentRoute,
    });
    return pending?.future ??
        Future.value(
          _success(
            'Scoped answer ${messages.length}',
            id: 'chat-job-${messages.length}',
            actions: actions,
          ),
        );
  }

  @override
  Future<String> confirmPermissionGrant(String proposalId) async {
    confirmations.add(proposalId);
    return 'Permission granted';
  }
}

class _RecordingApi extends ApiClient {
  _RecordingApi() : super(Dio());
  String? path;
  Object? body;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.body = body;
    return path.endsWith('/confirm')
        ? {'status': 'GRANTED', 'reply': 'Done'}
        : {'jobId': 'job-1', 'status': 'PENDING'};
  }
}

class _FakeJobRepository implements AiJobRepository {
  final requests = <AiJobRequest>[];
  @override
  Future<void> cancel(String jobId) async {}
  @override
  Future<AiJobSnapshot> get(String jobId) async =>
      _success('Scoped answer', id: jobId);
  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) async {
    requests.add(request);
    return _success('File read', id: 'file-job-1');
  }
}

class _Picker extends FilePicker {
  _Picker(this.file);
  final PlatformFile? file;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => file == null ? null : FilePickerResult([file!]);
}
