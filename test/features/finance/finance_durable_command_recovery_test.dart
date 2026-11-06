import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import '../../support/finance_command_test_support.dart';
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_durable_command_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_procurement_confirmation_dialog.dart';
import 'package:uten_imp/features/finance/widgets/gl_report_line_bindings_dialog.dart';
import 'package:uten_imp/features/finance/widgets/inventory_cost_posting_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/audit_screenshot_support.dart';

const _actor = '00000000-0000-0000-0000-000000000101';
const _posting = '33333333-3333-4333-8333-333333333333';
const _style = '00000000-0000-0000-0000-000000000401';
final _allGrants = {
  Perm.financeReportView,
  Perm.financeViewAll,
  Perm.arApLedgerView,
  Perm.paymentStyleEdit,
  Perm.financePostExecute,
  Perm.supplierSettlementConfirm,
  Perm.goodsCostView,
};
final _grants = StateProvider<Set<String>>((_) => {..._allGrants});
final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: _actor),
);
String _target(FinanceDurableOperation operation) => switch (operation) {
  FinanceDurableOperation.reportBinding => 'ADM_OFFICE',
  FinanceDurableOperation.inventoryPeriod => _posting,
  FinanceDurableOperation.inventoryPost ||
  FinanceDurableOperation.inventoryClose => '2026-09',
  _ => '',
};

void main() {
  testWidgets(
    'actual nullable default AP policy opens, requires an explicit reference and restores the original revision0 first-save receipt',
    (tester) async {
      final api = _Api(FinanceDurableOperation.procurementPolicy)
        ..defaultPolicy = true
        ..version = 0
        ..loseFirst = true;
      final storage = MemoryFormDraftStorage();
      var harness = await _mount(tester, api, storage);
      await tester.tap(find.text('打开原操作'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-durable-command')), findsOneWidget);
      final field = tester.widget<UtenInput>(find.byType(UtenInput));
      expect(field.controller!.text, isEmpty);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      await tester.enterText(
        find.descendant(
          of: find.byType(UtenInput),
          matching: find.byType(TextFormField),
        ),
        '按原财务核对依据保持原路线',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final original = Map<String, dynamic>.from(api.writes.single),
          draft = harness.container.read(formDraftsProvider).single;
      expect(original['expectedRevision'], 0);
      expect(original['effectiveFrom'], isNull);
      expect(original['enabled'], false);
      await _unmount(tester, harness);
      harness = await _mount(
        tester,
        api,
        storage,
        location: draft.resumeLocation,
      );
      await tapFinanceOriginalAction(tester, '核对原操作结果');
      await tester.pumpAndSettle();
      expect(api.writes, hasLength(1));
      expect(api.receipts[original['requestId']]!['requestBody'], original);
      expect(harness.container.read(formDraftsProvider), isEmpty);
      await _unmount(tester, harness);
    },
  );
  testWidgets(
    'enabling default AP policy requires an explicit current or future date before dispatch',
    (tester) async {
      final api = _Api(FinanceDurableOperation.procurementPolicy)
        ..defaultPolicy = true
        ..version = 0;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await tester.tap(find.text('打开原操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(UtenDropdownField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('先对账确认再立应付'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(UtenInput),
          matching: find.byType(TextFormField),
        ),
        '首次明确核对后启用原政策',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      final field = tester.widget<UtenDateField>(find.byType(UtenDateField));
      expect(field.required, isTrue);
      expect(field.value, isNull);
      expect(field.errorMessage, contains('首次启用日期只能为今天或以后'));
      expect(
        tester.widget<UtenInput>(find.byType(UtenInput)).controller!.text,
        '首次明确核对后启用原政策',
      );
      await _unmount(tester, harness);
    },
  );
  for (final invalid in <Map<String, dynamic>>[
    {'enabled': false, 'effectiveFrom': null, 'sourceReference': null},
    {
      'enabled': false,
      'effectiveFrom': null,
      'sourceReference': null,
      'revision': '0',
    },
    {
      'enabled': false,
      'effectiveFrom': null,
      'sourceReference': false,
      'revision': 0,
    },
    {
      'enabled': false,
      'effectiveFrom': false,
      'sourceReference': null,
      'revision': 0,
    },
  ]) {
    testWidgets('malformed AP policy remains rejected ${invalid.toString()}', (
      tester,
    ) async {
      final api = _Api(FinanceDurableOperation.procurementPolicy)
        ..policyOverride = invalid;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await tester.tap(find.text('打开原操作'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-durable-command')), findsNothing);
      expect(api.writes, isEmpty);
      await _unmount(tester, harness);
    });
  }

  for (final operation in [
    FinanceDurableOperation.procurementPolicy,
    FinanceDurableOperation.reportBinding,
    FinanceDurableOperation.inventoryPolicy,
    FinanceDurableOperation.inventoryPeriod,
  ]) {
    testWidgets(
      '${operation.key} actual launcher keeps input, aligned pending menu/actions and current review usable at narrow enlarged keyboard size',
      (tester) async {
        const capture = bool.fromEnvironment('UTEN_CAPTURE_FINANCE_DIALOGS');
        if (capture) await loadAuditScreenshotFonts(tester);
        final api = _Api(operation)..unwrittenFirst = true;
        final harness = await _mount(
          tester,
          api,
          MemoryFormDraftStorage(),
          width: 390,
          scale: 1.5,
        );
        await _openAndSave(tester, operation, keyboard: true);
        expect(find.text('重试原请求').hitTestable(), findsOneWidget);
        expect(find.text('原请求操作').hitTestable(), findsOneWidget);
        expect(
          tester.getRect(find.byType(UtenDialogActions).first).bottom,
          lessThanOrEqualTo(600),
        );
        final title = find.text(operation.title);
        final scroll = find.ancestor(
          of: title,
          matching: find.byType(Scrollable),
        );
        if (scroll.evaluate().isNotEmpty) {
          tester.state<ScrollableState>(scroll.first).position.jumpTo(0);
        }
        await tester.pumpAndSettle();
        if (capture) {
          await saveAuditScreenshot(
            tester,
            harness.boundary,
            'durable-${operation.key.toLowerCase()}-390-keyboard',
          );
        }
        await tester.tap(find.text('原请求操作'));
        await tester.pumpAndSettle();
        expect(find.text('核实未写并保留输入').hitTestable(), findsOneWidget);
        await tapFinanceOriginalAction(tester, '核实未写并保留输入');
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('核对当前设置'));
        await tester.tap(find.text('核对当前设置'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('采用当前版本，保留输入'));
        expect(find.text('采用当前版本，保留输入').hitTestable(), findsOneWidget);
        if (capture) {
          await saveAuditScreenshot(
            tester,
            harness.boundary,
            'durable-${operation.key.toLowerCase()}-390-review',
          );
        }
        expect(api.writes, hasLength(1));
        expect(tester.takeException(), isNull);
        await _unmount(tester, harness);
      },
    );
  }

  testWidgets(
    'unfinished raw input and original version restore through the hub without sending a command',
    (tester) async {
      final api = _Api(FinanceDurableOperation.procurementPolicy);
      final storage = MemoryFormDraftStorage();
      var harness = await _mount(tester, api, storage);
      await tester.tap(find.text('打开原操作'));
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(UtenInput),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(field, '原未提交依据 12.');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      final draft = harness.container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isFalse);
      await _unmount(tester, harness);
      api.version = 99;
      final uri = Uri.parse(draft.route);
      harness = await _mount(
        tester,
        api,
        storage,
        location: uri
            .replace(
              queryParameters: {...uri.queryParameters, 'draftId': draft.id},
            )
            .toString(),
      );
      expect(
        tester.widget<UtenInput>(find.byType(UtenInput)).controller!.text,
        '原未提交依据 12.',
      );
      expect(
        (harness.container.read(formDraftsProvider).single.data['body']
            as Map)['expectedRevision'],
        7,
      );
      expect(api.writes, isEmpty);
      await _unmount(tester, harness);
    },
  );
  for (final operation in FinanceDurableOperation.values.where(
    (operation) => !operation.chart,
  )) {
    testWidgets(
      '${operation.key} hard reopen through real hub preserves original body/target/version and retries only the original command',
      (tester) async {
        final api = _Api(operation)..loseFirst = true;
        final storage = MemoryFormDraftStorage();
        var harness = await _mount(tester, api, storage);
        await _openAndSave(tester, operation);
        final original = jsonEncode(api.writes.single);
        final draft = harness.container.read(formDraftsProvider).single;
        expect(draft.hasUnknownSubmission, isTrue);
        expect(draft.data['sent'], api.writes.single);
        await _unmount(tester, harness);
        api.version = 99;
        final uri = Uri.parse(draft.route);
        harness = await _mount(
          tester,
          api,
          storage,
          location: uri
              .replace(
                queryParameters: {...uri.queryParameters, 'draftId': draft.id},
              )
              .toString(),
        );
        expect(find.text('重试原请求'), findsOneWidget);
        expect(api.writes, hasLength(1));
        await tester.tap(find.text('重试原请求'));
        await tester.pumpAndSettle();
        expect(api.writes, hasLength(2));
        expect(jsonEncode(api.writes.last), original);
        expect(api.commits, 1);
        expect(api.version, 99);
        expect(harness.container.read(formDraftsProvider), isEmpty);
        expect(tester.takeException(), isNull);
        await _unmount(tester, harness);
      },
    );
  }

  for (final operation in FinanceDurableOperation.values.where(
    (operation) => !operation.chart,
  )) {
    testWidgets(
      '${operation.key} proved unwritten preserves input, requires explicit current review and sends a new ID only after explicit save',
      (tester) async {
        final api = _Api(operation)..unwrittenFirst = true;
        final harness = await _mount(tester, api, MemoryFormDraftStorage());
        await _openAndSave(tester, operation);
        final original = Map<String, dynamic>.from(api.writes.single);
        final staleSave = tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '重试原请求'))
            .onPressed!;
        api.version = 99;
        await tapFinanceOriginalAction(tester, '核实未写并保留输入');
        await tester.pumpAndSettle();
        expect(api.commits, 0);
        expect(api.cancellations.single['requestBody'], original);
        final cancelled = harness.container.read(formDraftsProvider).single;
        expect(cancelled.hasUnknownSubmission, isFalse);
        expect(
          cancelled.data['body'],
          Map<String, dynamic>.from(original)..remove('requestId'),
        );
        expect(
          (cancelled.data['retiredReceipt'] as Map)['outcome'],
          'CANCELLED_UNWRITTEN',
        );
        expect(cancelled.data['requestId'], original['requestId']);
        staleSave();
        await tester.pumpAndSettle();
        expect(api.writes, hasLength(1));
        await tester.tap(find.text('核对当前设置'));
        await tester.pumpAndSettle();
        expect(api.writes, hasLength(1));
        await tester.ensureVisible(find.text('采用当前版本，保留输入'));
        await tester.tap(find.text('采用当前版本，保留输入'));
        await tester.pumpAndSettle();
        expect(api.writes, hasLength(1));
        expect(
          harness.container.read(formDraftsProvider).single.data['requestId'],
          original['requestId'],
        );
        final label = _saveLabel(operation);
        await tester.ensureVisible(find.widgetWithText(UtenButton, label));
        await tester.tap(find.widgetWithText(UtenButton, label));
        await tester.pumpAndSettle();
        expect(api.writes, hasLength(2));
        expect(api.writes.last['requestId'], isNot(original['requestId']));
        final expectedField = switch (operation) {
          FinanceDurableOperation.procurementPolicy => 'expectedRevision',
          FinanceDurableOperation.reportBinding => 'expectedFingerprint',
          FinanceDurableOperation.inventoryPolicy ||
          FinanceDurableOperation.inventoryClose => 'expectedVersion',
          _ => null,
        };
        if (expectedField != null) {
          expect(
            api.writes.last[expectedField],
            operation == FinanceDurableOperation.reportBinding
                ? 'current-state-v99'
                : 99,
          );
        }
        for (final entry in original.entries) {
          if (entry.key != 'requestId' && entry.key != expectedField) {
            expect(api.writes.last[entry.key], entry.value);
          }
        }
        expect(api.commits, 1);
        expect(harness.container.read(formDraftsProvider), isEmpty);
        expect(tester.takeException(), isNull);
        await _unmount(tester, harness);
      },
    );
  }

  testWidgets(
    'a lost cancellation reply remains the original unknown command until its matching tombstone is read',
    (tester) async {
      final api = _Api(FinanceDurableOperation.procurementPolicy)
        ..unwrittenFirst = true
        ..loseCancelFirst = true;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _openAndSave(tester, api.operation);
      final original = Map<String, dynamic>.from(api.writes.single);
      await tapFinanceOriginalAction(tester, '核实未写并保留输入');
      await tester.pumpAndSettle();
      expect(
        harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      expect(
        harness.container.read(formDraftsProvider).single.data['sent'],
        original,
      );
      await tapFinanceOriginalAction(tester, '核对原操作结果');
      await tester.pumpAndSettle();
      expect(
        harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isFalse,
      );
      expect(find.text('核对当前设置'), findsOneWidget);
      expect(api.commits, 0);
      final late = await api.put(
        api.operation.path(_target(api.operation)),
        body: original,
      );
      expect(late['outcome'], 'CANCELLED_UNWRITTEN');
      expect(api.commits, 0);
      await _unmount(tester, harness);
    },
  );

  testWidgets(
    'cancellation returns an existing success and completes without pretending the original was unwritten',
    (tester) async {
      final api = _Api(FinanceDurableOperation.procurementPolicy)
        ..loseFirst = true;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _openAndSave(tester, api.operation);
      await tapFinanceOriginalAction(tester, '核实未写并保留输入');
      await tester.pumpAndSettle();
      expect(api.commits, 1);
      expect(api.writes, hasLength(1));
      expect(harness.container.read(formDraftsProvider), isEmpty);
      expect(find.byKey(const Key('finance-durable-command')), findsNothing);
      await _unmount(tester, harness);
    },
  );

  testWidgets(
    'losing write permission still allows cancellation proof and current read but never a new save',
    (tester) async {
      final api = _Api(FinanceDurableOperation.inventoryClose)
        ..unwrittenFirst = true;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _openAndSave(tester, api.operation);
      harness.container.read(_grants.notifier).state = {..._allGrants}
        ..remove(Perm.financePostExecute);
      await tester.pumpAndSettle();
      await tapFinanceOriginalAction(tester, '核实未写并保留输入');
      await tester.pumpAndSettle();
      await tester.tap(find.text('核对当前设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('采用当前版本，保留输入'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '确认'))
            .onPressed,
        isNull,
      );
      expect(api.commits, 0);
      expect(api.writes, hasLength(1));
      await _unmount(tester, harness);
    },
  );

  testWidgets(
    'an account change while cancellation waits hides the old input and never publishes its late result',
    (tester) async {
      final api = _Api(FinanceDurableOperation.procurementPolicy)
        ..unwrittenFirst = true
        ..cancelGate = Completer<void>();
      final storage = MemoryFormDraftStorage();
      final harness = await _mount(tester, api, storage);
      await _openAndSave(tester, api.operation);
      final originalDraft = harness.container.read(formDraftsProvider).single;
      await tapFinanceOriginalAction(tester, '核实未写并保留输入');
      await tester.pump();
      await tester.pump();
      harness.container
          .read(_identity.notifier)
          .state = const AuthenticatedScope(
        userId: '00000000-0000-0000-0000-000000000999',
      );
      await tester.pump();
      api.cancelGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenInput), findsNothing);
      expect(find.text('访问范围已变化'), findsOneWidget);
      expect(api.writes, hasLength(1));
      await _unmount(tester, harness);
      final uri = Uri.parse(originalDraft.route);
      final restored = await _mount(
        tester,
        api,
        storage,
        location: uri
            .replace(
              queryParameters: {
                ...uri.queryParameters,
                'draftId': originalDraft.id,
              },
            )
            .toString(),
      );
      expect(find.text('原请求操作'), findsOneWidget);
      await tapFinanceOriginalAction(tester, '核对原操作结果');
      await tester.pumpAndSettle();
      expect(find.text('核对当前设置'), findsOneWidget);
      expect(api.commits, 0);
      await _unmount(tester, restored);
    },
  );

  testWidgets(
    'a later-check exit persists the unresolved command and does not resend it',
    (tester) async {
      final api = _Api(FinanceDurableOperation.inventoryPost)
        ..unwrittenFirst = true;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _openAndSave(tester, api.operation);
      await tester.tap(find.text('稍后核对'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('finance-durable-command')), findsNothing);
      expect(
        harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      expect(api.writes, hasLength(1));
      await _unmount(tester, harness);
    },
  );

  testWidgets(
    'a rejected dispatched CAS command stays frozen across hard reopen until a matching unwritten proof and explicit current review',
    (tester) async {
      final api = _Api(FinanceDurableOperation.procurementPolicy)
        ..rejectFirst = true;
      final storage = MemoryFormDraftStorage();
      var harness = await _mount(tester, api, storage);
      await _openAndSave(tester, api.operation);
      final draft = harness.container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(draft.data['sent'], api.writes.single);
      await _unmount(tester, harness);
      api.version = 99;
      final uri = Uri.parse(draft.route);
      harness = await _mount(
        tester,
        api,
        storage,
        location: uri
            .replace(
              queryParameters: {...uri.queryParameters, 'draftId': draft.id},
            )
            .toString(),
      );
      expect(find.text('重试原请求'), findsOneWidget);
      expect(tester.widget<UtenInput>(find.byType(UtenInput)).enabled, isFalse);
      expect(api.writes, hasLength(1));
      await tapFinanceOriginalAction(tester, '核对原操作结果');
      await tester.pumpAndSettle();
      expect(
        harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      await tapFinanceOriginalAction(tester, '核实未写并保留输入');
      await tester.pumpAndSettle();
      expect(tester.widget<UtenInput>(find.byType(UtenInput)).enabled, isTrue);
      expect(find.text('核对当前设置'), findsOneWidget);
      await tester.tap(find.text('核对当前设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('采用当前版本，保留输入'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(UtenButton, '保存'));
      await tester.pumpAndSettle();
      expect(api.writes.last['expectedRevision'], 99);
      expect(api.commits, 1);
      expect(harness.container.read(formDraftsProvider), isEmpty);
      await _unmount(tester, harness);
    },
  );

  for (final mismatch in [
    'actorId',
    'requestId',
    'operation',
    'method',
    'path',
    'requestBody',
  ]) {
    testWidgets(
      'a mismatched $mismatch receipt never completes or unfreezes an original command',
      (tester) async {
        final api = _Api(FinanceDurableOperation.procurementPolicy)
          ..loseFirst = true;
        final harness = await _mount(tester, api, MemoryFormDraftStorage());
        await _openAndSave(tester, api.operation);
        api.mismatch = mismatch;
        await tapFinanceOriginalAction(tester, '核对原操作结果');
        await tester.pumpAndSettle();
        expect(
          harness.container
              .read(formDraftsProvider)
              .single
              .hasUnknownSubmission,
          isTrue,
        );
        expect(api.writes, hasLength(1));
        expect(
          tester.widget<UtenInput>(find.byType(UtenInput)).enabled,
          isFalse,
        );
        api.mismatch = null;
        await tapFinanceOriginalAction(tester, '核对原操作结果');
        await tester.pumpAndSettle();
        expect(harness.container.read(formDraftsProvider), isEmpty);
        expect(api.writes, hasLength(1));
        await _unmount(tester, harness);
      },
    );
  }

  testWidgets(
    'missing receipt is not unwritten; lost write authority retains read-only original receipt recovery',
    (tester) async {
      final api = _Api(FinanceDurableOperation.inventoryClose)
        ..loseFirst = true;
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await _openAndSave(tester, api.operation);
      final retry = tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '重试原请求'))
          .onPressed!;
      api.found = false;
      await tapFinanceOriginalAction(tester, '核对原操作结果');
      await tester.pumpAndSettle();
      expect(
        harness.container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      harness.container.read(_grants.notifier).state = {..._allGrants}
        ..remove(Perm.financePostExecute);
      await tester.pumpAndSettle();
      retry();
      await tester.pumpAndSettle();
      expect(api.writes, hasLength(1));
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '重试原请求'))
            .onPressed,
        isNull,
      );
      api.found = true;
      await tapFinanceOriginalAction(tester, '核对原操作结果');
      await tester.pumpAndSettle();
      expect(harness.container.read(formDraftsProvider), isEmpty);
      expect(api.writes, hasLength(1));
      await _unmount(tester, harness);
    },
  );

  testWidgets(
    'pending dispatch has one overlay and captured callbacks cannot issue another write',
    (tester) async {
      final api = _Api(FinanceDurableOperation.inventoryPost)
        ..gate = Completer<void>();
      final harness = await _mount(tester, api, MemoryFormDraftStorage());
      await tester.tap(find.text('打开原操作'));
      await tester.pumpAndSettle();
      final save = tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '确认'))
          .onPressed!;
      save();
      save();
      await tester.pump();
      await tester.pump();
      expect(api.writes, hasLength(1));
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const Key('finance-durable-command')), findsOneWidget);
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(harness.container.read(formDraftsProvider), isEmpty);
      await _unmount(tester, harness);
    },
  );
}

Future<void> _openAndSave(
  WidgetTester tester,
  FinanceDurableOperation operation, {
  bool keyboard = false,
}) async {
  await tester.tap(find.text('打开原操作'));
  await tester.pumpAndSettle();
  if (operation == FinanceDurableOperation.reportDefaults) return;
  if (keyboard) {
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
  }
  for (final input
      in find
          .byType(UtenInput)
          .evaluate()
          .map((element) => element.widget as UtenInput)
          .toList()) {
    if (input.controller != null && input.enabled) {
      final field = find.descendant(
        of: find.byWidget(input),
        matching: find.byType(TextFormField),
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, '原依据与原输入保留 12.');
    }
  }
  final label = _saveLabel(operation);
  await tester.ensureVisible(find.widgetWithText(UtenButton, label));
  await tester.tap(find.widgetWithText(UtenButton, label));
  await tester.pumpAndSettle();
}

String _saveLabel(FinanceDurableOperation operation) => operation.inventory
    ? '确认'
    : operation == FinanceDurableOperation.reportBinding
    ? '保存取数设置'
    : operation == FinanceDurableOperation.reportDefaults
    ? '按默认名单补齐'
    : '保存';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Harness {
  _Harness(this.container, this.router, this.boundary);
  final ProviderContainer container;
  final GoRouter router;
  final GlobalKey boundary;
}

Future<void> _unmount(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox());
  harness.router.dispose();
  harness.container.dispose();
}

Future<_Harness> _mount(
  WidgetTester tester,
  _Api api,
  MemoryFormDraftStorage storage, {
  String location = '/start',
  double width = 1280,
  double scale = 1,
  bool capture = false,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://finance-command.test/api'),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  final boundary = GlobalKey();
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/start',
        builder: (_, _) => Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final operation = api.operation;
                switch (operation) {
                  case FinanceDurableOperation.procurementPolicy:
                    await showFinanceProcurementPolicyDialog(context);
                  case FinanceDurableOperation.reportBinding:
                    await showFinanceReportBindingCommand(
                      context,
                      line: GlReportLineBinding.fromJson({
                        'lineKey': 'ADM_OFFICE',
                        'label': '办公费',
                        'bindingKind': 'STYLE',
                        'targets': <Object>[],
                        'stateFingerprint': 'original-version-seven',
                      }),
                    );
                  case FinanceDurableOperation.reportDefaults:
                    await showFinanceReportDefaultsCommand(context);
                  default:
                    await showInventoryCostCommand(
                      context,
                      operation: operation,
                      target: _target(operation),
                      initialBody: switch (operation) {
                        FinanceDurableOperation.inventoryPolicy => {
                          'enabled': false,
                          'effectiveFrom': '2026-09-01',
                          'expectedVersion': 7,
                          'reconciliationReference': '原核对依据',
                        },
                        FinanceDurableOperation.inventoryPeriod => {
                          'targetPeriod': '2026-09',
                          'reason': '',
                        },
                        FinanceDurableOperation.inventoryClose => {
                          'expectedVersion': 7,
                          'reason': '',
                        },
                        _ => {},
                      },
                      initialContext: {
                        'sourceCount': 3,
                        'amountLocal': '0.000000000000000000000001',
                        'sourcePeriod': '2026-08',
                        'openPeriods': ['2026-09', '2026-10'],
                        'queryFrom': '2026-08-01',
                        'queryTo': '2026-09-30',
                      },
                    );
                }
              },
              child: const Text('打开原操作'),
            ),
          ),
        ),
      ),
      GoRoute(path: '/finance', builder: (_, _) => const FinanceHubPage()),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: capture
            ? auditScreenshotTheme(buildLightTheme())
            : buildLightTheme(),
        builder: (context, child) => RepaintBoundary(
          key: boundary,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(container, router, boundary);
}

class _Api extends ApiClient {
  _Api(this.operation) : super(Dio());
  final FinanceDurableOperation operation;
  bool loseFirst = false, found = true;
  bool defaultPolicy = false;
  Map<String, dynamic>? policyOverride;
  bool unwrittenFirst = false, loseCancelFirst = false, rejectFirst = false;
  int commits = 0, version = 7;
  String? mismatch;
  Completer<void>? gate;
  Completer<void>? cancelGate;
  final writes = <Map<String, dynamic>>[];
  final cancellations = <Map<String, dynamic>>[];
  final receipts = <String, Map<String, dynamic>>{};
  Map<String, dynamic>? receipt;
  Future<Map<String, dynamic>> _send(
    String path,
    String method,
    Object? body,
  ) async {
    final request = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(body)) as Map,
    );
    writes.add(request);
    if (unwrittenFirst && writes.length == 1) throw NetworkTimeoutException();
    if (rejectFirst && writes.length == 1) {
      throw ApiException(
        'CONFLICT',
        '当前设置已变化',
        httpStatus: 409,
        hasResponseCode: true,
      );
    }
    receipt = receipts[request['requestId']];
    if (receipt == null) {
      commits++;
      version++;
      receipt = {
        'found': true,
        'outcome': 'SUCCEEDED',
        'actorId': _actor,
        'requestId': request['requestId'],
        'operation': operation.key,
        'method': method,
        'path': path,
        'requestBody': request,
        'result': {'revision': version},
      };
      receipts[request['requestId'] as String] = receipt!;
    }
    if (gate != null) await gate!.future;
    if (loseFirst && writes.length == 1) throw NetworkTimeoutException();
    return Map<String, dynamic>.from(receipt!);
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) =>
      _send(path, 'PUT', body);
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
    bool preserveUnauthorizedSession = false,
  }) async {
    if (!path.endsWith('/cancel')) return _send(path, 'POST', body);
    final cancellation = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(body)) as Map,
    );
    cancellations.add(cancellation);
    final id = cancellation['requestId'] as String;
    receipt =
        receipts[id] ??
        {
          'found': true,
          'outcome': 'CANCELLED_UNWRITTEN',
          'actorId': cancellation['actorId'],
          'requestId': id,
          'operation': cancellation['operation'],
          'method': cancellation['method'],
          'path': cancellation['path'],
          'requestBody': cancellation['requestBody'],
          'result': {'cancelled': true},
        };
    receipts[id] = receipt!;
    if (cancelGate != null) await cancelGate!.future;
    if (loseCancelFirst && cancellations.length == 1) {
      throw NetworkTimeoutException();
    }
    return Map<String, dynamic>.from(receipt!);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/operations/')) {
      if (!found) return {'found': false};
      final stored = receipts[path.split('/').last];
      if (stored == null) return {'found': false};
      final result = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(stored)) as Map,
      );
      if (mismatch != null) {
        result[mismatch!] = mismatch == 'requestBody'
            ? {'other': 'body'}
            : 'mismatch';
      }
      return result;
    }
    if (policyOverride != null) {
      return Map<String, dynamic>.from(policyOverride!);
    }
    if (defaultPolicy &&
        path == '/finance/procurement-payable-recognitions/policy') {
      return {
        'enabled': false,
        'effectiveFrom': null,
        'sourceReference': null,
        'revision': 0,
      };
    }
    return {
      'revision': version,
      'version': version,
      'enabled': false,
      'effectiveFrom': '2026-09-01',
      'sourceReference': '原首次应付设置依据',
      'reconciliationReference': '当前成本策略依据',
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == GlReportLineBindingEndpoints.list) {
      return [
        {
          'lineKey': 'ADM_OFFICE',
          'label': '办公费',
          'stateFingerprint': 'current-state-v$version',
          'targets': <Object>[],
          'confirmedZero': false,
        },
      ];
    }
    if (path.endsWith('/periods')) {
      return [
        {
          'period': '2026-09',
          'status': 'OPEN',
          'version': version,
          'pendingCount': 0,
        },
      ];
    }
    if (path.endsWith('/postings')) {
      return [
        {
          'postingId': _posting,
          'postingStatus': 'READY',
          'targetPeriod': '2026-10',
          'amountLocal': '0.000000000000000000000001',
        },
      ];
    }
    return path == GlReportLineBindingEndpoints.expenseStyles
        ? [
            {
              'id': _style,
              'name': '办公费用',
              'code': '6602',
              'category': 'EXPENSE',
              'status': '使用',
              'children': <Object>[],
            },
          ]
        : [];
  }
}
