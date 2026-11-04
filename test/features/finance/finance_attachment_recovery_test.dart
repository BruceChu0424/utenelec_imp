import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/widgets/finance_auxiliary_import_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/features/finance/widgets/finance_procurement_confirmation_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'finance_requirement_test_ui.dart';

final _bytes = Uint8List.fromList([1, 2, 3, 4, 0, 255]);
Finder _input(String label) =>
    find.byWidgetPredicate((w) => w is UtenInput && w.label == label);
Future<void> _tap(WidgetTester t, String label) async {
  if (find.text(label).evaluate().isNotEmpty) {
    await t.ensureVisible(find.text(label).last);
  }
  await tapFinanceAction(t, label);
}

Future<void> _chooseConfirmation(WidgetTester t) async {
  final table = t.widget<MasterDataTableView<Map<String, dynamic>>>(
    find.byType(MasterDataTableView<Map<String, dynamic>>),
  );
  table.onSelectedIdsChanged!({'candidate-1'});
  await t.pumpAndSettle();
  await _tap(t, '提交对账确认');
  await t.enterText(_input('对方确认人'), '原实际确认人');
  await t.enterText(_input('来源依据'), '原确认件及真实来源核对');
  await _tap(t, '选择原确认件');
}

void main() {
  testWidgets(
    'confirmation hard reopen retries original private bytes and source request',
    (t) async {
      final api = _Api()..unknownConfirmation = true,
          storage = MemoryFormDraftStorage();
      var c = await _mount(t, api, storage, confirmation: true);
      await _chooseConfirmation(t);
      await _tap(t, '提交对账确认');
      final first = api.uploads.single;
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      final draft = c.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(base64Decode(draft.data['fileBytes'] as String), _bytes);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      c = await _mount(t, api, storage, confirmation: true, resume: draft.id);
      api.unknownConfirmation = false;
      await _tap(t, '核对并重试原请求');
      expect(api.uploads, hasLength(2));
      expect(api.uploads.last, first);
      expect(c.read(formDraftsProvider), isEmpty);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'confirmation in-flight interruption can read original receipt after write permission is removed',
    (t) async {
      final api = _Api()..gate = Completer<Map<String, dynamic>>(),
          storage = MemoryFormDraftStorage();
      var c = await _mount(t, api, storage, confirmation: true);
      await _chooseConfirmation(t);
      await t.ensureVisible(find.text('提交对账确认').last);
      await t.tap(find.text('提交对账确认').last);
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(api.uploads, hasLength(1));
      final draft = c.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      c = await _mount(
        t,
        api,
        storage,
        confirmation: true,
        resume: draft.id,
        readOnly: true,
      );
      api.gate!.complete({'id': 'confirmed'});
      await t.pumpAndSettle();
      api.receipt = true;
      await _tap(t, '只读核对原回执');
      expect(api.uploads, hasLength(1));
      expect(c.read(formDraftsProvider), isEmpty);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'auxiliary unknown file intake reopens with the same nonce query and bytes',
    (t) async {
      final api = _Api()..unknownAux = true, storage = MemoryFormDraftStorage();
      var c = await _mount(t, api, storage);
      await t.enterText(_input('来源账套'), '000账套');
      await _tap(t, '选择原明细文件');
      final first = api.uploads.single;
      expect(
        Uri.parse(first['path'].toString()).queryParameters['requestId'],
        isNotEmpty,
      );
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      final draft = c.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(base64Decode(draft.data['fileBytes'] as String), _bytes);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      c = await _mount(t, api, storage, resume: draft.id);
      api.unknownAux = false;
      await _tap(t, '核对并重试原上传');
      expect(api.uploads, hasLength(2));
      expect(api.uploads.last, first);
      expect(c.read(formDraftsProvider).single.hasUnknownSubmission, isFalse);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'auxiliary directory interruption is resolved by owner read without applying twice',
    (t) async {
      final api = _Api()..unknownApply = true,
          storage = MemoryFormDraftStorage();
      var c = await _mount(t, api, storage);
      await t.enterText(_input('来源账套'), '原账套');
      await _tap(t, '选择原明细文件');
      await _tap(t, '导入辅助目录草稿');
      await t.pump(const Duration(seconds: 2));
      await t.pumpAndSettle();
      final draft = c.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(api.applyBodies, hasLength(1));
      await t.pumpWidget(const SizedBox());
      c.dispose();
      c = await _mount(t, api, storage, resume: draft.id, readOnly: true);
      await _tap(t, '只读核对原结果');
      expect(api.applyBodies, hasLength(1));
      expect(c.read(formDraftsProvider).single.hasUnknownSubmission, isFalse);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}

Future<ProviderContainer> _mount(
  WidgetTester t,
  _Api api,
  MemoryFormDraftStorage storage, {
  bool confirmation = false,
  String? resume,
  bool readOnly = false,
}) async {
  await t.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => t.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://finance-draft.test/api'),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'finance-operator'),
      ),
      currentPermissionsProvider.overrideWithValue({
        Perm.financeReportView,
        Perm.financeViewAll,
        if (!readOnly) ...[
          Perm.paymentStyleEdit,
          Perm.supplierSettlementConfirm,
          Perm.financePostExecute,
        ],
      }),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
      financeConfirmationFilePickerProvider.overrideWithValue(
        () async => PlatformFile(
          name: 'original.png',
          size: _bytes.length,
          bytes: _bytes,
        ),
      ),
      financeEntryFilePickerProvider.overrideWithValue(
        () async => PlatformFile(
          name: 'original.xlsx',
          size: _bytes.length,
          bytes: _bytes,
        ),
      ),
    ],
  );
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => confirmation
                  ? showFinanceProcurementConfirmationDialog(
                      context,
                      supplierId: 'supplier-1',
                      currencyId: 'currency-1',
                      resumeDraftId: resume,
                    )
                  : showFinanceAuxiliaryImportDialog(
                      context,
                      receivable: true,
                      currencyId: 'currency-1',
                      dateFrom: '2026-09-01',
                      dateTo: '2026-09-30',
                      resumeDraftId: resume,
                    ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await _tap(t, '打开');
  return c;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  bool unknownConfirmation = false,
      unknownAux = false,
      unknownApply = false,
      receipt = false;
  Completer<Map<String, dynamic>>? gate;
  final uploads = <Map<String, dynamic>>[],
      applyBodies = <Map<String, dynamic>>[];
  Map<String, dynamic>? preview;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/candidates')) {
      return {
        'items': [
          {
            'id': 'candidate-1',
            'billNo': 'RC-001',
            'commercialDate': '2026-09-15',
            'amountOriginal': '150.000000000000000000000001',
            'amountLocal': '150.000000000000000000000001',
            'sourceFingerprint': 'source-real',
          },
        ],
        'totalPages': 1,
      };
    }
    if (path.contains('/procurement-payable-recognitions/operations/')) {
      if (!receipt) {
        throw ApiException(
          'NOT_FOUND',
          '尚未取得本人原回执',
          hasResponseCode: true,
          httpStatus: 404,
        );
      }
      final item = uploads.first,
          cmd = Map<String, dynamic>.from(item['command'] as Map);
      return {
        'request_id': cmd['requestId'],
        'submitted_by': 'finance-operator',
        'supplier_id': cmd['supplierId'],
        'currency_id': cmd['currencyId'],
        'effective_date': cmd['effectiveDate'],
        'counterpart_confirmed_by': cmd['counterpartConfirmedBy'],
        'counterpart_confirmed_date': cmd['counterpartConfirmedDate'],
        'source_reference': cmd['sourceReference'],
        'file_sha256': sha256.convert(_bytes).toString(),
        'file_name': 'original.png',
        'lines': [
          for (final r in cmd['candidates'] as List)
            {
              'candidate_id': (r as Map)['candidateId'],
              'source_fingerprint': r['sourceFingerprint'],
            },
        ],
      };
    }
    if (path.contains('/auxiliary-imports/operations/')) {
      if (!receipt) {
        throw ApiException(
          'NOT_FOUND',
          '尚未取得本人原回执',
          hasResponseCode: true,
          httpStatus: 404,
        );
      }
      return {'requestId': path.split('/').last, 'preview': preview};
    }
    if (path.endsWith('/batch-1')) {
      return {...?preview, 'directoryApplied': applyBodies.isNotEmpty};
    }
    return {'items': <Object>[], 'totalPages': 0};
  }

  @override
  Future<Map<String, dynamic>> postMultipartFile(
    String path,
    Uint8List bytes,
    String filename,
    String contentType, {
    Duration? receiveTimeout,
    Map<String, Object?> jsonParts = const {},
    Map<String, dynamic>? headers,
  }) async {
    uploads.add({
      'path': path,
      'bytes': List<int>.from(bytes),
      'filename': filename,
      'contentType': contentType,
      'headers': headers ?? {},
      if (jsonParts['command'] != null)
        'command': jsonDecode(jsonEncode(jsonParts['command'])),
    });
    if (path.contains('/procurement-payable-recognitions')) {
      if (gate != null) return gate!.future;
      if (unknownConfirmation) throw NetworkTimeoutException();
      return {'id': 'confirmed'};
    }
    final q = Uri.parse(path).queryParameters;
    preview = {
      'importId': 'batch-1',
      'receivable': true,
      'sourceSystem': q['sourceSystem'],
      'currencyId': q['currencyId'],
      'dateFrom': q['dateFrom'],
      'dateTo': q['dateTo'],
      'sourceName': filename,
      'sha256': sha256.convert(bytes).toString(),
      'rows': [
        {
          'sourceRow': 4,
          'partyCode': '00001',
          'partyName': '原客户',
          'closingBalance': '12.000000000000000000000001',
        },
      ],
      'issues': <Object>[],
      'columns': [
        {'key': 'partyCode', 'label': '客户编号', 'type': 'text'},
        {'key': 'closingBalance', 'label': '期末余额金额', 'type': 'money'},
      ],
      'directoryApplied': false,
    };
    if (unknownAux) throw NetworkTimeoutException();
    return preview!;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    applyBodies.add(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(body)) as Map),
    );
    if (unknownApply) throw NetworkTimeoutException();
    return {'status': 'DIRECTORY_DRAFTS_APPLIED'};
  }
}
