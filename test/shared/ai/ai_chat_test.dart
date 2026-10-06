import 'dart:async';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_en.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/dashboard/models/dashboard_overview.dart';
import 'package:uten_imp/features/dashboard/pages/dashboard_page.dart';
import 'package:uten_imp/features/dashboard/providers/dashboard_overview_provider.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/settings/pages/settings_page.dart';
import 'package:uten_imp/features/shell/pages/main_shell_page.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_action_card.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/ai/page_context/ai_page_context.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/repositories/public_settings_repository.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_repository.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_models.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_overlay.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_repository.dart';
import 'package:uten_imp/shared/ai/guided/ai_guided_file_plan.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _p1 = '39a3c832-b0e5-4fe2-8040-7cb4247741b9';
const _p2 = '5f0c7a3e-2b1d-4c8e-9a6f-0d1e2f3a4b5c';
const _docCard = '7a6b5c4d-3e2f-4a1b-8c9d-0e1f2a3b4c5d';
const _docCard2 = '8b7c6d5e-4f3a-4b2c-9d0e-1f2a3b4c5d6e';
const _c1 = '0b5c43f4-5ad4-4e5b-9e4f-2f6f3b0f7a11';
final _en = AppLocalizationsEn();

/// Server-side state of every card the fakes know about (chat + file jobs).
final _serverCards = <String, Map<String, dynamic>>{};

void main() {
  setUp(_serverCards.clear);

  test(
    'cards fail closed: unknown types, ids, handlers and routes are dropped',
    () {
      expect(AiChatCapabilities.fromJson({}).canChat, isFalse);
      expect(AiChatCapabilities.fromJson({'canChat': 'true'}).canChat, isFalse);
      expect(AiChatAction.tryParse(_card()), isNotNull);
      for (final bad in [
        {..._card(), 'type': 'OPEN_SALES_ORDER_DRAFT'},
        {..._card(), 'actionType': 'EXECUTE_SQL'},
        {..._card(), 'proposalId': '../admin?grant=true'},
        {..._card(), 'handler': 'drop table'},
        {..._card(), 'route': 'https://evil.test/admin'},
        {..._card(), 'route': '/admin?x=1'},
        {..._card(), 'summaryLines': <String>[]},
        {..._card(), 'status': 'DONE'},
        {..._card(), 'execution': 'BROWSER'},
      ]) {
        expect(AiChatAction.tryParse(bad), isNull, reason: '$bad');
      }
      final reply = AiChatReply.fromJson({
        'reply': 'ok',
        'fallback': true,
        'sources': [
          {'id': 'page.legend', 'label': 'Current page colours'},
          {'id': 'x', 'label': ''},
          'bad',
        ],
        'actions': [
          _card(),
          {'type': 'CONFIRM_PERMISSION_GRANT'},
        ],
      });
      expect(reply.fallback, isTrue);
      expect(reply.sources.map((source) => source.label), [
        'Current page colours',
      ]);
      expect(reply.actions.single.proposalId, _p1);
      expect(checkedAiChatId('valid-job-1'), 'valid-job-1');
    },
  );

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
    'repository sends the route with the bounded snapshot and uses UUID card endpoints',
    () async {
      final api = _RecordingApi();
      final repository = DioAiChatRepository(api);
      await repository.send(
        message: 'How do I fill this in?',
        conversationId: _c1.toUpperCase(),
        currentRoute: '/sales/orders/new?amount=private',
        snapshot: const {'version': 1, 'title': 'Order'},
        locale: 'en',
      );
      expect(api.path, '/ai/chat/messages');
      expect(api.body, {
        'message': 'How do I fill this in?',
        'conversationId': _c1,
        'locale': 'en',
        'pageContext': {
          'route': '/sales/orders/new',
          'snapshot': {'version': 1, 'title': 'Order'},
        },
      });
      // Without a sendable route nothing about the page is sent; unknown
      // interface languages are not sent either.
      await repository.send(
        message: 'Hi',
        conversationId: _c1,
        currentRoute: 'https://evil.test',
        snapshot: const {'title': 'x'},
        locale: 'fr',
      );
      expect(api.body, {'message': 'Hi', 'conversationId': _c1});
      await expectLater(
        repository.send(message: 'test', conversationId: '../../other'),
        throwsFormatException,
      );
      await expectLater(
        repository.conversation(conversationId: '../x'),
        throwsFormatException,
      );
      api.cardResult = {
        ..._card(status: 'CONFIRMED'),
        'args': {'row': 3},
      };
      final confirmed = await repository.confirmAction(_p1.toUpperCase());
      expect(api.path, '/ai/chat/actions/$_p1/confirm');
      expect(confirmed.args, {'row': 3});
      api.cardResult = _card(status: 'CONFIRMED', outcome: 'SUCCEEDED');
      await repository.actionReceipt(_p1, succeeded: true, message: ' Done ');
      expect(api.path, '/ai/chat/actions/$_p1/receipt');
      expect(api.body, {'outcome': 'SUCCEEDED', 'message': 'Done'});
      api.cardResult = _card(status: 'CANCELLED');
      await repository.cancelAction(_p1);
      expect(api.path, '/ai/chat/actions/$_p1/cancel');
      api.cardResult = _card(id: _p2);
      await expectLater(repository.actionStatus(_p1), throwsFormatException);
      await expectLater(
        repository.confirmAction('../admin'),
        throwsFormatException,
      );
      await repository.confirmPermissionGrant(_p2);
      expect(api.path, '/ai/chat/permission-grants/confirm');
      expect(api.body, {'proposalId': _p2});
      await expectLater(
        repository.confirmPermissionGrant('opaque.signed.token'),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'the composer says what will be attached and the message carries the page snapshot',
    (tester) async {
      final harness = await _pump(tester, page: const _OrderPage());
      await _open(tester);
      expect(
        find.text(_en.aiChatAttachSummary(0, 2, 0)),
        findsOneWidget,
        reason: 'two inputs; the password field is never attached',
      );
      await _send(tester, 'Which values must I check?');
      final sent = harness.repository.messages.single;
      expect(sent['currentRoute'], '/sales/orders/new');
      final snapshot = sent['snapshot']! as Map<String, Object?>;
      final fields = (snapshot['fields']! as List).cast<Map<String, Object?>>();
      expect(fields.map((field) => field['label']), ['Customer', 'Quantity']);
      expect(fields.first['state'], 'REQUIRED_EMPTY');
      expect(snapshot.toString(), isNot(contains('hunter2')));
      expect(
        (snapshot['pageActions']! as List).map(
          (action) => (action as Map)['name'],
        ),
        containsAll(['setLineField', 'setField']),
      );
      // Page awareness off: neither the route nor the snapshot is sent.
      await _togglePageAware(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ai-chat-attach-preview')),
        findsNothing,
      );
      await _send(tester, 'Generic question');
      expect(harness.repository.messages.last['currentRoute'], isNull);
      expect(harness.repository.messages.last['snapshot'], isNull);
    },
  );

  testWidgets(
    'a fallback reply shows its basis and that the page is authoritative',
    (tester) async {
      final repository = _FakeChatRepository()
        ..extraResult = {
          'fallback': true,
          'sources': [
            {'id': 'page.legend', 'label': 'Current page colours'},
          ],
        };
      await _pump(tester, repository: repository);
      await _open(tester);
      await _send(tester, 'What do the colours mean?');
      await tester.pumpAndSettle();
      expect(find.text(_en.aiChatFallback), findsOneWidget);
      expect(
        find.text(
          '${_en.aiChatSources('Current page colours')} · ${_en.aiChatVerifyOnPage}',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a page action runs only after confirm, with the confirmed arguments, and records one receipt',
    (tester) async {
      final executed = <Map<String, Object?>>[];
      final repository = _FakeChatRepository()
        ..actions = [_card()]
        ..confirmArgs = {'row': 3, 'field': 'Quantity', 'value': '100'};
      await _pump(
        tester,
        repository: repository,
        page: _OrderPage(onSetLine: executed.add),
      );
      await _open(tester);
      await _send(tester, 'Change row 3 quantity to 100');
      await tester.pumpAndSettle();
      expect(find.text('Row: 3 (V50003)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-action-countdown-$_p1')),
        findsOneWidget,
      );
      expect(executed, isEmpty, reason: 'nothing runs before confirmation');
      expect(repository.actionCalls, isEmpty);
      await _tapCard(tester, 'ai-action-confirm-$_p1');
      expect(repository.actionCalls, [
        'confirm:$_p1',
        'receipt:$_p1:SUCCEEDED',
      ]);
      expect(executed, [
        {'row': 3, 'field': 'Quantity', 'value': '100'},
      ]);
      expect(find.text(_en.aiChatCardSucceeded), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-action-confirm-$_p1')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'a retry after switching page awareness off sends only the question',
    (tester) async {
      final repository = _FakeChatRepository()
        ..sendFailure = NetworkException();
      await _pump(tester, repository: repository, page: const _OrderPage());
      await _open(tester);
      await _send(tester, 'Which values must I check?');
      await tester.pumpAndSettle();
      expect(repository.messages.single['snapshot'], isNotNull);
      repository.sendFailure = null;
      await _togglePageAware(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('ai-chat-retry-1')));
      await tester.tap(find.byKey(const ValueKey('ai-chat-retry-1')));
      await tester.pumpAndSettle();
      final retried = repository.messages.last;
      expect(retried['message'], 'Which values must I check?');
      expect(retried['currentRoute'], isNull);
      expect(retried['snapshot'], isNull);
      expect(retried['intentHint'], isNull);
    },
  );

  testWidgets('payroll and personal pages attach nothing but the question', (
    tester,
  ) async {
    final harness = await _pump(tester, page: const _OrderPage());
    harness.container.read(harness.route.notifier).state = '/payroll/review';
    await tester.pumpAndSettle();
    await _open(tester);
    expect(find.text(_en.aiChatAttachWithheld), findsOneWidget);
    await _send(tester, 'What is on this page?');
    final sent = harness.repository.messages.single;
    expect(sent['currentRoute'], '/payroll/review');
    expect(sent['snapshot'], isNull);
  });

  testWidgets(
    'system administration pages attach nothing and run no card (ADR-153)',
    (tester) async {
      final repository = _FakeChatRepository()
        ..actions = [_card(route: '/admin/ai-settings')];
      final harness = await _pump(
        tester,
        repository: repository,
        page: const _OrderPage(),
      );
      harness.container.read(harness.route.notifier).state =
          '/admin/ai-settings';
      await tester.pumpAndSettle();
      await _open(tester);
      expect(find.text(_en.aiChatAttachProtected), findsOneWidget);
      await _send(tester, 'Save this page for me');
      await tester.pumpAndSettle();
      final sent = harness.repository.messages.single;
      expect(sent['currentRoute'], '/admin/ai-settings');
      expect(sent['snapshot'], isNull);
      await _tapCard(tester, 'ai-action-confirm-$_p1');
      expect(repository.actionCalls, isEmpty);
      expect(find.text(_en.aiChatCardProtectedPage), findsOneWidget);
    },
  );

  testWidgets('a card does not run on another instance of the same page', (
    tester,
  ) async {
    final executed = <Map<String, Object?>>[];
    final generation = ValueNotifier(0);
    addTearDown(generation.dispose);
    final repository = _FakeChatRepository()
      ..actions = [_card()]
      ..confirmArgs = {'row': 3, 'field': 'Quantity', 'value': '100'};
    await _pump(
      tester,
      repository: repository,
      page: ValueListenableBuilder<int>(
        valueListenable: generation,
        builder: (_, value, _) =>
            _OrderPage(key: ValueKey(value), onSetLine: executed.add),
      ),
    );
    await _open(tester);
    await _send(tester, 'Change row 3 quantity to 100');
    await tester.pumpAndSettle();
    // The user saved and opened another new order on the same route.
    generation.value++;
    await tester.pumpAndSettle();
    await _tapCard(tester, 'ai-action-confirm-$_p1');
    expect(executed, isEmpty);
    expect(repository.actionCalls, ['confirm:$_p1', 'receipt:$_p1:FAILED']);
    expect(repository.receiptMessages[_p1], _en.aiChatCardPageChanged);
  });

  testWidgets('a double click confirms the card exactly once', (tester) async {
    final gate = Completer<void>();
    final executed = <Map<String, Object?>>[];
    final repository = _FakeChatRepository()
      ..actions = [_card()]
      ..confirmGate = gate;
    await _pump(
      tester,
      repository: repository,
      page: _OrderPage(onSetLine: executed.add),
    );
    await _open(tester);
    await _send(tester, 'Change row 3');
    await tester.pumpAndSettle();
    final confirm = find.byKey(const ValueKey('ai-action-confirm-$_p1'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('ai-action-running-$_p1')),
      findsOneWidget,
    );
    expect(confirm, findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(
      repository.actionCalls.where((call) => call.startsWith('confirm')),
      hasLength(1),
    );
    expect(executed, hasLength(1));
  });

  testWidgets('cancel closes the card without running anything', (
    tester,
  ) async {
    final executed = <Map<String, Object?>>[];
    final repository = _FakeChatRepository()..actions = [_card()];
    await _pump(
      tester,
      repository: repository,
      page: _OrderPage(onSetLine: executed.add),
    );
    await _open(tester);
    await _send(tester, 'Change row 3');
    await tester.pumpAndSettle();
    await _tapCard(tester, 'ai-action-cancel-$_p1');
    expect(repository.actionCalls, ['cancel:$_p1']);
    expect(executed, isEmpty);
    expect(find.text(_en.aiChatCardCancelled), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-action-confirm-$_p1')), findsNothing);
  });

  testWidgets('an expired card shows why and offers no buttons', (
    tester,
  ) async {
    final repository = _FakeChatRepository()
      ..actions = [_card(ttl: const Duration(seconds: -5))];
    await _pump(tester, repository: repository, page: const _OrderPage());
    await _open(tester);
    await _send(tester, 'Change row 3');
    await tester.pumpAndSettle();
    expect(find.text(_en.aiChatCardExpired), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-action-confirm-$_p1')), findsNothing);
    expect(repository.actionCalls, isEmpty);
  });

  testWidgets(
    'a card for another page is refused locally before anything is consumed',
    (tester) async {
      final repository = _FakeChatRepository()
        ..actions = [_card(route: '/sales/quotes/new')];
      await _pump(tester, repository: repository, page: const _OrderPage());
      await _open(tester);
      await _send(tester, 'Change row 3');
      await tester.pumpAndSettle();
      await _tapCard(tester, 'ai-action-confirm-$_p1');
      expect(repository.actionCalls, isEmpty);
      expect(find.text(_en.aiChatCardWrongPage), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-action-confirm-$_p1')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a handler failure is reported as a FAILED receipt with its reason',
    (tester) async {
      final repository = _FakeChatRepository()..actions = [_card()];
      await _pump(
        tester,
        repository: repository,
        page: _OrderPage(
          onSetLine: (_) =>
              throw const AiActionFailure('Row 3 has no item yet'),
        ),
      );
      await _open(tester);
      await _send(tester, 'Change row 3');
      await tester.pumpAndSettle();
      await _tapCard(tester, 'ai-action-confirm-$_p1');
      expect(repository.actionCalls, ['confirm:$_p1', 'receipt:$_p1:FAILED']);
      expect(repository.receiptMessages[_p1], 'Row 3 has no item yet');
      expect(find.text(_en.aiChatCardFailed), findsOneWidget);
      expect(find.text('Row 3 has no item yet'), findsOneWidget);
    },
  );

  testWidgets(
    'an identity change seen by the server voids the card instead of running it',
    (tester) async {
      final executed = <Map<String, Object?>>[];
      final repository = _FakeChatRepository()
        ..actions = [_card()]
        ..confirmFailure = ApiException(
          'CONFLICT',
          'Access changed',
          httpStatus: 409,
          fieldErrors: const [
            ApiFieldError(
              field: 'errorCode',
              message: 'AI_ACTION_AUTH_CHANGED',
            ),
          ],
        )
        ..afterConfirmFailure = {
          'status': 'CANCELLED',
          'outcome': 'AUTH_CHANGED',
        };
      await _pump(
        tester,
        repository: repository,
        page: _OrderPage(onSetLine: executed.add),
      );
      await _open(tester);
      await _send(tester, 'Change row 3');
      await tester.pumpAndSettle();
      await _tapCard(tester, 'ai-action-confirm-$_p1');
      expect(repository.actionCalls, ['confirm:$_p1', 'status:$_p1']);
      expect(executed, isEmpty);
      expect(find.text(_en.aiChatCardAuthChanged), findsOneWidget);
    },
  );

  testWidgets(
    'an unknown network result offers a status check and never confirms twice',
    (tester) async {
      final repository = _FakeChatRepository()
        ..actions = [_card()]
        ..confirmFailure = NetworkException();
      await _pump(tester, repository: repository, page: const _OrderPage());
      await _open(tester);
      await _send(tester, 'Change row 3');
      await tester.pumpAndSettle();
      await _tapCard(tester, 'ai-action-confirm-$_p1');
      expect(find.text(_en.aiChatCardUnknown), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-action-confirm-$_p1')),
        findsNothing,
      );
      _serverCards[_p1] = {..._serverCards[_p1]!, 'status': 'CONFIRMED'};
      await _tapCard(tester, 'ai-action-check-$_p1');
      expect(repository.actionCalls, ['confirm:$_p1', 'status:$_p1']);
      expect(find.text(_en.aiChatCardConfirmed), findsOneWidget);
    },
  );

  testWidgets(
    'super-admin grant card uses the step-up endpoint once and shows the result',
    (tester) async {
      final repository = _FakeChatRepository()..actions = [_grant()];
      await _pump(
        tester,
        repository: repository,
        initial: _identity(superAdmin: true),
      );
      await _open(tester);
      await _send(tester, 'Grant inventory access to the warehouse employee');
      await tester.pumpAndSettle();
      expect(find.text('Person: Warehouse employee'), findsOneWidget);
      expect(find.text(_en.aiChatCardStepUp), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-action-risk-$_p2')), findsOneWidget);
      expect(repository.confirmations, isEmpty);
      await _tapCard(tester, 'ai-action-confirm-$_p2');
      expect(repository.confirmations, [_p2]);
      expect(repository.actionCalls, ['status:$_p2']);
      expect(find.text('Permission granted'), findsOneWidget);
      expect(find.text(_en.aiChatCardSucceeded), findsOneWidget);
    },
  );

  testWidgets('an identity change discards cards and late replies', (
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
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-action-card-$_p2')), findsOneWidget);
    harness.container.read(harness.identity.notifier).state = _identity(
      user: 'bob',
      superAdmin: true,
    );
    await tester.pumpAndSettle();
    await _open(tester);
    expect(find.byKey(const ValueKey('ai-action-card-$_p2')), findsNothing);
    expect(find.textContaining('Warehouse employee'), findsNothing);
    expect(repository.confirmations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown or legacy actions never render or navigate', (
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
        {'type': 'CONFIRM_PERMISSION_GRANT', 'proposalId': 'opaque.token'},
      ];
    await _pump(tester, repository: repository);
    await _open(tester);
    await _send(tester, 'Test');
    await tester.pumpAndSettle();
    expect(find.text('Unexpected command'), findsNothing);
    expect(find.text('Unsafe draft'), findsNothing);
    expect(repository.confirmations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'file-only invoice uses a neutral request and opens expense only after the card is confirmed',
    (tester) async {
      final file = PlatformFile(
        name: 'invoice.pdf',
        size: 4,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      FilePicker.platform = _Picker(file);
      addTearDown(() => FilePicker.platform = _Picker(null));
      final jobs = _FakeJobRepository()
        ..routeOverride = {
          'workflow': 'EXPENSE_CLAIM',
          'documentType': 'INVOICE',
          'title': 'Prepare expense',
        };
      Uri? opened;
      final harness = await _pump(
        tester,
        jobs: jobs,
        initial: _identity(permissions: 'ai:use\nexpense:apply'),
        onDraftOpened: (uri, extra) => opened = uri,
      );
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
      await tester.pumpAndSettle();
      await _send(tester, '');
      await tester.pumpAndSettle();
      expect(
        jobs.requests.single.params['message'],
        AppLocalizationsEn().aiChatAttachmentQuestion,
      );
      expect(
        opened,
        isNull,
        reason: 'recognition never opens a page by itself',
      );
      expect(
        find.byKey(const ValueKey('ai-action-card-$_docCard')),
        findsOneWidget,
      );
      await _tapCard(tester, 'ai-action-confirm-$_docCard');
      expect(opened?.path, '/expense/new');
      expect(harness.repository.messages, isEmpty);
      expect(harness.repository.actionCalls, [
        'confirm:$_docCard',
        'receipt:$_docCard:SUCCEEDED',
      ]);
      expect(jobs.reads, ['file-job-1']);
    },
  );

  testWidgets(
    'long file instructions are cut for the server and nothing opens automatically',
    (tester) async {
      final file = PlatformFile(
        name: 'quote.csv',
        size: 4,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      FilePicker.platform = _Picker(file);
      addTearDown(() => FilePicker.platform = _Picker(null));
      final jobs = _FakeJobRepository();
      var opens = 0;
      await _pump(tester, jobs: jobs, onDraftOpened: (_, _) => opens++);
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
      await tester.pumpAndSettle();
      await _send(
        tester,
        '${List.filled(550, 'x').join()} Analyze only. Do not create anything.',
      );
      await tester.pumpAndSettle();
      expect(
        jobs.requests.single.params['message']!.length,
        lessThanOrEqualTo(512),
      );
      expect(opens, 0);
    },
  );

  for (final page in [
    (
      route: '/sales/quotes/new?customer=private#total',
      enabled: true,
      expected: '/sales/quotes/new',
    ),
    (route: '/sales/orders/new', enabled: false, expected: null),
    (
      route: 'https://foreign.invalid/sales/orders/new',
      enabled: true,
      expected: null,
    ),
    (route: '/${'a' * 240}', enabled: true, expected: null),
  ]) {
    testWidgets(
      'document page context is optional and bounded: ${page.route}',
      (tester) async {
        final file = PlatformFile(
          name: 'quote.csv',
          size: 4,
          bytes: Uint8List.fromList([1, 2, 3, 4]),
        );
        FilePicker.platform = _Picker(file);
        addTearDown(() => FilePicker.platform = _Picker(null));
        final jobs = _FakeJobRepository();
        AiGuidedFilePlan? opened;
        final harness = await _pump(
          tester,
          jobs: jobs,
          onDraftOpened: (_, extra) => opened = extra as AiGuidedFilePlan,
        );
        harness.container.read(harness.route.notifier).state = page.route;
        await tester.pump();
        await _open(tester);
        if (!page.enabled) {
          await _togglePageAware(tester);
          await tester.pump();
        }
        await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
        await tester.pumpAndSettle();
        await _send(tester, 'Prepare this document');
        await tester.pumpAndSettle();
        expect(jobs.requests.single.params, {
          'message': 'Prepare this document',
          'pageRoute': ?page.expected,
        });
        expect(opened, isNull);
        await _tapCard(tester, 'ai-action-confirm-$_docCard');
        expect(opened?.pageRoute, page.expected);
      },
    );
  }

  for (final scenario in [
    'unsupported',
    'revoked',
    'changed_identity',
    'retry',
  ]) {
    testWidgets(
      'document route $scenario cannot navigate or write unexpectedly',
      (tester) async {
        final file = PlatformFile(
          name: 'quote.csv',
          size: 4,
          bytes: Uint8List.fromList([1, 2, 3, 4]),
        );
        FilePicker.platform = _Picker(file);
        addTearDown(() => FilePicker.platform = _Picker(null));
        final jobs = _FakeJobRepository();
        var opens = 0;
        if (scenario == 'unsupported') {
          jobs.routeOverride = {
            'workflow': 'NONE',
            'needsChoice': true,
            'choices': <Object>[],
          };
        }
        if (scenario == 'changed_identity') {
          jobs.pendingRead = Completer<AiJobSnapshot>();
        }
        if (scenario == 'retry') jobs.submitFailure = NetworkException();
        final harness = await _pump(
          tester,
          jobs: jobs,
          onDraftOpened: (_, _) => opens++,
        );
        await _open(tester);
        await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
        await tester.pumpAndSettle();
        await _send(tester, 'Prepare this document');
        if (scenario == 'changed_identity') {
          harness.container.read(harness.identity.notifier).state = _identity(
            user: 'bob',
          );
          await tester.pump();
          jobs.pendingRead!.complete(jobs.routed!);
        }
        await tester.pumpAndSettle();
        if (scenario == 'unsupported') {
          expect(
            find.byKey(const ValueKey('ai-action-card-$_docCard')),
            findsNothing,
          );
        }
        if (scenario == 'revoked') {
          // The source job read is refused at confirmation: the card records
          // a failed receipt and no page opens.
          jobs.readFailure = ApiException(
            'FORBIDDEN',
            'Access changed',
            httpStatus: 403,
          );
          await _tapCard(tester, 'ai-action-confirm-$_docCard');
          expect(
            harness.repository.actionCalls.last,
            'receipt:$_docCard:FAILED',
          );
          expect(find.text('Access changed'), findsWidgets);
        }
        expect(opens, 0);
        expect(harness.repository.messages, isEmpty);
        if (scenario == 'retry') {
          jobs.submitFailure = null;
          harness.container.read(harness.route.notifier).state =
              '/sales/quotes/new';
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('ai-chat-retry-1')));
          await tester.pumpAndSettle();
          expect(opens, 0);
          expect(jobs.requests, hasLength(2));
          expect(jobs.requests.first.bytes, jobs.requests.last.bytes);
          expect(jobs.requests.last.params, jobs.requests.first.params);
          expect(jobs.requests.last.params['pageRoute'], '/sales/orders/new');
          await _tapCard(tester, 'ai-action-confirm-$_docCard');
          expect(opens, 1);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'file first routes as a document and opens a typed unsaved order only after confirmation',
    (tester) async {
      final file = PlatformFile(
        name: 'quotation.xlsx',
        size: 4,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      FilePicker.platform = _Picker(file);
      addTearDown(() => FilePicker.platform = _Picker(null));
      final jobs = _FakeJobRepository();
      Object? handedFile;
      Uri? destination;
      final harness = await _pump(
        tester,
        jobs: jobs,
        onDraftOpened: (uri, extra) {
          destination = uri;
          handedFile = extra;
        },
      );
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
      await tester.pumpAndSettle();
      expect(find.text('quotation.xlsx'), findsOneWidget);
      await _send(tester, 'Prepare an order');
      expect(jobs.requests, hasLength(1));
      expect(jobs.requests.single.kind, 'ERP_DOCUMENT_ROUTE');
      expect(jobs.requests.single.params, {
        'message': 'Prepare an order',
        'pageRoute': '/sales/orders/new',
      });
      expect(jobs.requests.single.bytes, file.bytes);
      await tester.pumpAndSettle();
      expect(harness.repository.messages, isEmpty);
      expect(destination, isNull);
      expect(find.text('Open: New sales order'), findsOneWidget);
      await _tapCard(tester, 'ai-action-confirm-$_docCard');
      expect(destination?.path, '/sales/orders/new');
      expect(destination?.queryParameters, isEmpty);
      final plan = handedFile as AiGuidedFilePlan;
      expect(plan.file.bytes, file.bytes);
      expect(plan.file.name, file.name);
      expect(plan.jobId, 'file-job-1');
      expect(plan.pageRoute, '/sales/orders/new');
      expect(harness.repository.confirmations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'page suggestion endpoint only receives a bounded path and rejects a mismatched reply',
    () async {
      final api = _RecordingApi()
        ..pageResult = {
          'pageRoute': '/sales/orders/new',
          'pageTitle': 'Order page',
          'suggestions': [
            'Order date?',
            'Order date?',
            42,
            'Customer?',
            'Quantity?',
            'Excess?',
          ],
        };
      final repository = DioAiChatRepository(api);
      final result = await repository.pageSuggestions(
        '/sales/orders/new?amount=secret#field',
      );
      expect(api.path, '/ai/chat/page-suggestions');
      expect(api.query, {'pageRoute': '/sales/orders/new'});
      expect(result.suggestions, ['Order date?', 'Customer?', 'Quantity?']);
      await expectLater(
        repository.pageSuggestions('/${'a' * 240}'),
        throwsFormatException,
      );
      await expectLater(
        repository.pageSuggestions('https://other.invalid/page'),
        throwsFormatException,
      );
      api.pageResult = {
        'pageRoute': '/sales/quotes/new',
        'suggestions': ['Wrong page'],
      };
      await expectLater(
        repository.pageSuggestions('/sales/orders/new'),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'page suggestions update with an open history and click uses the new page',
    (tester) async {
      final repository = _FakeChatRepository()
        ..pageResults.addAll({
          '/sales/orders/new': const AiChatPageSuggestions(
            pageRoute: '/sales/orders/new',
            pageTitle: 'Order page',
            suggestions: ['Order date?', 'Order customer?'],
          ),
          '/sales/quotes/new': const AiChatPageSuggestions(
            pageRoute: '/sales/quotes/new',
            pageTitle: 'Quote page',
            suggestions: ['Quote validity?', 'Quote customer?'],
          ),
        });
      final harness = await _pump(tester, repository: repository);
      expect(repository.pageRequests, isEmpty);
      await _open(tester);
      expect(find.text('Order page'), findsOneWidget);
      expect(find.text('Order date?'), findsOneWidget);
      await _send(tester, 'hello');
      await tester.pumpAndSettle();
      harness.container.read(harness.route.notifier).state =
          '/sales/quotes/new?private=secret';
      await tester.pumpAndSettle();
      expect(find.text('Quote page'), findsOneWidget);
      expect(find.text('Order date?'), findsNothing);
      expect(find.text('Scoped answer 1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-chat-page-suggestions')),
        findsOneWidget,
      );
      await tester.tap(find.text('Quote validity?'));
      await tester.pumpAndSettle();
      expect(repository.messages.last['message'], 'Quote validity?');
      expect(repository.messages.last['currentRoute'], '/sales/quotes/new');
      // ADR-152: moving to another page keeps the same conversation.
      expect(
        repository.messages.last['conversationId'],
        repository.messages.first['conversationId'],
      );
      await _togglePageAware(tester);
      await tester.pumpAndSettle();
      expect(find.text('Quote customer?'), findsNothing);
      expect(
        find.byKey(const ValueKey('ai-chat-page-suggestions')),
        findsNothing,
      );
      final reads = repository.pageRequests.length;
      harness.container.read(harness.route.notifier).state =
          '/sales/orders/new';
      await tester.pumpAndSettle();
      expect(repository.pageRequests, hasLength(reads));
      expect(find.text('Scoped answer 2'), findsOneWidget);
    },
  );

  for (final route in ['/unknown/page', '/finance/restricted']) {
    testWidgets(
      'unknown or denied page has no advertised page guidance: $route',
      (tester) async {
        final repository = _FakeChatRepository()
          ..suggestions = [AppLocalizationsEn().aiChatPageQuestion]
          ..deniedPages.add('/finance/restricted');
        final harness = await _pump(tester, repository: repository);
        harness.container.read(harness.route.notifier).state = route;
        await tester.pump();
        await _open(tester);
        expect(
          find.text(AppLocalizationsEn().aiChatPageQuestion),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('ai-chat-page-suggestions')),
          findsNothing,
        );
        await _send(tester, 'hello');
        expect(find.text('Scoped answer 1'), findsOneWidget);
      },
    );
  }

  for (final boundary in ['route', 'disabled', 'identity']) {
    testWidgets('late page suggestions cannot cross $boundary changes', (
      tester,
    ) async {
      final pending = Completer<AiChatPageSuggestions>();
      final repository = _FakeChatRepository()
        ..pendingPages['/sales/orders/new'] = pending
        ..pageResults['/sales/quotes/new'] = const AiChatPageSuggestions(
          pageRoute: '/sales/quotes/new',
          pageTitle: 'New page',
          suggestions: ['New question?'],
        );
      final harness = await _pump(tester, repository: repository);
      await _open(tester);
      if (boundary == 'route') {
        harness.container.read(harness.route.notifier).state =
            '/sales/quotes/new';
      } else if (boundary == 'disabled') {
        await _togglePageAware(tester);
      } else {
        repository.pendingPages.clear();
        harness.container.read(harness.identity.notifier).state = _identity(
          user: 'new-user',
        );
      }
      await tester.pumpAndSettle();
      pending.complete(
        const AiChatPageSuggestions(
          pageRoute: '/sales/orders/new',
          pageTitle: 'Old private page',
          suggestions: ['Old private question?'],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Old private page'), findsNothing);
      expect(find.text('Old private question?'), findsNothing);
      if (boundary == 'route') {
        expect(find.text('New question?'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('welcome has two examples without policy paragraphs', (
    tester,
  ) async {
    final l10n = AppLocalizationsEn();
    final repository = _FakeChatRepository()
      ..suggestions = [
        l10n.aiChatPageQuestion,
        l10n.aiChatAttachmentQuestion,
        l10n.aiChatGuidedQuoteRequest,
      ];
    await _pump(tester, repository: repository);
    await _open(tester);
    expect(find.text(l10n.aiChatWelcome), findsOneWidget);
    expect(find.text(l10n.aiChatPageQuestion), findsOneWidget);
    expect(find.text(l10n.aiChatAttachmentQuestion), findsOneWidget);
    expect(find.text(l10n.aiChatGuidedQuoteRequest), findsNothing);
    expect(find.text('Only data permitted for this account.'), findsNothing);
    expect(find.text(l10n.aiChatBoundary), findsNothing);
    expect(find.text(l10n.aiChatPrivacyNotice), findsNothing);
    await _send(tester, 'hello');
    expect(find.text('Scoped answer 1'), findsOneWidget);
    expect(find.text(l10n.aiChatBoundary), findsNothing);
    expect(find.text('Only data permitted for this account.'), findsNothing);
  });

  testWidgets(
    'privacy information is available from the header without a permanent composer footer',
    (tester) async {
      await _pump(tester);
      await _open(tester);
      final l10n = AppLocalizationsEn();
      expect(find.text(l10n.aiChatPrivacyNotice), findsNothing);
      final panel = tester.getRect(find.byKey(const ValueKey('ai-chat-panel')));
      final composer = tester.getRect(
        find.byKey(const ValueKey('ai-chat-composer')),
      );
      expect(panel.bottom - composer.bottom, closeTo(12, 0.1));
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
            .decoration!
            .hintText,
        l10n.aiChatHint,
      );
      await tester.tap(find.byTooltip(l10n.aiChatInfo));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(l10n.aiChatPrivacyNotice), findsOneWidget);
      expect(find.text(l10n.aiChatBoundary), findsOneWidget);
      expect(find.text(l10n.aiChatCancel), findsNothing);
      await tester.tap(find.text(l10n.aiChatInfoDone));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiChatPrivacyNotice), findsNothing);
      expect(tester.takeException(), isNull);
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
    'delivered AI failure stays beside its message and retry never overwrites a new draft',
    (tester) async {
      final pending = Completer<AiJobSnapshot>();
      final repository = _FakeChatRepository()..pending = pending;
      final jobs = _FakeJobRepository()
        ..response = const AiJobSnapshot(
          id: 'accepted-1',
          kind: 'ERP_CHAT',
          status: AiJobStatus.failed,
          errorCode: 'AI_INVALID_RESPONSE',
          errorMessage: 'AI response could not be processed',
        );
      final harness = await _pump(tester, repository: repository, jobs: jobs);
      await _open(tester);
      await _send(tester, 'hello');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        'My next draft',
      );
      pending.complete(
        const AiJobSnapshot(
          id: 'accepted-1',
          kind: 'ERP_CHAT',
          status: AiJobStatus.pending,
        ),
      );
      await tester.pumpAndSettle();
      final failed = find.byKey(const ValueKey('ai-chat-delivery-1'));
      expect(
        find.descendant(
          of: failed,
          matching: find.text(AppLocalizationsEn().aiChatReplyFailed),
        ),
        findsOneWidget,
      );
      expect(
        find.text(AppLocalizationsEn().aiChatDeliveryUnknown),
        findsNothing,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
            .controller!
            .text,
        'My next draft',
      );
      harness.container.read(harness.route.notifier).state =
          '/production/plans/new';
      repository.pending = null;
      jobs.response = null;
      await tester.ensureVisible(find.byKey(const ValueKey('ai-chat-retry-1')));
      await tester.tap(find.byKey(const ValueKey('ai-chat-retry-1')));
      await tester.pumpAndSettle();
      expect(repository.messages, hasLength(2));
      expect(repository.messages[1], repository.messages[0]);
      expect(
        find.byKey(const ValueKey('ai-chat-user-bubble-1')),
        findsOneWidget,
      );
      expect(find.text('hello'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
            .controller!
            .text,
        'My next draft',
      );
    },
  );

  testWidgets(
    'unknown delivery is explicit and only a user retry resubmits the stored message',
    (tester) async {
      final repository = _FakeChatRepository()
        ..sendFailure = NetworkException();
      await _pump(tester, repository: repository);
      await _open(tester);
      await _send(tester, 'Original message');
      await tester.pumpAndSettle();
      expect(
        find.text(AppLocalizationsEn().aiChatDeliveryUnknown),
        findsOneWidget,
      );
      expect(find.text(AppLocalizationsEn().aiChatReplyFailed), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
            .controller!
            .text,
        isEmpty,
      );
      expect(repository.messages, hasLength(1));
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        'Unsent fresh text',
      );
      repository.sendFailure = null;
      await tester.ensureVisible(find.byKey(const ValueKey('ai-chat-retry-1')));
      await tester.tap(find.byKey(const ValueKey('ai-chat-retry-1')));
      await tester.pumpAndSettle();
      expect(repository.messages.map((item) => item['message']), [
        'Original message',
        'Original message',
      ]);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
            .controller!
            .text,
        'Unsent fresh text',
      );
    },
  );

  testWidgets(
    'interrupted polling checks the accepted job again without submitting twice',
    (tester) async {
      final repository = _FakeChatRepository()
        ..response = const AiJobSnapshot(
          id: 'accepted-1',
          kind: 'ERP_CHAT',
          status: AiJobStatus.pending,
        );
      final jobs = _FakeJobRepository()..readFailure = NetworkException();
      await _pump(tester, repository: repository, jobs: jobs);
      await _open(tester);
      await _send(tester, 'Question with a known job');
      await tester.pumpAndSettle();
      expect(
        find.text(AppLocalizationsEn().aiChatReplyInterrupted),
        findsOneWidget,
      );
      expect(find.text(AppLocalizationsEn().aiChatCheckReply), findsOneWidget);
      jobs.readFailure = null;
      await tester.ensureVisible(find.byKey(const ValueKey('ai-chat-retry-1')));
      await tester.tap(find.byKey(const ValueKey('ai-chat-retry-1')));
      await tester.pumpAndSettle();
      expect(repository.messages, hasLength(1));
      expect(jobs.reads, ['accepted-1', 'accepted-1']);
      expect(find.text('Scoped answer'), findsOneWidget);
    },
  );

  testWidgets('retries and later messages stay in one conversation', (
    tester,
  ) async {
    final repository = _FakeChatRepository()..sendFailure = NetworkException();
    await _pump(tester, repository: repository);
    await _open(tester);
    await _send(tester, 'Earlier message');
    repository.sendFailure = null;
    await _send(tester, 'Newer message');
    await tester.ensureVisible(find.byKey(const ValueKey('ai-chat-retry-1')));
    await tester.tap(find.byKey(const ValueKey('ai-chat-retry-1')));
    await tester.pumpAndSettle();
    await _send(tester, 'Continue the newer conversation');
    expect(repository.messages[2]['message'], 'Earlier message');
    final ids = repository.messages.map((m) => m['conversationId']).toSet();
    expect(ids, hasLength(1));
    expect(aiChatUuid.hasMatch(ids.single! as String), isTrue);
    expect(repository.messages.last['locale'], 'en');
  });

  group('ADR-152 chat settings and conversation', () {
    testWidgets(
      'the settings button opens the panel; each change saves at once with a busy row',
      (tester) async {
        final repository = _FakeChatRepository()
          ..settingsGate = Completer<void>();
        await _pump(tester, repository: repository);
        await _open(tester);
        final button = find.byKey(const ValueKey('ai-chat-settings'));
        expect(tester.widget<IconButton>(button).tooltip, _en.aiChatSettings);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ai-chat-settings')), findsNothing);
        expect(
          find.byKey(const ValueKey('ai-chat-settings-panel')),
          findsOneWidget,
        );
        expect(find.text(_en.aiChatSettings), findsOneWidget);
        expect(find.byKey(const ValueKey('ai-chat-composer')), findsNothing);
        expect(
          find.byKey(const ValueKey('ai-settings-confirm-always')),
          findsOneWidget,
        );
        expect(find.text(_en.aiChatSettingsConfirmAlways), findsOneWidget);

        await tester.tap(find.text(_en.aiChatSettingsDetailConcise));
        await tester.pump();
        expect(repository.settingChanges.single, {'detail': 'CONCISE'});
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('ai-settings-detail')),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        // Other rows wait while one is saving.
        await tester.tap(find.text(_en.aiChatSettingsReasoningDeep));
        await tester.pump();
        expect(repository.settingChanges, hasLength(1));
        repository.settingsGate!.complete();
        await tester.pumpAndSettle();
        expect(repository.settings.detail, AiChatDetail.concise);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('ai-settings-detail')),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        for (final entry in {
          _en.aiChatSettingsReasoningDeep: {'reasoning': 'DEEP'},
          _en.aiChatSettingsMemoryTurns(10): {'memoryTurns': 10},
          _en.aiChatSettingsLanguageKo: {'replyLanguage': 'KO'},
          _en.aiChatSettingsStyleProfessional: {
            'explanationStyle': 'PROFESSIONAL',
          },
          _en.aiChatSettingsSendCtrlEnter: {'sendKey': 'CTRL_ENTER'},
        }.entries) {
          final choice = find.text(entry.key);
          await tester.ensureVisible(choice);
          await tester.tap(choice);
          await tester.pumpAndSettle();
          expect(repository.settingChanges.last, entry.value);
        }
        for (final field in ['showSources', 'showSuggestions']) {
          final toggle = find.byKey(ValueKey('ai-settings-$field'));
          await tester.ensureVisible(toggle);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(repository.settingChanges.last, {field: false});
        }
        await tester.tap(find.byKey(const ValueKey('ai-settings-back')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ai-chat-composer')), findsOneWidget);
      },
    );

    testWidgets('a failed save rolls the choice back and says so', (
      tester,
    ) async {
      final repository = _FakeChatRepository()
        ..settingsFailure = NetworkException();
      await _pump(tester, repository: repository);
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('ai-chat-settings')));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('ai-settings-pageAware'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(find.byKey(const ValueKey('ai-settings-error')), findsOneWidget);
      expect(find.text(_en.aiChatSettingsSaveFailed), findsOneWidget);
      // The page is still read: the next question carries the snapshot route.
      await tester.tap(find.byKey(const ValueKey('ai-settings-back')));
      await tester.pumpAndSettle();
      await _send(tester, 'Still on the page?');
      expect(repository.messages.last['currentRoute'], '/sales/orders/new');
    });

    testWidgets(
      'a service without thinking depth shows the note and keeps the choice locked',
      (tester) async {
        final repository = _FakeChatRepository()..reasoningSupported = false;
        await _pump(tester, repository: repository);
        await _open(tester);
        await tester.tap(find.byKey(const ValueKey('ai-chat-settings')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('ai-settings-reasoning-unsupported')),
          findsOneWidget,
        );
        expect(
          find.text(_en.aiChatSettingsReasoningUnsupported),
          findsOneWidget,
        );
        await tester.tap(
          find.text(_en.aiChatSettingsReasoningDeep),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(repository.settingChanges, isEmpty);
      },
    );

    testWidgets('Enter sends by default; Shift+Enter does not', (tester) async {
      final repository = _FakeChatRepository();
      await _pump(tester, repository: repository);
      await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        'Enter question',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(repository.messages, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(repository.messages.single['message'], 'Enter question');
    });

    testWidgets('Ctrl+Enter mode: Enter is a new line, Ctrl+Enter sends', (
      tester,
    ) async {
      final repository = _FakeChatRepository()
        ..settings = const AiChatSettings(sendKey: AiChatSendKey.ctrlEnter);
      await _pump(tester, repository: repository);
      await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        'Ctrl question',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(repository.messages, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        repository.messages.single['message'],
        startsWith('Ctrl question'),
      );
    });

    testWidgets(
      'the latest conversation is restored and continued; new chat starts another',
      (tester) async {
        final repository = _FakeChatRepository()
          ..restored = AiChatConversationView(
            conversationId: _c1,
            hiddenTurns: 2,
            turns: [
              AiChatTurn(
                jobId: 'job-a',
                reply: AiChatReply.fromJson({
                  'question': 'Which tasks lack material?',
                  'reply': 'Task A01 lacks material.',
                  'conversationId': _c1,
                  'sources': [
                    {'id': 'page.tables', 'label': 'Current page table'},
                  ],
                }),
              ),
            ],
          );
        await _pump(tester, repository: repository);
        await _open(tester);
        expect(find.text('Which tasks lack material?'), findsOneWidget);
        expect(find.text('Task A01 lacks material.'), findsOneWidget);
        expect(find.byKey(const ValueKey('ai-chat-restored')), findsOneWidget);
        expect(find.text(_en.aiChatHiddenTurns(2)), findsOneWidget);
        await _send(tester, 'And the first one, why?');
        await tester.pumpAndSettle();
        expect(repository.messages.single['conversationId'], _c1);

        await tester.tap(find.byKey(const ValueKey('ai-chat-new')));
        await tester.pumpAndSettle();
        expect(find.text(_en.aiChatResetHint), findsOneWidget);
        await tester.tap(find.text(_en.aiChatConfirm));
        await tester.pumpAndSettle();
        expect(find.text('Task A01 lacks material.'), findsNothing);
        await _send(tester, 'Fresh topic');
        await tester.pumpAndSettle();
        final fresh = repository.messages.last['conversationId']! as String;
        expect(fresh, isNot(_c1));
        expect(aiChatUuid.hasMatch(fresh), isTrue);
      },
    );

    testWidgets('the conversation is restored only when the panel opens', (
      tester,
    ) async {
      final repository = _FakeChatRepository()
        ..restored = AiChatConversationView(
          conversationId: _c1,
          turns: [
            AiChatTurn(
              jobId: 'job-a',
              reply: AiChatReply.fromJson({
                'question': 'Which tasks lack material?',
                'reply': 'Task A01 lacks material.',
                'conversationId': _c1,
              }),
            ),
          ],
        );
      await _pump(tester, repository: repository);
      // Page loads alone never re-read the conversation.
      expect(repository.conversationCalls, 0);
      await _open(tester);
      expect(repository.conversationCalls, 1);
      expect(find.text('Task A01 lacks material.'), findsOneWidget);
    });

    testWidgets('a changed answer comes back as its question only', (
      tester,
    ) async {
      final repository = _FakeChatRepository()
        ..restored = AiChatConversationView(
          conversationId: _c1,
          turns: [
            AiChatTurn(
              jobId: 'job-a',
              reply: AiChatReply.fromJson({
                'question': 'How much stock of HP035754?',
                'dataChanged': true,
                'conversationId': _c1,
              }),
            ),
          ],
        );
      await _pump(tester, repository: repository);
      await _open(tester);
      expect(find.text('How much stock of HP035754?'), findsOneWidget);
      expect(find.text(_en.aiChatRestoredDataChanged), findsOneWidget);
      expect(find.text(_en.aiChatHiddenTurns(1)), findsNothing);
    });

    testWidgets('a restored page card can be cancelled but never run', (
      tester,
    ) async {
      final executed = <Map<String, Object?>>[];
      _serverCards[_p1] = _card();
      final repository = _FakeChatRepository()
        ..restored = AiChatConversationView(
          conversationId: _c1,
          turns: [
            AiChatTurn(
              jobId: 'job-b',
              reply: AiChatReply.fromJson({
                'question': 'Change row 3 quantity to 100',
                'reply': 'Please check the card.',
                'conversationId': _c1,
                'actions': [_card()],
              }),
            ),
          ],
        );
      await _pump(
        tester,
        repository: repository,
        page: _OrderPage(onSetLine: executed.add),
      );
      await _open(tester);
      expect(
        find.byKey(const ValueKey('ai-action-detached-$_p1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ai-action-confirm-$_p1')),
        findsNothing,
      );
      await _tapCard(tester, 'ai-action-cancel-$_p1');
      // Cancelling is allowed; the one-time proposal is never consumed.
      expect(repository.actionCalls, ['cancel:$_p1']);
      expect(executed, isEmpty);
    });

    testWidgets(
      'clearing history asks first, clears on the server and starts over',
      (tester) async {
        final repository = _FakeChatRepository();
        await _pump(tester, repository: repository);
        await _open(tester);
        await _send(tester, 'Something to clear');
        await tester.pumpAndSettle();
        final before = repository.messages.single['conversationId'];
        await tester.tap(find.byKey(const ValueKey('ai-chat-settings')));
        await tester.pumpAndSettle();
        final clear = find.byKey(const ValueKey('ai-settings-clear'));
        await tester.ensureVisible(clear);
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(find.text(_en.aiChatSettingsClearBody), findsOneWidget);
        await tester.tap(find.text(_en.aiChatCancel));
        await tester.pumpAndSettle();
        expect(repository.clearCalls, 0);
        await tester.tap(clear);
        await tester.pumpAndSettle();
        await tester.tap(find.text(_en.aiChatConfirm));
        await tester.pumpAndSettle();
        expect(repository.clearCalls, 1);
        await tester.tap(find.byKey(const ValueKey('ai-settings-back')));
        await tester.pumpAndSettle();
        expect(find.text('Scoped answer 1'), findsNothing);
        await _send(tester, 'After clearing');
        expect(repository.messages.last['conversationId'], isNot(before));
      },
    );

    testWidgets(
      'settings stay reachable on a narrow keyboard viewport at text scale 2',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final repository = _FakeChatRepository();
        await _pump(tester, repository: repository, size: const Size(360, 740));
        await _open(tester);
        tester.view.viewInsets = const FakeViewPadding(bottom: 360);
        await tester.pumpAndSettle();
        final settings = find.byKey(const ValueKey('ai-chat-settings'));
        await tester.ensureVisible(settings);
        await tester.tap(settings);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final clear = find.byKey(const ValueKey('ai-settings-clear'));
        await tester.ensureVisible(clear);
        await tester.pumpAndSettle();
        expect(clear.hitTestable(), findsOneWidget);
        final toggle = find.byKey(const ValueKey('ai-settings-showSources'));
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(repository.settingChanges.single, {'showSources': false});
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('sources and suggestions follow their settings', (
      tester,
    ) async {
      final repository = _FakeChatRepository()
        ..settings = const AiChatSettings(
          showSources: false,
          showSuggestions: false,
        )
        ..suggestions = const ['Suggested question']
        ..extraResult = {
          'sources': [
            {'id': 'page.legend', 'label': 'Current page colours'},
          ],
        };
      await _pump(tester, repository: repository);
      await _open(tester);
      expect(find.text('Suggested question'), findsNothing);
      await _send(tester, 'What do the colours mean?');
      await tester.pumpAndSettle();
      expect(find.textContaining('Current page colours'), findsNothing);
    });
  });

  testWidgets(
    'user bubbles align right and composer keeps both icon controls inside',
    (tester) async {
      await _pump(tester);
      await _open(tester);
      await _send(tester, 'hello');
      final messages = tester.getRect(
        find.byKey(const ValueKey('ai-chat-messages')),
      );
      final user = tester.getRect(
        find.byKey(const ValueKey('ai-chat-user-bubble-1')),
      );
      final assistant = tester.getRect(
        find.byKey(const ValueKey('ai-chat-assistant-bubble')),
      );
      expect(user.right, closeTo(messages.right - 16, 0.1));
      expect(user.width, lessThanOrEqualTo((messages.width - 32) * 0.62));
      expect(assistant.left, closeTo(messages.left + 16, 0.1));
      final composer = tester.getRect(
        find.byKey(const ValueKey('ai-chat-composer')),
      );
      final attach = tester.getRect(
        find.byKey(const ValueKey('ai-chat-attach')),
      );
      final send = tester.getRect(find.byKey(const ValueKey('ai-chat-send')));
      expect(attach.left, greaterThan(composer.left));
      expect(attach.bottom, lessThan(composer.bottom));
      expect(send.right, lessThan(composer.right));
      expect(send.bottom, lessThan(composer.bottom));
      expect(send.center.dx, greaterThan(attach.center.dx));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('ai-chat-send')),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'page-help hint requires an allowlisted value and a safe current path',
    () async {
      final api = _RecordingApi();
      final repository = DioAiChatRepository(api);
      await repository.send(
        message: 'Page help',
        conversationId: _c1,
        currentRoute: '/sales/quotes/new?private=value',
        intentHint: 'PAGE_HELP',
      );
      expect(api.body, {
        'message': 'Page help',
        'conversationId': _c1,
        'intentHint': 'PAGE_HELP',
        'pageContext': {'route': '/sales/quotes/new'},
      });
      for (final hint in ['TOOL', 'GRANT', 'PAGE_HELP;override']) {
        await expectLater(
          repository.send(
            message: 'Question',
            conversationId: _c1,
            currentRoute: '/sales/quotes/new',
            intentHint: hint,
          ),
          throwsFormatException,
        );
      }
      await expectLater(
        repository.send(
          message: 'Question',
          conversationId: _c1,
          intentHint: 'PAGE_HELP',
        ),
        throwsFormatException,
      );
      await expectLater(
        repository.send(
          message: 'Question',
          conversationId: _c1,
          currentRoute: 'https://untrusted.example/admin',
          intentHint: 'PAGE_HELP',
        ),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'real MainShell push and pop send the active page, and only the local shortcut hints page help',
    (tester) async {
      final repository = _FakeChatRepository();
      final router = await _pumpRealShell(tester, repository);
      router.push('/sales/quotes/new?private=value');
      await tester.pumpAndSettle();
      // Characterize the go_router 14 shell behavior that caused this defect.
      expect(
        GoRouterState.of(
          tester.element(find.byType(MainShellPage)),
        ).matchedLocation,
        '/sales/quotes',
      );
      expect(
        tester.widget<AiChatOverlay>(find.byType(AiChatOverlay)).currentRoute,
        '/sales/quotes/new',
      );
      await _open(tester);
      expect(repository.pageRequests.last, '/sales/quotes/new');
      await tester.tap(find.text(AppLocalizationsEn().aiChatPageQuestion));
      await tester.pumpAndSettle();
      expect(repository.messages.single['currentRoute'], '/sales/quotes/new');
      expect(repository.messages.single['intentHint'], 'PAGE_HELP');
      router.push('/sales/orders/new?private=other');
      await tester.pumpAndSettle();
      expect(repository.pageRequests.last, '/sales/orders/new');
      expect(find.text('Scoped answer 1'), findsOneWidget);
      await _send(tester, 'Next page');
      expect(repository.messages.last['currentRoute'], '/sales/orders/new');
      expect(repository.messages.last['intentHint'], isNull);
      router.pop();
      await tester.pumpAndSettle();
      expect(repository.pageRequests.last, '/sales/quotes/new');
      await _send(tester, 'Back to quote');
      expect(repository.messages.last['currentRoute'], '/sales/quotes/new');
      router.pop();
      await tester.pumpAndSettle();
      await _send(tester, 'Back to list');
      expect(repository.messages.last['currentRoute'], '/sales/quotes');
      expect(tester.takeException(), isNull);
    },
  );

  // 2026-10-05 incident: a card confirmed on the dashboard closed the panel,
  // reported success, and nothing appeared, because the shell judged
  // "main tab or business page" from the location frozen before the push.
  for (final tab in [RouteName.dashboard, RouteName.settings]) {
    testWidgets(
      'real MainShell shows a page pushed from the $tab tab, pops back to it, and its tab button leaves the page',
      (tester) async {
        final router = await _pumpRealShell(
          tester,
          _FakeChatRepository(),
          initialLocation: tab,
        );
        final tabPage = find.byType(
          tab == RouteName.dashboard ? DashboardPage : SettingsPage,
        );
        expect(tabPage.hitTestable(), findsOneWidget);
        router.push('/expense/new');
        await tester.pumpAndSettle();
        expect(find.text('Expense handoff').hitTestable(), findsOneWidget);
        expect(tabPage.hitTestable(), findsNothing);
        router.pop();
        await tester.pumpAndSettle();
        expect(find.text('Expense handoff'), findsNothing);
        expect(tabPage.hitTestable(), findsOneWidget);
        router.push('/expense/new');
        await tester.pumpAndSettle();
        expect(find.text('Expense handoff').hitTestable(), findsOneWidget);
        await tester.tap(
          find.byTooltip(
            tab == RouteName.dashboard ? _en.navDashboard : _en.navSettings,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Expense handoff'), findsNothing);
        expect(tabPage.hitTestable(), findsOneWidget);
        expect(topMatchedLocationOf(router), tab);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a file card confirmed on the dashboard opens the form above it before reporting success',
    (tester) async {
      final file = PlatformFile(
        name: 'invoice.pdf',
        size: 4,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      FilePicker.platform = _Picker(file);
      addTearDown(() => FilePicker.platform = _Picker(null));
      final jobs = _FakeJobRepository()
        ..routeOverride = {
          'workflow': 'EXPENSE_CLAIM',
          'documentType': 'INVOICE',
          'title': 'Prepare expense',
        };
      final repository = _FakeChatRepository();
      Uri? opened;
      await _pumpRealShell(
        tester,
        repository,
        initialLocation: RouteName.dashboard,
        identity: _identity(permissions: 'ai:use\n${Perm.expenseApply}'),
        jobs: jobs,
        onDraftOpened: (uri, _) => opened = uri,
      );
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
      await tester.pumpAndSettle();
      await _send(tester, '');
      await tester.pumpAndSettle();
      await _tapCard(tester, 'ai-action-confirm-$_docCard');
      expect(opened?.path, '/expense/new');
      expect(find.text('Expense handoff').hitTestable(), findsOneWidget);
      expect(find.byType(DashboardPage).hitTestable(), findsNothing);
      expect(find.byKey(const ValueKey('ai-chat-panel')), findsNothing);
      expect(repository.actionCalls, [
        'confirm:$_docCard',
        'receipt:$_docCard:SUCCEEDED',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a form that does not become the top page keeps the panel open with a failed receipt',
    (tester) async {
      final file = PlatformFile(
        name: 'invoice.pdf',
        size: 4,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      FilePicker.platform = _Picker(file);
      addTearDown(() => FilePicker.platform = _Picker(null));
      final jobs = _FakeJobRepository()
        ..routeOverride = {
          'workflow': 'EXPENSE_CLAIM',
          'documentType': 'INVOICE',
          'title': 'Prepare expense',
        };
      final repository = _FakeChatRepository();
      Uri? opened;
      await _pumpRealShell(
        tester,
        repository,
        initialLocation: RouteName.dashboard,
        identity: _identity(permissions: 'ai:use\n${Perm.expenseApply}'),
        jobs: jobs,
        onDraftOpened: (uri, _) => opened = uri,
        // The router's permission gate sends the form to the no-access page.
        redirect: (path) =>
            path == '/expense/new' ? RouteName.accessDenied : null,
      );
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
      await tester.pumpAndSettle();
      await _send(tester, '');
      await tester.pumpAndSettle();
      await _tapCard(tester, 'ai-action-confirm-$_docCard');
      expect(opened, isNull);
      expect(repository.actionCalls, [
        'confirm:$_docCard',
        'receipt:$_docCard:FAILED',
      ]);
      expect(repository.receiptMessages[_docCard], _en.aiChatCardFormNoAccess);
      expect(find.byKey(const ValueKey('ai-chat-panel')), findsOneWidget);
      expect(find.text(_en.aiChatCardFailed), findsOneWidget);
      expect(find.text(_en.aiChatCardFormNoAccess), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'without a router the card fails visibly instead of closing the panel',
    (tester) async {
      final file = PlatformFile(
        name: 'invoice.pdf',
        size: 4,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      FilePicker.platform = _Picker(file);
      addTearDown(() => FilePicker.platform = _Picker(null));
      final jobs = _FakeJobRepository()
        ..routeOverride = {
          'workflow': 'EXPENSE_CLAIM',
          'documentType': 'INVOICE',
          'title': 'Prepare expense',
        };
      final harness = await _pump(
        tester,
        jobs: jobs,
        initial: _identity(permissions: 'ai:use\n${Perm.expenseApply}'),
      );
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
      await tester.pumpAndSettle();
      await _send(tester, '');
      await tester.pumpAndSettle();
      await _tapCard(tester, 'ai-action-confirm-$_docCard');
      expect(harness.repository.actionCalls.last, 'receipt:$_docCard:FAILED');
      expect(
        harness.repository.receiptMessages[_docCard],
        _en.aiChatCardFormNotOpened,
      );
      expect(find.byKey(const ValueKey('ai-chat-panel')), findsOneWidget);
      expect(find.text(_en.aiChatCardFormNotOpened), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test('file answers parse purpose, pages, blocked items and structure', () {
    final bare = AiGuidedFileResult.fromJson(const {});
    expect(bare.typeSource, 'NONE');
    expect(bare.intent, 'NONE');
    expect(bare.pages, isEmpty);
    expect(bare.blocked, isEmpty);
    expect(bare.sheets, isEmpty);
    final odd = AiGuidedFileResult.fromJson({
      'typeSource': 'MODEL',
      'intent': 'DELETE_ALL',
      'pages': 'employee',
      'profile': ['Sheet1'],
    });
    expect(odd.typeSource, 'NONE');
    expect(odd.intent, 'NONE');
    expect(odd.pages, isEmpty);
    expect(odd.sheets, isEmpty);
    final result = AiGuidedFileResult.fromJson({
      'typeSource': 'AI',
      'intent': 'RECONCILE',
      'pages': [
        {'key': 'employee', 'title': ' Employee files ', 'route': '/employee'},
        {'key': 'foreign', 'title': 'Foreign', 'route': 'https://evil.test/x'},
        {'key': 'query', 'title': 'Query', 'route': '/employee?id=1'},
        {'key': 'up', 'title': 'Up', 'route': '/employee/../admin'},
        {'key': 'Bad Key', 'title': 'Bad key', 'route': '/employee'},
        {'key': 'blank', 'title': '  ', 'route': '/employee'},
        {'key': 'long', 'title': 'x' * 41, 'route': '/employee'},
        'not a page',
      ],
      'blocked': [
        {'title': 'Batch correction', 'reason': 'Not available yet.'},
        {'title': '', 'reason': 'No title'},
        {'title': 'No reason'},
      ],
      'profile': {
        'sheets': [
          {
            'name': 'Sheet1',
            'dataRows': 86,
            'columns': ['Name', 'Department', 42, 'y' * 30],
          },
          {'name': 'Sheet2', 'dataRows': -3},
        ],
      },
    });
    expect(result.typeSource, 'AI');
    expect(result.intent, 'RECONCILE');
    expect(result.pages.map((page) => (page.key, page.title, page.route)), [
      ('employee', 'Employee files', '/employee'),
    ]);
    expect(result.blocked.map((item) => (item.title, item.reason)), [
      ('Batch correction', 'Not available yet.'),
    ]);
    expect(result.sheets.first.name, 'Sheet1');
    expect(result.sheets.first.dataRows, 86);
    expect(result.sheets.first.columns, ['Name', 'Department', 'y' * 24]);
    expect(result.sheets.last.dataRows, 0);
    expect(result.sheets.last.columns, isEmpty);
    // Chat-only follow-ups never travel into a form draft.
    expect(result.toJson().keys, isNot(contains('pages')));
    expect(result.toJson().keys, isNot(contains('blocked')));
  });

  testWidgets(
    'an unclear file gets no card and one chip per purpose; a chip resends the same file once and yields one card',
    (tester) async {
      final file = PlatformFile(
        name: 'list.xlsx',
        size: 4,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      FilePicker.platform = _Picker(file);
      addTearDown(() => FilePicker.platform = _Picker(null));
      final jobs = _FakeJobRepository()
        ..routeOverride = {
          'documentType': 'UNKNOWN',
          'typeSource': 'NONE',
          'workflow': 'NONE',
          'needsChoice': true,
          'summary': 'Not sure what this file is for. Pick what to do with it.',
          'choices': [
            {'workflow': 'SALES_ORDER', 'title': 'Make a sales order'},
            {'workflow': 'SALES_QUOTE', 'title': 'Make a sales quote'},
            {'workflow': 'EXPENSE_CLAIM', 'title': 'Make an expense claim'},
          ],
        };
      AiGuidedFilePlan? opened;
      final harness = await _pump(
        tester,
        jobs: jobs,
        initial: _identity(
          permissions: [
            'ai:use',
            Perm.salesOrderView,
            Perm.salesOrderCreate,
            Perm.salesQuoteView,
            Perm.salesQuoteCreate,
            Perm.expenseApply,
          ].join('\n'),
        ),
        onDraftOpened: (_, extra) => opened = extra as AiGuidedFilePlan,
      );
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
      await tester.pumpAndSettle();
      await _send(tester, 'Check this file');
      await tester.pumpAndSettle();
      expect(find.byType(AiChatActionCard), findsNothing);
      ValueKey<String> chip(String job, String workflow) =>
          ValueKey('ai-doc-choice-$job-$workflow');
      for (final workflow in ['SALES_ORDER', 'SALES_QUOTE', 'EXPENSE_CLAIM']) {
        expect(find.byKey(chip('file-job-1', workflow)), findsOneWidget);
      }
      await _tapCard(tester, 'ai-doc-choice-file-job-1-SALES_QUOTE');
      expect(jobs.requests, hasLength(2));
      expect(jobs.requests.last.kind, aiGuidedRouteKind);
      expect(jobs.requests.last.bytes, file.bytes);
      expect(jobs.requests.last.fileName, file.name);
      expect(jobs.requests.last.params, {
        'message': 'Check this file',
        'pageRoute': '/sales/orders/new',
        'workflow': 'SALES_QUOTE',
      });
      // The pick is written as the user's own line (scrolled above the card).
      expect(
        find.text(
          _en.aiChatDocumentChosen('Make a sales quote'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(find.byType(AiChatActionCard), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-action-card-$_docCard2')),
        findsOneWidget,
      );
      expect(find.byKey(chip('file-job-2', 'SALES_ORDER')), findsNothing);
      // One pick per reply: the chips of the first answer are now inactive.
      await _scrollMessagesTo(
        tester,
        find.byKey(chip('file-job-1', 'SALES_ORDER')),
        up: true,
      );
      for (final workflow in ['SALES_ORDER', 'SALES_QUOTE', 'EXPENSE_CLAIM']) {
        final widget = tester.widget<ChoiceChip>(
          find.byKey(chip('file-job-1', workflow)),
        );
        expect(widget.onSelected, isNull);
        expect(widget.selected, workflow == 'SALES_QUOTE');
      }
      await _scrollMessagesTo(
        tester,
        find.byKey(const ValueKey('ai-action-confirm-$_docCard2')),
      );
      await _tapCard(tester, 'ai-action-confirm-$_docCard2');
      expect(opened?.jobId, 'file-job-2');
      expect(opened?.workflow, AiGuidedWorkflow.salesQuote);
      expect(harness.repository.actionCalls, [
        'confirm:$_docCard2',
        'receipt:$_docCard2:SUCCEEDED',
      ]);
      expect(harness.repository.messages, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('purposes this account cannot fill in are not offered as chips', (
    tester,
  ) async {
    final file = PlatformFile(
      name: 'list.xlsx',
      size: 4,
      bytes: Uint8List.fromList([1, 2, 3, 4]),
    );
    FilePicker.platform = _Picker(file);
    addTearDown(() => FilePicker.platform = _Picker(null));
    final jobs = _FakeJobRepository()
      ..routeOverride = {
        'workflow': 'NONE',
        'needsChoice': true,
        'choices': [
          {'workflow': 'SALES_ORDER', 'title': 'Make a sales order'},
          {'workflow': 'EXPENSE_CLAIM', 'title': 'Make an expense claim'},
          {'workflow': 'RUN_SQL', 'title': 'Unknown purpose'},
        ],
      };
    await _pump(tester, jobs: jobs);
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
    await tester.pumpAndSettle();
    await _send(tester, 'Check this file');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('ai-doc-choice-file-job-1-SALES_ORDER')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('ai-doc-choice-file-job-1-EXPENSE_CLAIM')),
      findsNothing,
    );
    expect(find.text('Unknown purpose'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'any chat user may upload; page chips follow the route guard and blocked items are shown as text',
    (tester) async {
      final file = PlatformFile(
        name: 'roster.xls',
        size: 4,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      FilePicker.platform = _Picker(file);
      addTearDown(() => FilePicker.platform = _Picker(null));
      // An HR account: no fill-in purposes at all, upload still available.
      final repository = _FakeChatRepository()..workflows = const [];
      final jobs = _FakeJobRepository()
        ..routeOverride = {
          'documentType': 'EMPLOYEE_ROSTER',
          'typeSource': 'RULES',
          'intent': 'RECONCILE',
          'workflow': 'NONE',
          'needsChoice': false,
          'title': 'Employee roster',
          'summary': 'This is an employee roster (title and column headers).',
          'choices': <Object>[],
          'pages': [
            {
              'key': 'employee',
              'title': 'Employee files',
              'route': '/employee',
            },
            {
              'key': 'identity_check',
              'title': 'ID checks',
              'route': '/hr/tasks/identity',
            },
          ],
          'blocked': [
            {
              'title': 'Batch correction',
              'reason': 'Not available yet; correct people one by one.',
            },
          ],
        };
      Uri? opened;
      await _pump(
        tester,
        repository: repository,
        jobs: jobs,
        initial: _identity(permissions: 'ai:use\n${Perm.employeeView}'),
        onDraftOpened: (uri, _) => opened = uri,
      );
      await _open(tester);
      expect(find.byKey(const ValueKey('ai-chat-attach')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
      await tester.pumpAndSettle();
      await _send(tester, 'Compare with the system and fix what differs');
      await tester.pumpAndSettle();
      expect(jobs.requests.single.params.containsKey('workflow'), isFalse);
      expect(find.byType(AiChatActionCard), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(
        find.byKey(const ValueKey('ai-doc-page-file-job-1-employee')),
        findsOneWidget,
      );
      expect(
        find.text(_en.aiChatDocumentOpenPage('Employee files')),
        findsOneWidget,
      );
      // The ID check page needs the ID edit permission on the client guard.
      expect(
        find.byKey(const ValueKey('ai-doc-page-file-job-1-identity_check')),
        findsNothing,
      );
      expect(
        find.text(
          _en.aiChatDocumentBlockedLine(
            'Batch correction',
            'Not available yet; correct people one by one.',
          ),
        ),
        findsOneWidget,
      );
      await _tapCard(tester, 'ai-doc-page-file-job-1-employee');
      expect(opened?.path, '/employee');
      expect(find.byKey(const ValueKey('ai-chat-panel')), findsNothing);
      expect(repository.messages, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final withGuidedCard in [true, false]) {
    testWidgets(
      'a file answer keeps at most one guided form card, never a page or permission card (guided card: $withGuidedCard)',
      (tester) async {
        final file = PlatformFile(
          name: 'quote.csv',
          size: 4,
          bytes: Uint8List.fromList([1, 2, 3, 4]),
        );
        FilePicker.platform = _Picker(file);
        addTearDown(() => FilePicker.platform = _Picker(null));
        final jobs = _FakeJobRepository()..extraActions = [_card(), _grant()];
        if (!withGuidedCard) {
          jobs.routeOverride = {'workflow': 'NONE', 'needsChoice': false};
        }
        await _pump(tester, jobs: jobs);
        await _open(tester);
        await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
        await tester.pumpAndSettle();
        await _send(tester, 'Prepare this document');
        await tester.pumpAndSettle();
        expect(
          find.byType(AiChatActionCard),
          withGuidedCard ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const ValueKey('ai-action-card-$_docCard')),
          withGuidedCard ? findsOneWidget : findsNothing,
        );
        expect(find.byKey(const ValueKey('ai-action-card-$_p1')), findsNothing);
        expect(find.byKey(const ValueKey('ai-action-card-$_p2')), findsNothing);
      },
    );
  }

  testWidgets(
    'typed text and suggestions with page awareness disabled do not send an intent hint',
    (tester) async {
      final question = AppLocalizationsEn().aiChatPageQuestion;
      final repository = _FakeChatRepository()..suggestions = [question];
      await _pump(tester, repository: repository);
      await _open(tester);
      await _togglePageAware(tester);
      await tester.pumpAndSettle();
      expect(find.text(question), findsNothing);
      await _send(tester, question);
      expect(repository.messages.single['currentRoute'], isNull);
      expect(repository.messages.single['intentHint'], isNull);
      await _togglePageAware(tester);
      await tester.pumpAndSettle();
      await _send(tester, question);
      expect(repository.messages.last['currentRoute'], '/sales/orders/new');
      expect(repository.messages.last['intentHint'], isNull);
    },
  );

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

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets(
      'narrow keyboard viewport remains usable at text scale $scale',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final repository = _FakeChatRepository()
          ..pageResults['/sales/orders/new'] = const AiChatPageSuggestions(
            pageRoute: '/sales/orders/new',
            pageTitle: 'Sales order',
            suggestions: [
              'How do I fill in the delivery date?',
              'How do I choose a customer?',
            ],
          );
        final harness = await _pump(
          tester,
          repository: repository,
          size: const Size(360, 740),
        );
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
          scale > 1.2 ? findsOneWidget : findsNothing,
        );
        await tester.ensureVisible(find.byKey(const ValueKey('ai-chat-input')));
        await _send(tester, 'How do I fill in this page?');
        expect(
          find.byKey(const ValueKey('ai-chat-page-suggestions')),
          findsOneWidget,
        );
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
}

Map<String, dynamic> _card({
  String id = _p1,
  String actionType = 'PAGE_ACTION',
  String handler = 'setLineField',
  String execution = 'CLIENT',
  String status = 'PROPOSED',
  String? route = '/sales/orders/new',
  Map<String, Object?> args = const {
    'row': 3,
    'field': 'Quantity',
    'value': '100',
  },
  List<String> lines = const [
    'Page: New sales order',
    'Action: Change a line',
    'Row: 3 (V50003)',
    'Field: Quantity',
    'New value: 100',
  ],
  Duration ttl = const Duration(minutes: 10),
  String risk = 'LOW',
  String? riskNote,
  bool stepUp = false,
  String? outcome,
  String title = 'Change a line',
}) => {
  'type': 'CONFIRM_ACTION',
  'proposalId': id,
  'actionType': actionType,
  'handler': handler,
  'execution': execution,
  'title': title,
  'summaryLines': lines,
  'risk': risk,
  'riskNote': ?riskNote,
  'requiresStepUp': stepUp,
  'route': ?route,
  if (execution == 'CLIENT') 'args': args,
  'issuedAt': DateTime.now().toUtc().toIso8601String(),
  'expiresAt': DateTime.now().add(ttl).toUtc().toIso8601String(),
  'status': status,
  'outcome': ?outcome,
};

Map<String, dynamic> _grant() => _card(
  id: _p2,
  actionType: 'PERMISSION_GRANT',
  handler: 'PERMISSION_GRANT',
  execution: 'SERVER',
  route: null,
  title: 'Grant one permission',
  lines: const [
    'Person: Warehouse employee',
    'Permission: View inventory',
    'Scope: Existing warehouse scope',
  ],
  risk: 'HIGH',
  riskNote: 'Granting takes effect at once.',
  stepUp: true,
);

/// A page that registers like the sales editor: two inputs (a password field
/// is present but never attached) and one closed page action.
class _OrderPage extends StatelessWidget {
  const _OrderPage({super.key, this.onSetLine});
  final void Function(Map<String, Object?> args)? onSetLine;

  @override
  Widget build(BuildContext context) => AiPageRegistrar(
    source: AiPageInfoSource(
      title: (_) => 'New sales order',
      actions: (ctx) => [
        AiPageAction(
          name: 'setLineField',
          title: 'Change a line',
          kind: AiActionKind.form,
          params: const [
            AiActionParam(
              'row',
              type: AiParamType.integer,
              title: 'Row',
              minimum: 1,
              maximum: 50,
            ),
            AiActionParam(
              'field',
              type: AiParamType.string,
              title: 'Field',
              options: ['Quantity', 'Discount'],
            ),
            AiActionParam(
              'value',
              type: AiParamType.string,
              title: 'New value',
            ),
          ],
          handler: (call) async {
            onSetLine?.call(call.args);
            return null;
          },
        ),
      ],
    ),
    child: const Column(
      children: [
        UtenInput(label: 'Customer', required: true),
        UtenInput(label: 'Quantity'),
        UtenInput(label: 'Password', isPassword: true, hint: 'hunter2'),
      ],
    ),
  );
}

/// Scrolls the conversation until [finder] is built and visible.
Future<void> _scrollMessagesTo(
  WidgetTester tester,
  Finder finder, {
  bool up = false,
}) async {
  await tester.scrollUntilVisible(
    finder,
    up ? -120 : 120,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey('ai-chat-messages')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  // The final jump is laid out on the next frame.
  await tester.pump();
}

Future<void> _tapCard(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey(key));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

AiChatIdentity _identity({
  String user = 'alice',
  String? actor,
  bool readOnly = false,
  int epoch = 1,
  String server = 'https://example.test/api',
  String permissions = 'ai:use\nsales_order:create\nsales_order:view',
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
  Map<String, Object?> extra = const {},
}) => AiJobSnapshot(
  id: id,
  kind: 'ERP_CHAT',
  status: AiJobStatus.succeeded,
  result: {'reply': reply, 'actions': actions, ...extra},
);

/// ADR-152: "read the current page" is a chat setting, saved at once.
Future<void> _togglePageAware(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('ai-chat-settings')));
  await tester.pumpAndSettle();
  final toggle = find.byKey(const ValueKey('ai-settings-pageAware'));
  await tester.ensureVisible(toggle);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('ai-settings-back')));
  await tester.pumpAndSettle();
}

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
  String? Function(String path)? redirect,
  Size size = const Size(1000, 850),
  Widget page = const SizedBox(key: ValueKey('business-surface')),
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
  final jobRepo = jobs ?? _FakeJobRepository();
  final pageContext = AiPageContextController();
  addTearDown(pageContext.dispose);
  final container = ProviderContainer(
    overrides: [
      aiChatIdentityProvider.overrideWith((ref) => ref.watch(identity)),
      aiGuidedFileIdentityProvider.overrideWith((ref) {
        final value = ref.watch(identity);
        return value == null
            ? null
            : (
                scope: value.scope,
                server: value.server,
                permissions: value.permissions,
              );
      }),
      aiChatRepositoryProvider.overrideWithValue(repo),
      aiJobRepositoryProvider.overrideWithValue(jobRepo),
      aiJobRunnerProvider.overrideWithValue(
        AiJobRunner(jobRepo, maxConsecutivePollErrors: 1),
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
      child: Scaffold(body: page),
    ),
  );
  Widget scoped(BuildContext context, Widget? child) =>
      AiPageContextScope(controller: pageContext, child: child!);
  final router = onDraftOpened == null
      ? null
      : GoRouter(
          redirect: redirect == null
              ? null
              : (context, state) => redirect(state.uri.path),
          routes: [
            GoRoute(path: '/', builder: (context, state) => home),
            GoRoute(
              path: '/sales/:seg/new',
              builder: (context, state) {
                onDraftOpened(state.uri, state.extra);
                return const Scaffold(body: Text('Order review handoff'));
              },
            ),
            GoRoute(
              path: '/expense/new',
              builder: (context, state) {
                onDraftOpened(state.uri, state.extra);
                return const Scaffold(body: Text('Expense handoff'));
              },
            ),
            GoRoute(
              path: '/employee',
              builder: (context, state) {
                onDraftOpened(state.uri, state.extra);
                return const Scaffold(body: Text('Employee files'));
              },
            ),
            GoRoute(
              path: RouteName.accessDenied,
              builder: (context, state) =>
                  const Scaffold(body: Text('No access page')),
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
              builder: scoped,
            )
          : MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: scoped,
              home: home,
            ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(container, identity, route, repo);
}

/// The real MainShellPage inside a ShellRoute, like app_router: the four main
/// tabs are drawn by the shell itself and their routes only sit underneath.
Future<GoRouter> _pumpRealShell(
  WidgetTester tester,
  _FakeChatRepository repository, {
  String initialLocation = '/sales/quotes',
  AiChatIdentity? identity,
  _FakeJobRepository? jobs,
  void Function(Uri, Object?)? onDraftOpened,
  String? Function(String path)? redirect,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final who = identity ?? _identity();
  final jobRepo = jobs ?? _FakeJobRepository();
  final router = GoRouter(
    initialLocation: initialLocation,
    redirect: redirect == null
        ? null
        : (context, state) => redirect(state.uri.path),
    routes: [
      ShellRoute(
        builder: (_, _, child) => MainShellPage(child: child),
        routes: [
          for (final tab in [RouteName.dashboard, RouteName.settings])
            GoRoute(
              path: tab,
              builder: (_, _) => Scaffold(body: Text('Route page $tab')),
            ),
          GoRoute(
            path: '/sales/quotes',
            builder: (_, _) => const Scaffold(body: Text('Quotes list')),
          ),
          GoRoute(
            path: '/sales/:seg/new',
            builder: (_, state) =>
                Scaffold(body: Text('Editor ${state.pathParameters['seg']}')),
          ),
          GoRoute(
            path: '/expense/new',
            builder: (_, state) {
              onDraftOpened?.call(state.uri, state.extra);
              return const Scaffold(body: Text('Expense handoff'));
            },
          ),
          GoRoute(
            path: RouteName.accessDenied,
            builder: (_, _) => const Scaffold(body: Text('No access page')),
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        aiChatIdentityProvider.overrideWithValue(who),
        aiGuidedFileIdentityProvider.overrideWithValue((
          scope: who.scope,
          server: who.server,
          permissions: who.permissions,
        )),
        currentPermissionsProvider.overrideWithValue(
          who.permissions.split('\n').toSet(),
        ),
        aiChatRepositoryProvider.overrideWithValue(repository),
        aiJobRepositoryProvider.overrideWithValue(jobRepo),
        aiJobRunnerProvider.overrideWithValue(AiJobRunner(jobRepo)),
        badgeTotalTodoProvider.overrideWithValue(0),
        unreadNoticeCountProvider.overrideWithValue(0),
        sharedPreferencesProvider.overrideWithValue(preferences),
        // The dashboard tab is drawn by the shell; keep its own reads offline.
        dashboardOverviewProvider.overrideWith(
          (ref) async => DashboardOverview(
            departmentCode: '',
            departmentName: '',
            generatedAt: DateTime(2026, 10, 5),
            metrics: const [],
            todos: const [],
          ),
        ),
        myCelebrationTodayProvider.overrideWith((ref) async => const []),
        publicSettingsRepositoryProvider.overrideWithValue(
          const _ChatPublicSettings(),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

class _ChatPublicSettings implements PublicSettingsRepository {
  const _ChatPublicSettings();
  @override
  Future<PublicSettings> fetch() async => const PublicSettings();
}

class _Harness {
  const _Harness(this.container, this.identity, this.route, this.repository);
  final ProviderContainer container;
  final StateProvider<AiChatIdentity?> identity;
  final StateProvider<String> route;
  final _FakeChatRepository repository;
}

class _FakeChatRepository implements AiChatRepository {
  final messages = <Map<String, Object?>>[];
  final confirmations = <String>[];
  final actionCalls = <String>[];
  final receiptMessages = <String, String?>{};
  List<Map<String, dynamic>> actions = [];
  Map<String, Object?> extraResult = const {};
  Map<String, Object?>? confirmArgs;
  Object? confirmFailure;
  Map<String, Object?>? afterConfirmFailure;
  Completer<void>? confirmGate;
  Completer<AiJobSnapshot>? pending;
  AiJobSnapshot? response;
  Object? sendFailure;
  int capabilityCalls = 0;
  List<String> suggestions = const [];

  /// Fill-in purposes the server allows this account (uploading itself is
  /// open to every chat user).
  List<String> workflows = const [
    'SALES_ORDER',
    'SALES_QUOTE',
    'EXPENSE_CLAIM',
  ];
  final pageRequests = <String>[];
  final pageResults = <String, AiChatPageSuggestions>{};
  final pendingPages = <String, Completer<AiChatPageSuggestions>>{};
  final deniedPages = <String>{};

  /// ADR-152 settings and conversation state of the fake server.
  AiChatSettings settings = AiChatSettings.defaults;
  bool reasoningSupported = true;
  final settingChanges = <Map<String, Object>>[];
  Object? settingsFailure;
  Completer<void>? settingsGate;
  AiChatConversationView restored = const AiChatConversationView();
  Object? restoreFailure;
  int clearCalls = 0;
  Object? clearFailure;

  @override
  Future<({AiChatSettings settings, bool reasoningEffortSupported})>
  updateSettings(Map<String, Object> change) async {
    settingChanges.add(change);
    await settingsGate?.future;
    if (settingsFailure case final failure?) throw failure;
    for (final entry in change.entries) {
      settings = settings.withField(entry.key, entry.value);
    }
    return (settings: settings, reasoningEffortSupported: reasoningSupported);
  }

  int conversationCalls = 0;

  @override
  Future<AiChatConversationView> conversation({String? conversationId}) async {
    conversationCalls++;
    if (restoreFailure case final failure?) throw failure;
    return restored;
  }

  @override
  Future<void> clearConversations() async {
    clearCalls++;
    if (clearFailure case final failure?) throw failure;
    restored = const AiChatConversationView();
  }

  @override
  Future<AiChatPageSuggestions> pageSuggestions(String pageRoute) async {
    pageRequests.add(pageRoute);
    if (deniedPages.contains(pageRoute)) {
      throw ApiException('FORBIDDEN', 'Denied page');
    }
    if (pendingPages[pageRoute] case final pending?) return pending.future;
    return pageResults[pageRoute] ??
        AiChatPageSuggestions(
          pageRoute: pageRoute,
          pageTitle: pageRoute.startsWith('/sales/') ? 'Sales page' : '',
          suggestions: pageRoute.startsWith('/sales/')
              ? [AppLocalizationsEn().aiChatPageQuestion]
              : const [],
        );
  }

  @override
  Future<AiChatCapabilities> capabilities() async {
    capabilityCalls++;
    return AiChatCapabilities(
      canChat: true,
      available: true,
      canUploadSalesOrder: true,
      canUploadDocument: true,
      workflows: workflows,
      canManagePermissions: true,
      scopeSummary: 'Only data permitted for this account.',
      suggestions: suggestions,
      settings: settings,
      reasoningEffortSupported: reasoningSupported,
    );
  }

  @override
  Future<AiJobSnapshot> send({
    required String message,
    required String conversationId,
    String? currentRoute,
    String? intentHint,
    Map<String, Object?>? snapshot,
    String? locale,
  }) async {
    messages.add({
      'message': message,
      'conversationId': conversationId,
      'currentRoute': currentRoute,
      'intentHint': intentHint,
      'snapshot': snapshot,
      'locale': locale,
    });
    if (sendFailure case final error?) throw error;
    for (final card in actions) {
      if (card['proposalId'] is String) {
        _serverCards[card['proposalId'] as String] = card;
      }
    }
    return pending?.future ??
        (response != null
            ? Future.value(response!)
            : Future.value(
                _success(
                  'Scoped answer ${messages.length}',
                  id: 'chat-job-${messages.length}',
                  actions: actions,
                  extra: extraResult,
                ),
              ));
  }

  AiChatAction _parse(String id) => AiChatAction.tryParse(_serverCards[id])!;

  @override
  Future<AiChatAction> actionStatus(String proposalId) async {
    actionCalls.add('status:$proposalId');
    return _parse(proposalId);
  }

  @override
  Future<({AiChatAction card, Map<String, Object?> args})> confirmAction(
    String proposalId,
  ) async {
    actionCalls.add('confirm:$proposalId');
    await confirmGate?.future;
    if (confirmFailure case final failure?) {
      if (afterConfirmFailure case final change?) {
        _serverCards[proposalId] = {..._serverCards[proposalId]!, ...change};
      }
      throw failure;
    }
    final card = {..._serverCards[proposalId]!, 'status': 'CONFIRMED'};
    _serverCards[proposalId] = card;
    return (
      card: _parse(proposalId),
      args:
          confirmArgs ??
          Map<String, Object?>.of(card['args'] as Map<String, dynamic>),
    );
  }

  @override
  Future<AiChatAction> cancelAction(String proposalId) async {
    actionCalls.add('cancel:$proposalId');
    _serverCards[proposalId] = {
      ..._serverCards[proposalId]!,
      'status': 'CANCELLED',
    };
    return _parse(proposalId);
  }

  @override
  Future<AiChatAction> actionReceipt(
    String proposalId, {
    required bool succeeded,
    String? message,
  }) async {
    actionCalls.add(
      'receipt:$proposalId:${succeeded ? 'SUCCEEDED' : 'FAILED'}',
    );
    receiptMessages[proposalId] = message;
    _serverCards[proposalId] = {
      ..._serverCards[proposalId]!,
      'status': succeeded ? 'CONFIRMED' : 'FAILED',
      'outcome': succeeded ? 'SUCCEEDED' : 'FAILED',
      'outcomeMessage': ?message,
    };
    return _parse(proposalId);
  }

  @override
  Future<String> confirmPermissionGrant(String proposalId) async {
    confirmations.add(proposalId);
    _serverCards[proposalId] = {
      ..._serverCards[proposalId]!,
      'status': 'CONFIRMED',
      'outcome': 'SUCCEEDED',
    };
    return 'Permission granted';
  }
}

class _RecordingApi extends ApiClient {
  _RecordingApi() : super(Dio());
  String? path;
  Object? body;
  Map<String, dynamic>? query;
  Map<String, dynamic> pageResult = const {};
  Map<String, dynamic> cardResult = const {};

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.query = query;
    return path.startsWith('/ai/chat/actions/') ? cardResult : pageResult;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.body = body;
    if (path.startsWith('/ai/chat/actions/')) return cardResult;
    return path.endsWith('/confirm')
        ? {'status': 'GRANTED', 'reply': 'Done'}
        : {'jobId': 'job-1', 'status': 'PENDING'};
  }
}

class _FakeJobRepository implements AiJobRepository {
  final requests = <AiJobRequest>[];
  final reads = <String>[];
  Object? readFailure;
  Completer<AiJobSnapshot>? pendingRead;
  AiJobSnapshot? response;

  /// The latest file job; every file job stays readable by its id.
  AiJobSnapshot? routed;
  final _routedJobs = <String, AiJobSnapshot>{};
  Map<String, dynamic>? routeOverride;

  /// Further cards a file result carries next to its own (the chat must keep
  /// at most one).
  List<Map<String, dynamic>> extraActions = const [];
  Object? submitFailure;
  @override
  Future<void> cancel(String jobId) async {}
  @override
  Future<AiJobSnapshot> get(String jobId) async {
    reads.add(jobId);
    if (readFailure case final error?) throw error;
    if (pendingRead != null) return pendingRead!.future;
    return response ??
        _routedJobs[jobId] ??
        _success('Scoped answer', id: jobId);
  }

  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) async {
    requests.add(request);
    if (submitFailure case final failure?) throw failure;
    if (request.kind == aiGuidedRouteKind) {
      final jobId = 'file-job-${_routedJobs.length + 1}';
      final cardId = _routedJobs.isEmpty ? _docCard : _docCard2;
      // Like the server: a purpose the user picked overrides what the file
      // looked like and yields exactly one card.
      final chosen = request.params['workflow'];
      final override = chosen == null
          ? routeOverride
          : {'workflow': chosen, 'needsChoice': false, 'choices': <Object>[]};
      final workflow = (override?['workflow'] as String?) ?? 'SALES_ORDER';
      final card = _card(
        id: cardId,
        actionType: 'OPEN_GUIDED_FORM',
        handler: 'OPEN_GUIDED_FORM',
        route: request.params['pageRoute'],
        title: 'Open the form and fill it in',
        lines: [
          'File: ${request.fileName}',
          'Open: ${switch (workflow) {
            'EXPENSE_CLAIM' => 'New expense claim',
            'SALES_QUOTE' => 'New sales quote',
            _ => 'New sales order',
          }}',
          'Saving stays with you on the page.',
        ],
        args: {'workflow': workflow, 'sourceJobId': jobId},
      );
      if (workflow != 'NONE') _serverCards[cardId] = card;
      for (final extra in extraActions) {
        _serverCards[extra['proposalId'] as String] = extra;
      }
      routed = AiJobSnapshot(
        id: jobId,
        kind: aiGuidedRouteKind,
        status: AiJobStatus.succeeded,
        result: {
          'documentType': 'SALES_QUOTATION',
          'workflow': 'SALES_ORDER',
          'title': 'Prepare order',
          'summary': 'Recognized. Confirm the card to open the form.',
          'needsChoice': false,
          'choices': <Object>[],
          'steps': ['Read file', 'Fill form'],
          'fields': <String, String>{},
          'requiresReview': true,
          'source': {
            'fileName': request.fileName,
            'sha256': sha256.convert(request.bytes).toString(),
          },
          'actions': [if (workflow != 'NONE') card, ...extraActions],
          ...?override,
        },
      );
      _routedJobs[jobId] = routed!;
      return routed!;
    }
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
