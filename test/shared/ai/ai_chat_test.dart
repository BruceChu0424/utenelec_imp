import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_en.dart';
import 'package:uten_imp/features/shell/pages/main_shell_page.dart';
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

  testWidgets(
    'file-only invoice uses a neutral request and opens expense without a business write',
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
      expect(opened?.path, '/expense/new');
      expect(harness.repository.messages, isEmpty);
      expect(harness.repository.confirmations, isEmpty);
      expect(jobs.reads, ['file-job-1']);
    },
  );

  testWidgets(
    'long file instructions cannot auto-open when intent after 512 characters is unseen',
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
      expect(
        opens,
        0,
        reason: 'The server did not receive the final no-create instruction',
      );
    },
  );

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
        if (scenario == 'revoked') {
          jobs.readFailure = ApiException(
            'FORBIDDEN',
            'Access changed',
            httpStatus: 403,
          );
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
        expect(opens, 0);
        expect(harness.repository.messages, isEmpty);
        if (scenario == 'retry') {
          jobs.submitFailure = null;
          await tester.tap(find.byKey(const ValueKey('ai-chat-retry-1')));
          await tester.pumpAndSettle();
          expect(opens, 1);
          expect(jobs.requests, hasLength(2));
          expect(jobs.requests.first.bytes, jobs.requests.last.bytes);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

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

  testWidgets('retrying an earlier message keeps a newer conversation branch', (
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
    expect(repository.messages[2]['previousJobId'], isNull);
    expect(repository.messages[3]['previousJobId'], 'chat-job-2');
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
        currentRoute: '/sales/quotes/new?private=value',
        intentHint: 'PAGE_HELP',
      );
      expect(api.body, {
        'message': 'Page help',
        'intentHint': 'PAGE_HELP',
        'pageContext': {'route': '/sales/quotes/new'},
      });
      for (final hint in ['TOOL', 'GRANT', 'PAGE_HELP;override']) {
        await expectLater(
          repository.send(
            message: 'Question',
            currentRoute: '/sales/quotes/new',
            intentHint: hint,
          ),
          throwsFormatException,
        );
      }
      await expectLater(
        repository.send(message: 'Question', intentHint: 'PAGE_HELP'),
        throwsFormatException,
      );
      await expectLater(
        repository.send(
          message: 'Question',
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
      await tester.tap(find.text(AppLocalizationsEn().aiChatPageQuestion));
      await tester.pumpAndSettle();
      expect(repository.messages.single['currentRoute'], '/sales/quotes/new');
      expect(repository.messages.single['intentHint'], 'PAGE_HELP');
      router.push('/sales/orders/new?private=other');
      await tester.pumpAndSettle();
      await _send(tester, 'Next page');
      expect(repository.messages.last['currentRoute'], '/sales/orders/new');
      expect(repository.messages.last['intentHint'], isNull);
      router.pop();
      await tester.pumpAndSettle();
      await _send(tester, 'Back to quote');
      expect(repository.messages.last['currentRoute'], '/sales/quotes/new');
      router.pop();
      await tester.pumpAndSettle();
      await _send(tester, 'Back to list');
      expect(repository.messages.last['currentRoute'], '/sales/quotes');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'typed text and suggestions with page awareness disabled do not send an intent hint',
    (tester) async {
      final question = AppLocalizationsEn().aiChatPageQuestion;
      final repository = _FakeChatRepository()..suggestions = [question];
      await _pump(tester, repository: repository);
      await _open(tester);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text(question));
      await tester.pumpAndSettle();
      expect(repository.messages.single['currentRoute'], isNull);
      expect(repository.messages.single['intentHint'], isNull);
      await tester.tap(find.byType(Switch));
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
      expect(find.textContaining('View inventory'), findsWidgets);
      expect(find.textContaining('Existing warehouse scope'), findsWidgets);
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
    'file first routes as a document then automatically opens a typed unsaved order',
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
      await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
      await tester.pumpAndSettle();
      expect(find.text('quotation.xlsx'), findsOneWidget);
      await _send(tester, 'Prepare an order');
      expect(jobs.requests, hasLength(1));
      expect(jobs.requests.single.kind, 'ERP_DOCUMENT_ROUTE');
      expect(jobs.requests.single.params, {'message': 'Prepare an order'});
      expect(jobs.requests.single.bytes, file.bytes);
      await tester.pumpAndSettle();
      expect(harness.repository.messages, isEmpty);
      expect(destination?.path, '/sales/orders/new');
      expect(destination?.queryParameters, isEmpty);
      final plan = handedFile as AiGuidedFilePlan;
      expect(plan.file.bytes, file.bytes);
      expect(plan.file.name, file.name);
      expect(plan.jobId, 'file-job-1');
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
      aiJobRepositoryProvider.overrideWithValue(jobs ?? _FakeJobRepository()),
      aiJobRunnerProvider.overrideWithValue(
        AiJobRunner(jobs ?? _FakeJobRepository(), maxConsecutivePollErrors: 1),
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

Future<GoRouter> _pumpRealShell(
  WidgetTester tester,
  _FakeChatRepository repository,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    initialLocation: '/sales/quotes',
    routes: [
      ShellRoute(
        builder: (_, _, child) => MainShellPage(child: child),
        routes: [
          GoRoute(
            path: '/sales/quotes',
            builder: (_, _) => const Scaffold(body: Text('Quotes list')),
          ),
          GoRoute(
            path: '/sales/:seg/new',
            builder: (_, state) =>
                Scaffold(body: Text('Editor ${state.pathParameters['seg']}')),
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        aiChatIdentityProvider.overrideWithValue(_identity()),
        aiChatRepositoryProvider.overrideWithValue(repository),
        aiJobRunnerProvider.overrideWithValue(
          AiJobRunner(_FakeJobRepository()),
        ),
        badgeTotalTodoProvider.overrideWithValue(0),
        unreadNoticeCountProvider.overrideWithValue(0),
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
  final messages = <Map<String, String?>>[];
  final confirmations = <String>[];
  List<Map<String, dynamic>> actions = [];
  Completer<AiJobSnapshot>? pending;
  AiJobSnapshot? response;
  Object? sendFailure;
  int capabilityCalls = 0;
  List<String> suggestions = const [];

  @override
  Future<AiChatCapabilities> capabilities() async {
    capabilityCalls++;
    return AiChatCapabilities(
      canChat: true,
      available: true,
      canUploadSalesOrder: true,
      canUploadDocument: true,
      workflows: const ['SALES_ORDER', 'SALES_QUOTE', 'EXPENSE_CLAIM'],
      canManagePermissions: true,
      scopeSummary: 'Only data permitted for this account.',
      suggestions: suggestions,
    );
  }

  @override
  Future<AiJobSnapshot> send({
    required String message,
    String? previousJobId,
    String? attachmentJobId,
    String? currentRoute,
    String? intentHint,
  }) async {
    messages.add({
      'message': message,
      'previousJobId': previousJobId,
      'attachmentJobId': attachmentJobId,
      'currentRoute': currentRoute,
      'intentHint': intentHint,
    });
    if (sendFailure case final error?) throw error;
    return pending?.future ??
        (response != null
            ? Future.value(response!)
            : Future.value(
                _success(
                  'Scoped answer ${messages.length}',
                  id: 'chat-job-${messages.length}',
                  actions: actions,
                ),
              ));
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
  final reads = <String>[];
  Object? readFailure;
  Completer<AiJobSnapshot>? pendingRead;
  AiJobSnapshot? response;
  AiJobSnapshot? routed;
  Map<String, dynamic>? routeOverride;
  Object? submitFailure;
  @override
  Future<void> cancel(String jobId) async {}
  @override
  Future<AiJobSnapshot> get(String jobId) async {
    reads.add(jobId);
    if (readFailure case final error?) throw error;
    if (pendingRead != null) return pendingRead!.future;
    return response ??
        (routed?.id == jobId ? routed! : _success('Scoped answer', id: jobId));
  }

  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) async {
    requests.add(request);
    if (submitFailure case final failure?) throw failure;
    if (request.kind == aiGuidedRouteKind) {
      routed = AiJobSnapshot(
        id: 'file-job-1',
        kind: aiGuidedRouteKind,
        status: AiJobStatus.succeeded,
        result: {
          'documentType': 'SALES_QUOTATION',
          'workflow': 'SALES_ORDER',
          'title': 'Prepare order',
          'summary': 'Ready to fill an unsaved form',
          'needsChoice': false,
          'choices': <Object>[],
          'steps': ['Read file', 'Fill form'],
          'fields': <String, String>{},
          'requiresReview': true,
          'source': {
            'fileName': request.fileName,
            'sha256': sha256.convert(request.bytes).toString(),
          },
          ...?routeOverride,
        },
      );
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
