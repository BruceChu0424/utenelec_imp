import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_collapsible_section.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/intake/finance_intake_launcher.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
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
const _recognizeKey = ValueKey('finance-entry-recognize');

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

  testWidgets('empty receipt keeps recognition until AR rows are referenced', (
    tester,
  ) async {
    final launch = _Launch();
    final env = await _pump(tester, launch: launch, withArRow: false);
    await _selectAccount(tester, FinanceDocType.receipt);
    final bankCells = find.byKey(
      const ValueKey('finance-receipt-bank-reference'),
    );
    expect(bankCells, findsNothing);
    await _recognize(tester);
    expect(launch.calls, 1);
    expect(bankCells, findsNothing);
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
    expect(bankCells, findsNWidgets(2));
    final second = tester.widget<TextField>(bankCells.last).controller!;
    expect(first, same(second));
    expect(first.text, 'BANK-20261003-001');
    await tester.ensureVisible(bankCells.last);
    await tester.enterText(bankCells.last, 'BANK-REVIEWED-002');
    await tester.pumpAndSettle();
    expect(first.text, 'BANK-REVIEWED-002');
    expect(env.api.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

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
      expect(find.byKey(_recognizeKey), findsNothing);
      expect(launch.calls, 0);
    });
  }

  testWidgets('editing a saved draft has no bank recognition entry', (
    tester,
  ) async {
    final launch = _Launch();
    final env = await _pump(tester, launch: launch, existing: true);
    expect(find.byKey(_recognizeKey), findsNothing);
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

Future<void> _recognize(WidgetTester tester, {bool pending = false}) async {
  tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .jumpTo(0);
  await tester.pump();
  final entry = find.byKey(_recognizeKey);
  await tester.scrollUntilVisible(
    entry,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(entry);
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
  if (type == FinanceDocType.receipt && suffix == 'account-amount') {
    final sectionFinder = find.byKey(
      const ValueKey('finance-receipt-settlement-fees'),
    );
    await tester.scrollUntilVisible(
      sectionFinder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final section = tester.widget<UtenCollapsibleSection>(sectionFinder);
    if (!(section.expanded ?? section.initiallyExpanded)) {
      await tester.tap(
        find.descendant(of: sectionFinder, matching: find.text(section.title)),
      );
      await tester.pumpAndSettle();
    }
  }
  final field = find.byKey(ValueKey('finance-${type.name}-$suffix')).first;
  await tester.scrollUntilVisible(
    field,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  return tester.widget<TextField>(field).controller!;
}

Future<void> _addArRow(WidgetTester tester, {int index = 1}) async {
  final gridFinder = find.byWidgetPredicate(
    (widget) => widget is UtenEditableGrid<FinanceGridRow>,
  );
  await tester.scrollUntilVisible(
    gridFinder,
    -200,
    scrollable: find.byType(Scrollable).first,
  );
  final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(gridFinder);
  final row = FinanceGridRow(mode: ItemMode.settle)
    ..appliedLedgerId = 'ledger-$index'
    ..appliedBillNo = 'AR-00$index'
    ..sourceDocType = 'SALES_SHIPMENT'
    ..sourceDocNo = 'XSCK-00$index'
    ..currencyId = 'currency-cny'
    ..currencyCode = 'CNY'
    ..receivableOriginalText = '100.00'
    ..balanceOriginalText = '100.00';
  row.amount.text = '1.00';
  row.exchangeRate.text = '1';
  grid.controller.addRow(row);
  await tester.pumpAndSettle();
}

Future<PendingAttachmentController> _pending(WidgetTester tester) async {
  final section = find.byKey(const ValueKey('finance-doc-draft-attachments'));
  await tester.scrollUntilVisible(
    section,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  return tester.widget<BusinessAttachmentSection>(section).draftController!;
}

Future<void> _selectAccount(WidgetTester tester, FinanceDocType type) async {
  if (type == FinanceDocType.payment) {
    final field = find.byWidgetPredicate(
      (widget) => widget is UtenDropdownField && widget.label == '付款账户',
    );
    tester.widget<UtenDropdownField>(field).onChanged('account-1');
  } else {
    final field = find.text('点击选择收款账户');
    await tester.scrollUntilVisible(
      field,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'ZH000001 · 人民币账户'));
  }
  await tester.pumpAndSettle();
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
  await tester.binding.setSurfaceSize(const Size(1600, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
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
    await _addArRow(tester);
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    router.dispose();
    container.dispose();
  });
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
  }) async => path.endsWith('/draft-1')
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

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => switch (path) {
    '/master/accounts/dict' => [
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
