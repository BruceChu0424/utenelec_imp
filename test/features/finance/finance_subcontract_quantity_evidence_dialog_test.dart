import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/features/finance/widgets/finance_subcontract_quantity_evidence_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

const _scope = <String, dynamic>{
  'supplierId': 'supplier-real',
  'dateFrom': '2026-10-01',
  'dateTo': '2026-10-31',
};
const _seed = <String, dynamic>{
  '__goodsId': 'material-real',
  '__colorId': null,
  'goodsCode': 'M-REAL',
  'goodsName': '原真实材料',
};
const _exact = '12.000000000000000000000001';
final _bytes = Uint8List.fromList([0, 255, 7, 8, 9, 14]);
Finder _field(String label) =>
    find.byWidgetPredicate((w) => w is UtenInput && w.label == label);
Finder _dropdown(String label) =>
    find.byWidgetPredicate((w) => w is UtenDropdownField && w.label == label);
Future<void> _tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester) async {
  await tester.enterText(_field('原PCS输入'), _exact);
  await tester.enterText(_field('真实凭据/实盘日期'), '2026-09-30');
  await tester.enterText(_field('真实依据'), '原实盘凭据，数值与原字节均保留');
  tester.widget<UtenDropdownField>(_dropdown('采用用途')).onChanged('USE');
  await tester.pumpAndSettle();
  await _tap(tester, '选择真实凭据');
}

Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : {};
void main() {
  testWidgets(
    'accepted evidence directory projection retires after rejection',
    (tester) async {
      final api = _Api()..directoryTotal = 101;
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        directory: true,
      );
      await _completeTable(tester);
      api.failKind = 'DIRECTORY';
      api.failPage = 2;
      await _tap(tester, '刷新');
      final finder = find.byType(MasterDataTableView<Map<String, dynamic>>);
      await _waitForReadError(tester, finder);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        finder,
      );
      expect(table.items, isEmpty);
      expect(table.error, '后批无权限');
      expect(api.sent, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  for (final kind in ['GROUP', 'RECEIPT']) {
    testWidgets(
      'accepted $kind candidates retire on403 and preserve the input query',
      (tester) async {
        final api = _Api();
        final container = await _mount(
          tester,
          api,
          MemoryFormDraftStorage(),
          purpose: kind == 'GROUP' ? 'PERIOD_OPENING' : 'ROW_CORRESPONDENCE',
        );
        await _tap(tester, kind == 'GROUP' ? '选择真实材料和颜色' : '选择原业务行');
        await _completeTable(tester);
        await tester.enterText(_field('搜索真实单号或商品'), '原查询保留');
        api.failKind = kind;
        api.failPage = 2;
        await _tap(tester, '查询');
        final finder = find
            .byType(MasterDataTableView<Map<String, dynamic>>)
            .last;
        await _waitForReadError(tester, finder);
        final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
          finder,
        );
        expect(table.items, isEmpty);
        expect(table.error, '后批无权限');
        expect(
          tester.widget<UtenInput>(_field('搜索真实单号或商品')).controller!.text,
          '原查询保留',
        );
        expect(api.sent, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        container.dispose();
      },
    );
  }
  testWidgets(
    'quantity directory collects every exact record and scrolling stays local',
    (tester) async {
      final api = _Api()..directoryTotal = 101;
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        directory: true,
      );
      final table = await _completeTable(tester);
      expect(table.items.last['id'], 'quantity-100');
      expect(_map(table.items.last['input'])['quantityPcs'], _exact);
      expect(table.totalPages, 1);
      expect(table.onPageChange, isNull);
      await _scrollLocally(tester, api, '实际材料100');
      // Progressive complete read (2026-11-08): 50, then aligned 50/100 —
      // offsets 0/50/100, every record exactly once.
      expect(api.reads.map((q) => q['size']), [50, 50, 100]);
      expect(api.reads.map((q) => q['page']), [1, 2, 2]);
      expect(api.sent, isEmpty);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  for (final kind in [
    'MATERIAL_ISSUE',
    'MATERIAL_RETURN',
    'RECEIPT',
    'PRODUCT_RETURN',
  ]) {
    testWidgets(
      '$kind picker retains every real source UUID and original unit',
      (tester) async {
        final api = _Api();
        final container = await _mount(
          tester,
          api,
          MemoryFormDraftStorage(),
          purpose: 'ROW_CORRESPONDENCE',
        );
        tester.widget<UtenDropdownField>(_dropdown('原业务来源')).onChanged(kind);
        await tester.pumpAndSettle();
        await _tap(tester, '选择原业务行');
        final table = await _completeTable(tester);
        final source = _map(table.items.last['source']);
        expect(_map(source['source'])['kind'], kind);
        expect(
          _map(source['source'])['itemId'],
          '${kind == 'MATERIAL_ISSUE' ? 'issue' : 'receipt'}-100',
        );
        expect(source['unitId'], 'pcs-real');
        expect(
          source['quantityOriginal'],
          kind == 'MATERIAL_ISSUE' ? '10' : '3',
        );
        expect(
          source['amountOriginal'],
          kind == 'MATERIAL_ISSUE' ? null : '150',
        );
        final queries = api.reads.where((q) => q['kind'] == kind).toList();
        // Progressive complete read (2026-11-08): 50, then aligned 50/100 —
        // offsets 0/50/100, every source exactly once.
        expect(queries.map((q) => q['size']), [50, 50, 100]);
        expect(queries.map((q) => q['page']), [1, 2, 2]);
        expect(
          queries.map((q) => q['supplierId']),
          everyElement('supplier-real'),
        );
        await _scrollLocally(
          tester,
          api,
          '${kind == 'MATERIAL_ISSUE' ? 'ISSUE' : 'RCV'}-100',
        );
        table.onRowTap!(table.items.last);
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            '${kind == 'MATERIAL_ISSUE' ? 'ISSUE' : 'RCV'}-100',
          ),
          findsWidgets,
        );
        expect(api.sent, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        container.dispose();
      },
    );
  }
  testWidgets(
    'group picker keeps goods color and different source units distinct',
    (tester) async {
      final api = _Api();
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      await _tap(tester, '选择真实材料和颜色');
      final table = await _completeTable(tester);
      expect(table.items[0]['goodsId'], table.items[1]['goodsId']);
      expect(table.items[0]['unitId'], isNot(table.items[1]['unitId']));
      expect(table.items.last['goodsName'], '真实材料100');
      await _scrollLocally(tester, api, '真实材料100');
      table.onRowTap!(table.items.last);
      await tester.pumpAndSettle();
      expect(find.textContaining('真实材料100'), findsWidgets);
      expect(api.sent, isEmpty);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'source continuation denial publishes no choices and retains exact form and file',
    (tester) async {
      final api = _Api()
        ..failKind = 'RECEIPT'
        ..failPage = 2;
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        purpose: 'ROW_CORRESPONDENCE',
      );
      await _fill(tester);
      await _tap(tester, '选择原业务行');
      final finder = find
          .byType(MasterDataTableView<Map<String, dynamic>>)
          .last;
      await _waitForReadError(tester, finder);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        finder,
      );
      expect(table.items, isEmpty);
      expect(table.error, isNotEmpty);
      expect(
        api.reads.any((q) => q['kind'] == 'RECEIPT' && q['page'] == 2),
        isTrue,
      );
      expect(api.sent, isEmpty);
      Navigator.of(tester.element(finder)).pop();
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenInput>(_field('原PCS输入')).controller!.text,
        _exact,
      );
      expect(find.text('actual-count.png'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'quantity directory continuation denial never becomes partial evidence',
    (tester) async {
      final api = _Api()
        ..directoryTotal = 101
        ..failKind = 'DIRECTORY'
        ..failPage = 2;
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        directory: true,
      );
      final finder = find.byType(MasterDataTableView<Map<String, dynamic>>);
      await _waitForReadError(tester, finder);
      expect(
        tester.widget<MasterDataTableView<Map<String, dynamic>>>(finder).items,
        isEmpty,
      );
      expect(api.sent, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets('a different source kind cannot masquerade as a requested UUID', (
    tester,
  ) async {
    final api = _Api()..wrongKind = true;
    final container = await _mount(
      tester,
      api,
      MemoryFormDraftStorage(),
      purpose: 'ROW_CORRESPONDENCE',
    );
    await _tap(tester, '选择原业务行');
    final finder = find.byType(MasterDataTableView<Map<String, dynamic>>);
    await _waitForReadError(tester, finder);
    expect(
      tester.widget<MasterDataTableView<Map<String, dynamic>>>(finder).items,
      isEmpty,
    );
    expect(api.sent, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
  testWidgets(
    'current period directory opens a related prior source in its original scope',
    (tester) async {
      final api = _Api();
      final record = <String, dynamic>{
        'id': 'quantity-prior',
        'revision': 0,
        'status': 'APPROVED',
        'submitted_by': 'finance-operator',
        'input': {
          'scope': _scope,
          'purpose': 'ROW_CORRESPONDENCE',
          'evidenceType': 'BILATERAL_SETTLEMENT_EQUIVALENCE',
          'source': {'kind': 'RECEIPT', 'itemId': 'receipt-0'},
          'materialIssueItemId': 'issue-0',
          'stockGroup': {
            'goodsId': 'material-real',
            'colorId': null,
            'pcsUnitId': 'pcs-real',
          },
          'quantityPcs': '4',
          'evidenceDate': '2026-10-15',
          'enabled': true,
          'applyToStatement': true,
          'sourceReference': '原期间双方已审4PCS',
        },
        'source': api._choice('RECEIPT', 0)['source'],
        'materialSource': api._choice('MATERIAL_ISSUE', 0)['source'],
        'appliedQuantityPcs': '4',
        'stockGroupReference': {'goodsCode': 'M-REAL', 'goodsName': '原真实材料'},
        'attachment': {
          'sha256': 'prior-actual-sha',
          'filename': 'prior-evidence.png',
        },
      };
      api.directoryRecord = record;
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        directory: true,
        scope: {
          'supplierId': 'supplier-real',
          'dateFrom': '2026-11-01',
          'dateTo': '2026-11-30',
        },
      );
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      expect(table.items, hasLength(1));
      table.onRowTap!(table.items.single);
      await tester.pumpAndSettle();
      expect(find.text('原数量版本不属于本供应商或期间'), findsNothing);
      await _tap(tester, '更正或停用');
      expect(tester.widget<UtenInput>(_field('原PCS输入')).controller!.text, '4');
      await _tap(tester, '提交审核');
      expect(_map(_map(api.sent.single['body'])['input'])['scope'], _scope);
      expect(api.sent.single['bytes'], isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'count input and original file bytes survive unknown result and hard reopen without creating a new request',
    (tester) async {
      final api = _Api()..unknown = true, storage = MemoryFormDraftStorage();
      var container = await _mount(tester, api, storage);
      await _fill(tester);
      await _tap(tester, '提交审核');
      expect(api.sent, hasLength(1));
      final original = api.sent.single;
      expect(original['bytes'], _bytes);
      expect(_map(_map(original['body'])['input'])['quantityPcs'], _exact);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      final draft = container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(base64Decode(draft.data['fileBytes'] as String), _bytes);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      container = await _mount(tester, api, storage, resume: draft.id);
      expect(
        tester.widget<UtenInput>(_field('原PCS输入')).controller!.text,
        _exact,
      );
      expect(tester.widget<UtenInput>(_field('原PCS输入')).enabled, isFalse);
      api.unknown = false;
      await _tap(tester, '重试原请求');
      expect(api.sent, hasLength(2));
      expect(api.sent.last, original);
      expect(container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'restored future business body and headers replay verbatim with original file ownership',
    (tester) async {
      final api = _Api(), storage = MemoryFormDraftStorage();
      var container = await _mount(tester, api, storage);
      await _fill(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final prior = container.read(formDraftsProvider).single,
          data = Map<String, dynamic>.from(prior.data);
      final body = <String, dynamic>{
        'requestId': 'original-request',
        'expectedRevision': -1,
        'input': {
          'scope': _scope,
          'purpose': 'PERIOD_OPENING',
          'evidenceType': 'PHYSICAL_COUNT',
          'source': null,
          'materialIssueItemId': null,
          'stockGroup': {
            'goodsId': 'material-real',
            'colorId': null,
            'pcsUnitId': 'pcs-real',
          },
          'quantityPcs': _exact,
          'evidenceDate': '2026-09-30',
          'enabled': true,
          'applyToStatement': true,
          'sourceReference': '原实盘凭据，数值与原字节均保留',
        },
        'attachmentEvidenceId': null,
        'futureContract': {
          'originalNumericText':
              '12345678901234567890.000000000000000000000001',
        },
      };
      final headers = <String, dynamic>{
        'X-Original-Request-Key': 'original-business-key',
        'X-Future-Contract': 'keep-this-value',
      };
      data[formDraftUnknownSubmissionKey] = true;
      data['pending'] = {
        'path': '/finance/subcontract-quantity-evidence',
        'body': body,
        'headers': headers,
        'actorId': 'finance-operator',
        'hasFile': true,
        'filename': data['filename'],
        'contentType': data['contentType'],
        'fileHash': data['fileHash'],
      };
      await container
          .read(formDraftsProvider.notifier)
          .save(
            FormDraft(
              id: prior.id,
              title: prior.title,
              module: prior.module,
              route: prior.route,
              permission: prior.permission,
              updatedAt: DateTime.now(),
              data: data,
              draftKind: prior.draftKind,
            ),
            expectedRevision: prior.revision,
          );
      container.dispose();
      container = await _mount(tester, api, storage, resume: prior.id);
      await _tap(tester, '重试原请求');
      expect(api.sent, hasLength(1));
      expect(api.sent.single['body'], body);
      expect(api.sent.single['headers'], headers);
      expect(api.sent.single['bytes'], _bytes);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'in-flight interruption persists raw bytes and late success cannot close the restored editor',
    (tester) async {
      final api = _Api()..gate = Completer<Map<String, dynamic>>(),
          storage = MemoryFormDraftStorage();
      var container = await _mount(tester, api, storage);
      await _fill(tester);
      await tester.ensureVisible(find.text('提交审核'));
      await tester.tap(find.text('提交审核'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      expect(api.sent, hasLength(1));
      final draft = container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      container = await _mount(tester, api, storage, resume: draft.id);
      api.gate!.complete({'id': 'quantity-1'});
      await tester.pumpAndSettle();
      expect(find.text('核对原请求回执'), findsOneWidget);
      expect(api.sent, hasLength(1));
      api.receipt = true;
      await _tap(tester, '核对原请求回执');
      expect(api.sent, hasLength(1));
      expect(container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'receipt with matching id but different original file hash cannot clear an unknown request',
    (tester) async {
      final api = _Api()..unknown = true;
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      await _fill(tester);
      await _tap(tester, '提交审核');
      api.receipt = true;
      api.wrongFile = true;
      await _tap(tester, '核对原请求回执');
      expect(
        container.read(formDraftsProvider).single.hasUnknownSubmission,
        isTrue,
      );
      expect(find.text('重试原请求'), findsOneWidget);
      expect(api.sent, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'receipt and material are selected by exact source UUID and order, without rewriting original charge',
    (tester) async {
      final api = _Api();
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        purpose: 'ROW_CORRESPONDENCE',
      );
      await _tap(tester, '选择原业务行');
      var table = await _completeTable(tester);
      expect(table.items, hasLength(101));
      expect(table.totalPages, 1);
      expect(table.onPageChange, isNull);
      table.onRowTap!(table.items.first);
      await tester.pumpAndSettle();
      await _tap(tester, '选择实际原发料行');
      table = await _completeTable(tester);
      expect(api.lastQuery!['orderItemId'], 'order-exact');
      table.onRowTap!(table.items.first);
      await tester.pumpAndSettle();
      await tester.enterText(_field('原PCS输入'), '4');
      await tester.enterText(_field('真实凭据/实盘日期'), '2026-10-15');
      await tester.enterText(_field('真实依据'), '双方结算当量4，与真实来源计价3×50=150分开');
      tester.widget<UtenDropdownField>(_dropdown('采用用途')).onChanged('USE');
      await tester.pumpAndSettle();
      await _tap(tester, '选择真实凭据');
      await _tap(tester, '提交审核');
      final input = _map(_map(api.sent.single['body'])['input']);
      expect(input['source'], {'kind': 'RECEIPT', 'itemId': 'receipt-0'});
      expect(input['materialIssueItemId'], 'issue-0');
      expect(_map(input['stockGroup'])['goodsId'], 'material-real');
      expect(input['quantityPcs'], '4');
      expect(input.containsKey('priceOriginal'), isFalse);
      expect(input.containsKey('amountOriginal'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'permission ABA retires original file form and narrow controls remain usable',
    (tester) async {
      final grants = StateProvider<Set<String>>(
        (ref) => {
          Perm.financeReportView,
          Perm.financeViewAll,
          Perm.paymentStyleEdit,
        },
      );
      final container = await _mount(
        tester,
        _Api(),
        MemoryFormDraftStorage(),
        grants: grants,
        narrow: true,
      );
      await _fill(tester);
      expect(tester.takeException(), isNull);
      final old = container.read(grants);
      container.read(grants.notifier).state = {};
      await tester.pumpAndSettle();
      expect(find.text('actual-count.png'), findsNothing);
      container.read(grants.notifier).state = old;
      await tester.pumpAndSettle();
      expect(find.text('actual-count.png'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
}

Future<MasterDataTableView<Map<String, dynamic>>> _completeTable(
  WidgetTester tester,
) async {
  final finder = find.byType(MasterDataTableView<Map<String, dynamic>>).last;
  for (var attempt = 0; attempt < 60; attempt++) {
    final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
      finder,
    );
    if (!table.isLoading && table.items.length == 101) return table;
    await tester.pump(const Duration(milliseconds: 50));
  }
  final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
    finder,
  );
  expect(table.items, hasLength(101), reason: table.error);
  return table;
}

Future<void> _waitForReadError(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 60; attempt++) {
    final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
      finder,
    );
    if (!table.isLoading && table.error != null) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(
    tester.widget<MasterDataTableView<Map<String, dynamic>>>(finder).error,
    isNotNull,
    reason: 'The actual rejection must complete and remain observable.',
  );
}

Future<void> _scrollLocally(WidgetTester tester, _Api api, String tail) async {
  final count = api.reads.length;
  await tester.drag(
    find.byType(MasterDataTableView<Map<String, dynamic>>).last,
    const Offset(0, -6000),
  );
  await tester.pumpAndSettle();
  expect(find.textContaining(tail), findsOneWidget);
  expect(api.reads, hasLength(count));
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api,
  MemoryFormDraftStorage storage, {
  String? resume,
  String purpose = 'PERIOD_OPENING',
  StateProvider<Set<String>>? grants,
  bool narrow = false,
  bool directory = false,
  Map<String, dynamic> scope = _scope,
}) async {
  await tester.binding.setSurfaceSize(
    narrow ? const Size(390, 900) : const Size(1300, 1100),
  );
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://finance-draft.test/api'),
      sessionProvider.overrideWith(_Session.new),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'finance-operator'),
      ),
      if (grants != null)
        currentPermissionsProvider.overrideWith((ref) => ref.watch(grants))
      else
        currentPermissionsProvider.overrideWithValue({
          Perm.financeReportView,
          Perm.financeViewAll,
          Perm.paymentStyleEdit,
          Perm.financePostExecute,
        }),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
      financeConfirmationFilePickerProvider.overrideWithValue(
        () async => PlatformFile(
          name: 'actual-count.png',
          size: _bytes.length,
          bytes: _bytes,
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFinanceSubcontractQuantityEvidenceDialog(
                context,
                scope: scope,
                purpose: purpose,
                sourceRow: directory ? null : _seed,
                resumeDraftId: resume,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await _tap(tester, '打开');
  return container;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  bool unknown = false, receipt = false, wrongFile = false;
  Completer<Map<String, dynamic>>? gate;
  final sent = <Map<String, dynamic>>[];
  Map<String, dynamic>? lastQuery;
  Map<String, dynamic>? directoryRecord;
  int? directoryTotal, failPage;
  String? failKind;
  bool wrongKind = false;
  final reads = <Map<String, dynamic>>[];
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [
    {'id': 'pcs-real', 'code': 'PCS', 'name': '件'},
  ];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    lastQuery = query;
    if (directoryTotal != null &&
        path.endsWith('/subcontract-quantity-evidence')) {
      return _page(
        'DIRECTORY',
        query!,
        directoryTotal!,
        (i) => {
          'id': 'quantity-$i',
          'revision': 0,
          'status': 'APPROVED',
          'input': {
            'scope': _scope,
            'purpose': 'PERIOD_OPENING',
            'evidenceType': 'PHYSICAL_COUNT',
            'quantityPcs': _exact,
            'enabled': true,
            'applyToStatement': true,
          },
          'stockGroupReference': {'goodsCode': 'M-$i', 'goodsName': '实际材料$i'},
          'appliedQuantityPcs': '12',
          'bookEstimatedPcs': '10',
        },
      );
    }
    if (directoryRecord != null && path.endsWith('/quantity-prior')) {
      return directoryRecord!;
    }
    if (directoryRecord != null &&
        path.endsWith('/subcontract-quantity-evidence')) {
      return {
        'items': [directoryRecord!],
        'totalPages': 1,
      };
    }
    if (path.contains('/operations/')) {
      if (!receipt) {
        throw ApiException(
          'NOT_FOUND',
          '本人原请求尚未取得成功回执',
          hasResponseCode: true,
          httpStatus: 404,
        );
      }
      final command = sent.single, body = _map(command['body']);
      return {
        'id': 'quantity-1',
        'requestId': body['requestId'],
        'submitted_by': 'finance-operator',
        'revision': 0,
        'input': body['input'],
        'attachment': {
          'sha256': wrongFile ? 'different-file' : command['fileHash'],
        },
      };
    }
    if (path.endsWith('/sources')) {
      final kind = query!['kind'].toString();
      return _page(
        kind,
        query,
        101,
        (i) => _choice(wrongKind ? 'MATERIAL_ISSUE' : kind, i),
      );
    }
    if (path.endsWith('/source-choices')) {
      return _page(
        'GROUP',
        query!,
        101,
        (i) => {
          'goodsId': 'group-${i ~/ 2}',
          'colorId': null,
          'unitId': i.isEven ? 'pcs-source' : 'weight-source',
          'goodsCode': 'G-$i',
          'goodsName': '真实材料$i',
          'unitName': i.isEven ? '件' : '千克',
        },
      );
    }
    return {'items': <Object>[], 'totalPages': 0};
  }

  Map<String, dynamic> _page(
    String kind,
    Map<String, dynamic> query,
    int total,
    Map<String, dynamic> Function(int) row,
  ) {
    final page = query['page'] as int, size = query['size'] as int;
    reads.add({...query, 'kind': kind});
    if (page == failPage && kind == failKind) {
      throw ApiException(
        'FORBIDDEN',
        '后批无权限',
        httpStatus: 403,
        hasResponseCode: true,
      );
    }
    return {
      'items': [
        for (var i = (page - 1) * size; i < page * size && i < total; i++)
          row(i),
      ],
      'page': page,
      'size': size,
      'total': total,
      'totalPages': (total / size).ceil(),
    };
  }

  Map<String, dynamic> _choice(String kind, int i) {
    final material = kind == 'MATERIAL_ISSUE';
    return {
      'source': {
        'source': {
          'kind': kind,
          'itemId': '${material ? 'issue' : 'receipt'}-$i',
        },
        'documentId': 'document-$i',
        'billNo': '${material ? 'ISSUE' : 'RCV'}-$i',
        'businessDate': '2026-10-15',
        'supplierId': 'supplier-real',
        'goodsId': material ? 'material-real' : 'product-real',
        'colorId': null,
        'unitId': 'pcs-real',
        'goodsCode': material ? 'M-REAL' : 'P-REAL',
        'goodsName': '同名真实货品',
        'unitCode': 'PCS',
        'unitName': '件',
        'quantityOriginal': material ? '10' : '3',
        'priceOriginal': material ? null : '50',
        'amountOriginal': material ? null : '150',
        'sourceBasis': 'ORIGINAL_APPROVED_DOCUMENT',
        'identityFingerprint': 'source-$kind-$i',
      },
      'orderItemId': 'order-exact',
      'materialIssueItemId': material ? 'issue-$i' : null,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    sent.add({
      'path': path,
      'body': jsonDecode(jsonEncode(body)),
      'headers': headers ?? {},
      'bytes': <int>[],
    });
    return {'id': 'quantity-next'};
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
    final body = _map(jsonParts['input']);
    final command = <String, dynamic>{
      'path': path,
      'body': jsonDecode(jsonEncode(body)),
      'bytes': List<int>.from(bytes),
      'filename': filename,
      'contentType': contentType,
      'headers': headers ?? {},
    };
    command['fileHash'] = sha256.convert(bytes).toString();
    sent.add(command);
    if (gate != null) return gate!.future;
    if (unknown) throw NetworkTimeoutException();
    return {'id': 'quantity-1'};
  }
}
