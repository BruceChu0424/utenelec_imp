import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import '../../support/audit_screenshot_support.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:uten_imp/features/finance/widgets/finance_statement_supplemental_cells.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/widgets/finance_statement_document_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
import 'finance_requirement_test_ui.dart';

const _scope = {
  'templateKey': 'supplierStatement',
  'partyRole': 'SUPPLIER',
  'partyId': '10000000-0000-0000-0000-000000000001',
  'currencyId': '10000000-0000-0000-0000-000000000002',
  'dateFrom': '2026-09-01',
  'dateTo': '2026-09-30',
};
void main() {
  testWidgets(
    'settlement original requires explicit preview and retains its exact unknown submission on hard restore',
    (tester) async {
      final api = _Api()..loseFirst = true;
      final storage = MemoryFormDraftStorage();
      final first = await _mount(
        tester,
        api,
        storage,
        mode: 'SETTLEMENT',
        target: 'original',
      );
      await tester.enterText(financeTextField('实际来源依据'), '按本单真实处理依据');
      await tester.tap(find.text('保存新版本'));
      await tester.pumpAndSettle();
      expect(api.commands, isEmpty);
      await tester.tap(find.text('核对结算原件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('74.999999999999999999999999'), findsWidgets);
      await tester.enterText(financeTextField('实际来源依据'), '另一份依据需要重新预览');
      await tester.tap(find.text('保存新版本'));
      await tester.pumpAndSettle();
      expect(api.commands, isEmpty);
      await tester.tap(find.text('核对结算原件'));
      await tester.pumpAndSettle();
      api.gate = Completer<void>();
      final savePoint = tester.getCenter(find.text('保存新版本'));
      for (int n = 0; n < 8; n++) {
        await tester.tapAt(savePoint);
      }
      expect(api.commands, hasLength(1));
      api.gate!.complete();
      api.gate = null;
      await tester.pumpAndSettle();
      expect(api.commands, hasLength(1));
      final editor =
          tester.state(find.byType(FinanceStatementDocumentEditor))
              as FormDraftMixin<FinanceStatementDocumentEditor>;
      await editor.saveFormDraftNow();
      final draft = first.read(formDraftsProvider).single;
      final original = jsonEncode(api.commands.single);
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      final second = await _mount(
        tester,
        api,
        storage,
        mode: 'SETTLEMENT',
        target: 'original',
        resume: draft.id,
        width: 430,
      );
      expect(
        tester.widget<TextField>(financeTextField('实际来源依据')).controller!.text,
        '另一份依据需要重新预览',
      );
      await tester.tap(find.text('核对原提交并继续'));
      await tester.pumpAndSettle();
      expect(api.commands, hasLength(2));
      expect(jsonEncode(api.commands.last), original);
      expect(
        api.commands.last['source'],
        containsPair('basedReviewId', 'original'),
      );
      expect(
        api.commands.last['source'],
        containsPair('expectedBasedFingerprint', 'b' * 64),
      );
      expect(api.commits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      second.dispose();
    },
  );
  testWidgets(
    'settlement original explicitly records no deductions without making zero the default',
    (tester) async {
      final api = _Api();
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        mode: 'SETTLEMENT',
        target: 'original',
        width: 430,
      );
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await tester.tap(find.text('本次没有手续费及尾数扣款'));
      await tester.enterText(financeTextField('实际来源依据'), '逐笔核对确无额外扣款');
      await tester.tap(find.text('核对结算原件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存新版本'));
      await tester.pumpAndSettle();
      expect(
        api.commands.single['source'],
        containsPair('explicitlyNoDeductions', true),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'frozen original keeps exact columns groups decimal facts and original export scope',
    (tester) async {
      final api = _Api();
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        mode: 'DIRECTORY',
      );
      await tester.tap(find.text('实际提交人').first);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('实际提交人').first);
      await tester.pumpAndSettle();
      final tables = tester
          .widgetList<MasterDataTableView<Map<String, dynamic>>>(
            find.byType(MasterDataTableView<Map<String, dynamic>>),
          );
      final original = tables.singleWhere(
        (table) =>
            table.tableKey?.startsWith('finance-statement-original-') == true,
      );
      expect(original.columns.map((c) => c.label), [
        '原日期',
        '订单号',
        '原数量',
        '原金额',
      ]);
      expect(original.columns[2].headerGroups.single.id, 'original:B4');
      final button = original.toolbarActions!
          .whereType<UtenPrintPreviewButton>()
          .single;
      expect(button.applyTableProjection, isFalse);
      expect(button.exportQuery!['statementReviewId'], 'original');
      final loaded = await tester.runAsync(button.loader);
      expect(loaded!.headers, ['原日期', '订单号', '原数量', '原金额']);
      expect(loaded.documentMetadata['reviewId'], 'original');
      expect(loaded.documentHeaderLines, contains('客户名称：真实原客户'));
      expect(loaded.rows.single.last, '12345678901234567890.1234');
      expect(loaded.rows.single[2], '12345678901234567890.1234');
      expect(loaded.headerGroups[2].single.id, 'original:B4');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'retired original directory and editor hide private metadata and do not revive on ABA',
    (tester) async {
      final grants = StateProvider<Set<String>>(
        (ref) => {
          Perm.financeReportView,
          Perm.financeViewAll,
          Perm.paymentStyleEdit,
          Perm.financePostExecute,
          Perm.supplierSettlementConfirm,
        },
      );
      final container = await _mount(
        tester,
        _Api(),
        MemoryFormDraftStorage(),
        mode: 'DIRECTORY',
        permissions: grants,
      );
      await tester.tap(find.text('实际提交人').first);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('实际提交人').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('12345678901234567890.1234'), findsWidgets);
      final original = container.read(grants);
      container.read(grants.notifier).state = {};
      await tester.pumpAndSettle();
      expect(find.textContaining('12345678901234567890.1234'), findsNothing);
      expect(find.textContaining('身份或权限已变化'), findsWidgets);
      container.read(grants.notifier).state = original;
      await tester.pumpAndSettle();
      expect(find.textContaining('12345678901234567890.1234'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );

  testWidgets(
    'original hidden calculation cells need explicit expansion and stay separate from paper columns',
    (tester) async {
      final api = _Api();
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      final metadata = <String, dynamic>{
        'canvasColumns': 17,
        'sourceFingerprint': 'one',
        'materialContextId': 'context',
        'hiddenColumns': [11, 12, 13, 14, 15, 16],
        'supplementalWidths': [5.5, 24.0, 6.3, 9.0, 7.7, 9.8, 11.6],
        'supplementalCells': [
          {
            'sourceCell': 'L4',
            'value': '原表计算标题',
            'type': 'text',
            'header': true,
          },
          {
            'sourceCell': 'Q5',
            'value': '12345678901234567890.123456789012345678901234',
            'type': 'number',
            'header': false,
          },
        ],
      };
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: FinanceStatementSupplementalCells(metadata: metadata),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('原表计算标题'), findsNothing);
      expect(find.text('展开原表隐藏计算区'), findsOneWidget);
      await tester.tap(find.text('展开原表隐藏计算区'));
      await tester.pumpAndSettle();
      expect(find.text('原表计算标题'), findsOneWidget);
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      expect(table.columns.map((col) => col.label), [
        '原表行',
        'K',
        'L',
        'M',
        'N',
        'O',
        'P',
        'Q',
      ]);
      expect(
        table.items.last['16'],
        '12345678901234567890.123456789012345678901234',
      );
      expect(table.toolbarActions, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );

  testWidgets(
    'profile rapid repeated save preserves one exact request and immutable version',
    (tester) async {
      final api = _Api()..gate = Completer<void>();
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      await tester.enterText(financeTextField('组织名称'), '财务原组织');
      await tester.enterText(
        financeTextField('收款账户'),
        '000012345678901234567890',
      );
      await tester.enterText(financeTextField('实际来源依据'), '财务已核对原始资料');
      for (var i = 0; i < 20; i++) {
        await tester.tap(find.text('保存新版本'));
      }
      await tester.pump();
      expect(api.commands, hasLength(1));
      expect(
        (api.commands.single['organization']
            as Map<String, dynamic>)['bankAccount'],
        '000012345678901234567890',
      );
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(api.commits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'lost profile response freezes raw fields and retries identical request after hard close',
    (tester) async {
      final api = _Api()..loseFirst = true;
      final storage = MemoryFormDraftStorage();
      final first = await _mount(tester, api, storage);
      await tester.enterText(financeTextField('组织名称'), '原组织\n原文');
      await tester.enterText(
        financeTextField('收款账户'),
        '00000012345678901234567890',
      );
      await tester.enterText(financeTextField('实际来源依据'), '原件逐项核对');
      await tester.tap(find.text('保存新版本'));
      await tester.pumpAndSettle();
      expect(api.commands, hasLength(1));
      expect(
        tester.widget<TextField>(financeTextField('收款账户')).enabled,
        isFalse,
      );
      final editor =
          tester.state(find.byType(FinanceStatementDocumentEditor))
              as FormDraftMixin<FinanceStatementDocumentEditor>;
      await editor.saveFormDraftNow();
      final draft = first.read(formDraftsProvider).single;
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      final second = await _mount(tester, api, storage, resume: draft.id);
      expect(
        tester.widget<TextField>(financeTextField('收款账户')).controller!.text,
        '00000012345678901234567890',
      );
      await tester.tap(find.text('核对原提交并继续'));
      await tester.pumpAndSettle();
      expect(api.commands, hasLength(2));
      expect(jsonEncode(api.commands.first), jsonEncode(api.commands.last));
      expect(api.commits, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      second.dispose();
    },
  );
  testWidgets(
    'definite rejection unlocks original inputs while preserving account text',
    (tester) async {
      final api = _Api()..reject = true;
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      await tester.enterText(financeTextField('收款账户'), '0000123');
      await tester.tap(find.text('保存新版本'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(financeTextField('收款账户')).enabled,
        isTrue,
      );
      expect(
        tester.widget<TextField>(financeTextField('收款账户')).controller!.text,
        '0000123',
      );
      expect(api.commits, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'counterpart upload binds original SHA and exact file; lost response is recovered before another upload',
    (tester) async {
      final api = _Api()..loseUpload = true;
      final storage = MemoryFormDraftStorage();
      final container = await _mount(
        tester,
        api,
        storage,
        mode: 'COUNTERPART',
        target: 'original',
      );
      await tester.enterText(financeTextField('对方实际签署姓名'), '实际签署人');
      await tester.enterText(
        financeTextField('实际确认日期 YYYY-MM-DD'),
        '2026-09-30',
      );
      await tester.enterText(financeTextField('实际来源依据'), '原回传核对依据');
      await tester.tap(find.text('选择实际签名/盖章回传件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认本次处理'));
      await tester.pumpAndSettle();
      expect(api.uploads, 1);
      expect(api.uploadInput!['documentSha256'], 'a' * 64);
      await tester.tap(find.text('核对原提交并继续'));
      await tester.pumpAndSettle();
      expect(api.uploads, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets('profile editor retains Uten controls on narrow enlarged text', (
    tester,
  ) async {
    final container = await _mount(
      tester,
      _Api(),
      MemoryFormDraftStorage(),
      width: 390,
      scale: 1.5,
    );
    expect(find.byType(UtenInput), findsWidgets);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('UTEN_CAPTURE_FINANCE')) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('statement-editor-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        {
          final file = File(
            'output/finance-applications/screenshots/对账打印资料-窄屏-匿名测试.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        }
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
  testWidgets(
    'counterpart hard reopen retains original bytes and retries without asking for the file again',
    (tester) async {
      final api = _Api()..loseUpload = true, storage = MemoryFormDraftStorage();
      var container = await _mount(
        tester,
        api,
        storage,
        mode: 'COUNTERPART',
        target: 'original',
      );
      await tester.enterText(financeTextField('对方实际签署姓名'), '实际签署人');
      await tester.enterText(
        financeTextField('实际确认日期 YYYY-MM-DD'),
        '2026-09-30',
      );
      await tester.enterText(financeTextField('实际来源依据'), '原回传核对依据');
      await tester.tap(find.text('选择实际签名/盖章回传件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认本次处理'));
      await tester.pumpAndSettle();
      final sent = Map<String, dynamic>.from(api.uploadInput!);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      final draft = container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(base64Decode(draft.data['fileBytes'] as String), [0, 255, 7, 8]);
      api.confirmed = false;
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      container = await _mount(
        tester,
        api,
        storage,
        mode: 'COUNTERPART',
        target: 'original',
        resume: draft.id,
      );
      api.loseUpload = false;
      await tester.tap(find.text('核对原提交并继续'));
      await tester.pumpAndSettle();
      expect(api.uploads, 2);
      expect(api.uploadInput, sent);
      expect(container.read(formDraftsProvider), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets('profile editor retains Uten controls on narrow enlarged text', (
    tester,
  ) async {
    final container = await _mount(
      tester,
      _Api(),
      MemoryFormDraftStorage(),
      width: 390,
      scale: 1.5,
    );
    expect(find.byType(UtenInput), findsWidgets);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('UTEN_CAPTURE_FINANCE')) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('statement-editor-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        {
          final file = File(
            'output/finance-applications/screenshots/对账打印资料-窄屏-匿名测试.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        }
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api,
  MemoryFormDraftStorage storage, {
  String? resume,
  String mode = 'PROFILE_SAVE',
  String? target,
  double width = 1200,
  double scale = 1,
  Map<String, dynamic> scope = _scope,
  StateProvider<Set<String>>? permissions,
}) async {
  if (const bool.fromEnvironment('UTEN_CAPTURE_FINANCE')) {
    await loadAuditScreenshotFonts(tester);
  }
  await tester.binding.setSurfaceSize(Size(width, 900));
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
      if (permissions != null)
        currentPermissionsProvider.overrideWith((ref) => ref.watch(permissions))
      else
        currentPermissionsProvider.overrideWithValue({
          Perm.financeReportView,
          Perm.financeViewAll,
          Perm.paymentStyleEdit,
          Perm.financePostExecute,
          Perm.supplierSettlementConfirm,
        }),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
      financeConfirmationFilePickerProvider.overrideWithValue(
        () async => PlatformFile(
          name: 'actual.pdf',
          size: 4,
          bytes: Uint8List.fromList([0, 255, 7, 8]),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: auditScreenshotTheme(buildLightTheme()),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('statement-editor-capture'),
            child: Material(
              color: buildLightTheme().scaffoldBackgroundColor,
              child: mode == 'DIRECTORY'
                  ? FinanceStatementDocumentDialog(scope: scope)
                  : FinanceStatementDocumentEditor(
                      scope: scope,
                      mode: mode,
                      targetId: target,
                      profileKind: mode == 'PROFILE_SAVE' ? 'OWN' : null,
                      resumeDraftId: resume,
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  bool loseFirst = false, reject = false, loseUpload = false;
  Completer<void>? gate;
  int commits = 0, uploads = 0;
  final commands = <Map<String, dynamic>>[];
  Map<String, dynamic>? uploadInput;
  bool confirmed = false;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/original-table')) {
      return {
        'columns': [
          {'key': 'date', 'label': '原日期', 'type': 'date', 'width': 150},
          {'key': 'order', 'label': '订单号', 'type': 'text', 'width': 200},
          {
            'key': 'qty',
            'label': '原数量',
            'type': 'number',
            'width': 150,
            'headerGroups': [
              {'id': 'original:B4', 'label': '数量'},
            ],
          },
          {'key': 'amount', 'label': '原金额', 'type': 'money', 'width': 180},
        ],
        'rows': [
          {
            'date': '2026-09-30',
            'order': '000000123',
            'qty': '12345678901234567890.1234',
            'amount': '12345678901234567890.1234',
          },
        ],
        'page': 1,
        'size': 50,
        'total': 1,
        'totalPages': 1,
        'facets': <String, dynamic>{},
        'totals': <Object?>[],
        'documentMetadata': {
          'reviewId': 'original',
          'title': '原对账单',
          'headerLines': [
            {'label': '客户名称：', 'value': '真实原客户'},
          ],
          'footerLines': [
            {'label': '对方确认：', 'value': null},
          ],
        },
      };
    }
    if (path.endsWith('/profiles')) {
      return {'items': <Object?>[]};
    }
    if (path.endsWith('/reviews/original')) {
      return {
        'status': confirmed ? 'BOTH_CONFIRMED' : 'INTERNAL_CONFIRMED',
        'document_sha256': 'a' * 64,
        'source_fingerprint': 'b' * 64,
        if (confirmed)
          'counterpart_file_sha256': sha256.convert([0, 255, 7, 8]).toString(),
        'counterpart_file_name': 'actual.pdf',
      };
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/settlement-preview')) {
      final input = Map<String, dynamic>.from(body as Map);
      return {
        'sourceFingerprint': 'c' * 64,
        'documentMetadata': {
          'footerLines': [
            {
              'key': 'settlementNet',
              'label': '合计：',
              'value': input['explicitlyNoDeductions'] == true
                  ? '80.0000'
                  : '74.999999999999999999999999',
              'pending': false,
            },
          ],
        },
      };
    }
    if (path.endsWith('/reviews/query')) {
      return {
        'items': [
          {
            'id': 'original',
            'status': 'INTERNAL_CONFIRMED',
            'submitted_name': '实际提交人',
            'submitted_at': '2026-09-30',
            'document_sha256': 'a' * 64,
          },
        ],
        'page': 1,
        'totalPages': 1,
        'total': 1,
      };
    }
    final data = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    commands.add(data);
    if (gate != null) {
      await gate!.future;
    }
    if (reject) {
      throw ApiException(
        'VALIDATION_FAILED',
        '请完整填写来源依据',
        httpStatus: 400,
        hasResponseCode: true,
      );
    }
    if (commits == 0) {
      commits++;
    }
    if (loseFirst && commands.length == 1) {
      throw NetworkTimeoutException();
    }
    return {'id': 'saved', 'revision': 0, 'status': 'SUBMITTED'};
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
    uploads++;
    uploadInput = _mapForTest(jsonParts['input']);
    expect(bytes, [0, 255, 7, 8]);
    confirmed = true;
    if (loseUpload) {
      throw NetworkTimeoutException();
    }
    return {'status': 'BOTH_CONFIRMED'};
  }
}

Map<String, dynamic> _mapForTest(Object? value) =>
    Map<String, dynamic>.from(value as Map);
