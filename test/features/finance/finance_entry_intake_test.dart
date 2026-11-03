import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/intake/finance_intake_launcher.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/features/finance/widgets/ar_ap_picker_dialog.dart';
import 'package:uten_imp/shared/attachments/attachment_file_rules.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_controller.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';
import '../../support/document_scope_capability_overrides.dart';
import '../../support/native_detail_reader_overrides.dart';
import '../../support/uten_test_actions.dart';

final _permissions = StateProvider<Set<String>>((ref) => _allPermissions);
final _identity = StateProvider<AuthenticatedScope?>((ref) => _initialIdentity);
const _initialIdentity = AuthenticatedScope(userId: 'finance-maker');
const _allPermissions = {
  Perm.financeViewAll,
  Perm.financeReceiptView,
  Perm.financeReceiptCreate,
  Perm.financeReceiptEdit,
  Perm.financePaymentView,
  Perm.financePaymentCreate,
  Perm.financePaymentEdit,
  Perm.attachmentUpload,
  Perm.attachmentView,
  Perm.aiUse,
};
Finder get _recognizeAction => find.text('识别银行回单');

void main() {
  for (final type in [FinanceDocType.receipt, FinanceDocType.payment]) {
    testWidgets(
      '${type.name} applies confirmed text and retains one original',
      (tester) async {
        final launch = _Launch();
        final env = await _pump(tester, type: type, launch: launch);
        await _selectAccount(tester, type);
        final amount = await _field(tester, type, 'account-amount');
        final reference = await _field(tester, type, 'bank-reference');
        amount.text = '9.00';
        reference.text = 'MANUAL-OLD';
        if (type == FinanceDocType.payment) {
          (await _field(tester, type, 'bank-fee')).text = '8.75';
        }
        await _recognize(tester);

        expect(launch.calls, 1);
        expect(launch.currentFields[FinanceIntakeField.accountAmount], '9.00');
        expect(
          launch.currentFields[FinanceIntakeField.bankReference],
          'MANUAL-OLD',
        );
        expect(amount.text, '123456789012.34');
        expect(reference.text, 'BANK-20261003-001');
        final pending = await _pending(tester);
        expect(pending.items.single.name, launch.file.name);
        expect(pending.items.single.bytes, orderedEquals(launch.file.bytes!));
        expect(pending.items.single.category, '银行回单');
        if (type == FinanceDocType.payment) {
          expect((await _field(tester, type, 'bank-fee')).text, '8.75');
        }
        expect(env.api.writes, isEmpty);

        await _recognize(tester);
        expect(launch.calls, 2);
        expect(
          pending.length,
          1,
          reason: 'The same original must not duplicate.',
        );
        expect(env.api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('selecting an actual account is required before file reading', (
    tester,
  ) async {
    final launch = _Launch();
    final env = await _pump(tester, launch: launch);
    await _recognize(tester);
    expect(launch.pickerCalls, 0);
    expect(launch.calls, 0);
    expect(env.api.writes, isEmpty);
  });

  testWidgets(
    'AR rows inherit the source reference with independent entry controllers',
    (tester) async {
      final launch = _Launch();
      final env = await _pump(tester, launch: launch, withArRow: false);
      await _selectAccount(tester, FinanceDocType.receipt);
      final initial = _table(tester).controller.rows.single;
      expect(initial.appliedLedgerId, isNull);
      expect(initial.entry.bankReference.text, isEmpty);
      await _recognize(tester);
      expect(launch.calls, 1);
      expect(initial.entry.bankReference.text, 'BANK-20261003-001');
      expect(
        (await _field(tester, FinanceDocType.receipt, 'account-amount')).text,
        '123456789012.34',
      );
      expect((await _pending(tester)).items, hasLength(1));

      await _addArRow(tester);
      await _addArRow(tester, index: 2);
      final first = await _field(
        tester,
        FinanceDocType.receipt,
        'bank-reference',
      );
      final rows = _table(tester).controller.rows;
      expect(rows.map((row) => row.appliedLedgerId), ['ledger-1', 'ledger-2']);
      final second = rows.last.entry.bankReference;
      expect(first, isNot(same(second)));
      expect(first.text, 'BANK-20261003-001');
      expect(second.text, 'BANK-20261003-001');
      expect(rows.first.entry.accountId, 'account-1');
      expect(rows.last.entry.accountId, 'account-1');
      expect(rows.first.entry.accountAmount.text, '123456789012.34');
      expect(
        rows.last.entry.accountAmount.text,
        isEmpty,
        reason:
            'Appending another AR row must not duplicate the bank actual amount.',
      );
      final secondField = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller == second,
      );
      await tester.ensureVisible(secondField);
      await tester.enterText(secondField, 'BANK-REVIEWED-002');
      await tester.pumpAndSettle();
      expect(first.text, 'BANK-20261003-001');
      expect(second.text, 'BANK-REVIEWED-002');
      expect((await _pending(tester)).items, hasLength(1));
      expect(env.api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final removed in [
    Perm.financeReceiptView,
    Perm.financeReceiptCreate,
    Perm.attachmentUpload,
  ]) {
    testWidgets('missing $removed hides bank recognition', (tester) async {
      final launch = _Launch();
      await _pump(
        tester,
        launch: launch,
        permissions: {..._allPermissions}..remove(removed),
      );
      expect(_recognizeAction, findsNothing);
      expect(launch.calls, 0);
    });
  }

  testWidgets('editing a saved draft has no bank recognition entry', (
    tester,
  ) async {
    final launch = _Launch();
    final env = await _pump(tester, launch: launch, existing: true);
    expect(_recognizeAction, findsNothing);
    expect(launch.calls, 0);
    expect(env.api.writes, isEmpty);
  });

  for (final change in [
    'field',
    'permission',
    'attachmentPermission',
    'identity',
  ]) {
    testWidgets('late recognition ignores changed $change', (tester) async {
      final completer = Completer<FinanceIntakePatch?>();
      final launch = _Launch(waitFor: completer);
      final env = await _pump(tester, launch: launch);
      await _selectAccount(tester, FinanceDocType.receipt);
      final amount = await _field(
        tester,
        FinanceDocType.receipt,
        'account-amount',
      );
      final reference = await _field(
        tester,
        FinanceDocType.receipt,
        'bank-reference',
      );
      final pending = await _pending(tester);
      await _recognize(tester, pending: true);
      expect(launch.calls, 1);
      expect(launch.stillCurrent!(), isTrue);
      switch (change) {
        case 'field':
          amount.text = '888.01';
        case 'permission':
          env.container.read(_permissions.notifier).state = {..._allPermissions}
            ..remove(Perm.financeReceiptCreate);
        case 'attachmentPermission':
          env.container.read(_permissions.notifier).state = {..._allPermissions}
            ..remove(Perm.attachmentUpload);
        case 'identity':
          env.container.read(_identity.notifier).state =
              const AuthenticatedScope(userId: 'another-user', epoch: 1);
      }
      await tester.pump();
      expect(launch.stillCurrent!(), isFalse);
      completer.complete(launch.patch(FinanceDocType.receipt));
      await tester.pumpAndSettle();
      expect(amount.text, change == 'field' ? '888.01' : '');
      expect(reference.text, '');
      expect(pending.items, isEmpty);
      expect(env.api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mismatched currency applies neither fields nor original', (
    tester,
  ) async {
    final launch = _Launch(currency: 'USD');
    final env = await _pump(tester, launch: launch);
    await _selectAccount(tester, FinanceDocType.receipt);
    final amount = await _field(
      tester,
      FinanceDocType.receipt,
      'account-amount',
    );
    final reference = await _field(
      tester,
      FinanceDocType.receipt,
      'bank-reference',
    );
    amount.text = '3.01';
    reference.text = 'MANUAL-001';
    await _recognize(tester);
    expect(amount.text, '3.01');
    expect(reference.text, 'MANUAL-001');
    expect((await _pending(tester)).items, isEmpty);
    expect(env.api.writes, isEmpty);
  });

  testWidgets('attachment capacity rejection cannot partially fill fields', (
    tester,
  ) async {
    final launch = _Launch();
    final env = await _pump(tester, launch: launch);
    await _selectAccount(tester, FinanceDocType.receipt);
    final amount = await _field(
      tester,
      FinanceDocType.receipt,
      'account-amount',
    );
    final reference = await _field(
      tester,
      FinanceDocType.receipt,
      'bank-reference',
    );
    amount.text = '3.01';
    reference.text = 'MANUAL-001';
    AttachmentLimits.apply(1);
    addTearDown(AttachmentLimits.reset);
    await _recognize(tester);
    expect(amount.text, '3.01');
    expect(reference.text, 'MANUAL-001');
    expect((await _pending(tester)).items, isEmpty);
    expect(env.api.writes, isEmpty);
  });
  for (final mismatch in ['hash', 'returnedBytes']) {
    testWidgets('changed source $mismatch applies neither fields nor file', (
      tester,
    ) async {
      final launch = _Launch(sourceMismatch: mismatch);
      final env = await _pump(tester, launch: launch);
      await _selectAccount(tester, FinanceDocType.receipt);
      final amount = await _field(
        tester,
        FinanceDocType.receipt,
        'account-amount',
      );
      final reference = await _field(
        tester,
        FinanceDocType.receipt,
        'bank-reference',
      );
      await _recognize(tester);
      expect(amount.text, '');
      expect(reference.text, '');
      expect((await _pending(tester)).items, isEmpty);
      expect(env.api.writes, isEmpty);
    });
  }
}

Finder get _tableFinder => find.byWidgetPredicate(
  (widget) => widget is UtenEditableGrid<FinanceGridRow>,
);

UtenEditableGrid<FinanceGridRow> _table(WidgetTester tester) =>
    tester.widget<UtenEditableGrid<FinanceGridRow>>(_tableFinder);

Future<void> _recognize(WidgetTester tester, {bool pending = false}) async {
  final grid = _table(tester).controller;
  grid.setSelected(grid.rows, false);
  grid.setSelected([grid.rows.first], true);
  await tester.pump();
  await tester.ensureVisible(_recognizeAction);
  await tester.tap(_recognizeAction);
  if (pending) {
    await tester.pump(const Duration(milliseconds: 100));
  } else {
    await tester.pumpAndSettle();
  }
}

Future<TextEditingController> _field(
  WidgetTester tester,
  FinanceDocType type,
  String suffix,
) async {
  final table = _table(tester);
  expect(table.tableKey, 'finance.${type.name}.entry.v1');
  final key = switch (suffix) {
    'account-amount' => 'entryAccountAmount',
    'bank-reference' => 'entryBankReference',
    'bank-fee' => 'entryFee',
    _ => throw StateError('Unsupported entry field $suffix'),
  };
  expect(table.columns.map((column) => column.key), contains(key));
  final entry = table.controller.rows.first.entry;
  return switch (suffix) {
    'account-amount' => entry.accountAmount,
    'bank-reference' => entry.bankReference,
    'bank-fee' => entry.fee,
    _ => throw StateError('Unsupported entry field $suffix'),
  };
}

Future<void> _addArRow(WidgetTester tester, {int index = 1}) async {
  final grid = _table(tester).controller;
  final target = grid.rows.first;
  target.entry.partyId = 'client-1';
  target.entry.touch();
  grid.setSelected(grid.rows, false);
  grid.setSelected([target], true);
  await tester.pumpAndSettle();
  final import = find.text('引用应收').first;
  await tester.ensureVisible(import);
  await tester.tap(import);
  await tester.pumpAndSettle();
  final selected = find.byKey(ValueKey('ar-ap-select-ledger-$index'));
  expect(selected, findsOneWidget);
  await tester.ensureVisible(selected);
  await tester.tap(selected);
  await tester.pumpAndSettle();
  final confirm = find.byKey(const ValueKey('ar-ap-confirm'));
  await tester.ensureVisible(confirm);
  await tester.tap(confirm);
  await tester.pumpAndSettle();
}

Future<PendingAttachmentController> _pending(WidgetTester tester) async {
  final section = find.byWidgetPredicate(
    (widget) =>
        widget is BusinessAttachmentSection && widget.draftController != null,
  );
  await tester.ensureVisible(section);
  return tester.widget<BusinessAttachmentSection>(section).draftController!;
}

Future<void> _selectAccount(WidgetTester tester, FinanceDocType type) async {
  expect(_table(tester).tableKey, 'finance.${type.name}.entry.v1');
  final cell = find
      .byKey(const ValueKey(('uten-grid-cell', 'entryAccount')))
      .first;
  final action = find.descendant(of: cell, matching: find.byType(UtenButton));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
  final accountRow = find.byKey(
    const ValueKey('finance-account-picker-account-1'),
  );
  await tester.ensureVisible(accountRow);
  expect(
    find.descendant(of: accountRow, matching: find.text('人民币账户')),
    findsOneWidget,
  );
  expect(
    find.descendant(of: accountRow, matching: find.text('ZH000001')),
    findsOneWidget,
  );
  await tester.tap(accountRow);
  await tester.pumpAndSettle();
  final confirm = find.byKey(const Key('finance-account-picker-confirm'));
  await tester.ensureVisible(confirm);
  await tester.tap(confirm);
  await tester.pumpAndSettle();
  expect(_table(tester).controller.rows.first.entry.accountId, 'account-1');
}

class _Launch {
  _Launch({this.currency = 'CNY', this.waitFor, this.sourceMismatch});
  final String currency;
  final Completer<FinanceIntakePatch?>? waitFor;
  final String? sourceMismatch;
  final file = PlatformFile(
    name: '银行回单.csv',
    size: 48,
    bytes: Uint8List.fromList(utf8.encode('银行回单,流水号,BANK-20261003-001')),
  );
  int calls = 0;
  int pickerCalls = 0;
  bool Function()? stillCurrent;
  Map<FinanceIntakeField, String> currentFields = const {};

  FinanceIntakePatch patch(FinanceDocType type) => FinanceIntakePatch(
    jobId: 'job-1',
    file: sourceMismatch == 'returnedBytes'
        ? PlatformFile(
            name: file.name,
            size: 3,
            bytes: Uint8List.fromList([1, 2, 3]),
          )
        : file,
    sourceSha256: sourceMismatch == 'hash'
        ? '0' * 64
        : sha256.convert(file.bytes!).toString(),
    docType: type,
    sourceCurrencyCode: currency,
    confirmedFields: {
      FinanceIntakeField.accountAmount: '123456789012.34',
      FinanceIntakeField.bankReference: 'BANK-20261003-001',
      if (type == FinanceDocType.payment) FinanceIntakeField.bankFee: '1.20',
    },
  );

  Future<FinanceIntakePatch?> call(
    BuildContext context,
    WidgetRef ref, {
    required PlatformFile file,
    required FinanceDocType docType,
    required bool Function() stillCurrent,
    Map<FinanceIntakeField, String> currentFields = const {},
  }) async {
    calls++;
    this.stillCurrent = stillCurrent;
    this.currentFields = Map.of(currentFields);
    return waitFor?.future ?? Future.value(patch(docType));
  }
}

Future<({ProviderContainer container, _Api api})> _pump(
  WidgetTester tester, {
  required _Launch launch,
  FinanceDocType type = FinanceDocType.receipt,
  Set<String> permissions = _allPermissions,
  bool existing = false,
  bool withArRow = true,
}) async {
  await setUtenTestSurfaceSize(tester, const Size(1600, 1200));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final api = _Api();
  final container = ProviderContainer(
    overrides: [
      ...nativeDetailReaderOverrides(
        includeSession: false,
        includeServer: false,
      ),
      financeWriteAllDocumentScope(),
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
      sharedPreferencesProvider.overrideWithValue(preferences),
      formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
      sessionProvider.overrideWith(_Session.new),
      _permissions.overrideWith((ref) => permissions),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
      financeEntryFilePickerProvider.overrideWithValue(() async {
        launch.pickerCalls++;
        return launch.file;
      }),
      financeIntakeLauncherProvider.overrideWithValue(launch.call),
    ],
  );
  final path =
      '/finance/${type.pathSegment}/${existing ? 'draft-1/edit' : 'new'}';
  final router = GoRouter(
    initialLocation: path,
    routes: [
      GoRoute(
        path: path,
        builder: (_, _) =>
            FinanceDocEditPage(docType: type, id: existing ? 'draft-1' : null),
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (type == FinanceDocType.receipt && !existing && withArRow) {
    final row = _table(tester).controller.rows.single;
    row.applyLedger(
      const AppliedArAp(
        ledgerId: 'ledger-1',
        appliedBillNo: 'AR-001',
        receiptAmountText: '1.00',
        sourceDocType: 'SALES_SHIPMENT',
        sourceDocNo: 'XSCK-001',
        currencyId: 'currency-cny',
        currencyCode: 'CNY',
        currencyName: '人民币',
        receivableOriginalText: '100.00',
        balanceOriginalText: '100.00',
      ),
    );
    row.entry.partyId = 'client-1';
    row.entry.currencyId = 'currency-cny';
    row.entry.touch();
    await tester.pumpAndSettle();
  }
  expect(tester.takeException(), isNull);
  return (container: container, api: api);
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'finance-maker', code: 'finance', name: '财务测试'),
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final writes = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/ar-ap') {
      return {
        'items': [
          for (final index in [1, 2])
            {
              'id': 'ledger-$index',
              'direction': 'AR',
              'clientId': 'client-1',
              'clientName': '客户甲',
              'billNo': 'AR-00$index',
              'billDate': '2026-10-03',
              'sourceDocType': 'SALES_SHIPMENT',
              'sourceDocNo': 'XSCK-00$index',
              'currencyId': 'currency-cny',
              'currencyCode': 'CNY',
              'currencyName': '人民币',
              'amountOriginal': 100,
              'amountOriginalExact': '100.00',
              'amountReceivedOriginal': 0,
              'amountReceivedOriginalExact': '0',
              'amountWriteOffOriginal': 0,
              'amountWriteOffOriginalExact': '0',
              'amountBalanceOriginal': 100,
              'amountBalanceOriginalExact': '100.00',
            },
        ],
        'page': 1,
        'size': 50,
        'total': 2,
        'totalPages': 1,
      };
    }
    return path.endsWith('/draft-1')
        ? {
            'id': 'draft-1',
            'status': 0,
            'version': 1,
            'makerId': 'finance-maker',
            'billNo': 'SK-001',
            'billDate': '2026-10-03',
            'receiptKind': 'AR_SETTLEMENT',
            'accountId': 'account-1',
            'items': <Map<String, dynamic>>[],
          }
        : {
            'items': <Map<String, dynamic>>[],
            'total': 0,
            'counts': <String, int>{},
          };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => switch (path) {
    '/master/accounts/dict' || '/business-references/accounts' => [
      {
        'id': 'account-1',
        'code': 'ZH000001',
        'name': '人民币账户',
        'currencyId': 'currency-cny',
        'currencyCode': 'CNY',
        'currencyName': '人民币',
        'baseCurrency': true,
        'status': '使用',
      },
    ],
    '/master/currencies/dict' => [
      {
        'id': 'currency-cny',
        'name': '人民币',
        'code': 'CNY',
        'baseCurrency': true,
      },
    ],
    _ => [],
  };

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    writes.add('POST $path');
    throw StateError('Recognition must not write business records');
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    writes.add('PUT $path');
    throw StateError('Recognition must not write business records');
  }
}
