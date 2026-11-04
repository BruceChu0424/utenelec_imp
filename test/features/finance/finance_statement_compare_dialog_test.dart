import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/features/finance/widgets/finance_statement_compare_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

const _scope = <String, dynamic>{
  'templateKey': 'supplierStatement',
  'partyRole': 'SUPPLIER',
  'partyId': 'supplier-1',
  'currencyId': 'currency-1',
  'dateFrom': '2026-09-01',
  'dateTo': '2026-09-30',
};
const _precise = '80.000000000000000000000001';
void main() {
  testWidgets(
    'external original keeps eight columns and manual associations through a hard reopen',
    (tester) async {
      final api = _Api(), storage = MemoryFormDraftStorage();
      var container = await _mount(tester, api, storage);
      await tester.tap(find.text('导入原表'));
      await tester.pumpAndSettle();
      var source = _table(tester, 'source'), actual = _table(tester, 'actual');
      expect(source.columns.skip(2).map((c) => c.label), _labels);
      expect(actual.columns.skip(1).map((c) => c.label), _labels);
      expect(actual.items.single['amount'], _precise);
      source.onRowTap!(source.items.single);
      await tester.pumpAndSettle();
      actual = _table(tester, 'actual');
      actual.onRowTap!(actual.items.single);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      final draft = container.read(formDraftsProvider).single;
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      container = await _mount(tester, api, storage, resume: draft.id);
      expect(find.textContaining('已对应1行'), findsOneWidget);
      expect(_table(tester, 'source').items.single['__mapping'], '1');
      await tester.tap(find.text('逐列比对'));
      await tester.pumpAndSettle();
      expect(api.comparisons, hasLength(1));
      expect(api.comparisons.single['rows'], [
        {'sourceRow': 7, 'reportRowNumber': 1},
      ]);
      expect(api.comparisons.single['context'], _scope);
      expect(api.comparisons.single['expectedSourceFingerprint'], 'facts-1');
      expect(_table(tester, 'differences').items.single['actual'], _precise);
      expect(api.moneyWrites, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'changed facts preserve the old mapping and block an index from silently selecting a different row',
    (tester) async {
      final api = _Api();
      final container = await _mount(tester, api, MemoryFormDraftStorage());
      await tester.tap(find.text('导入原表'));
      await tester.pumpAndSettle();
      var table = _table(tester, 'source');
      table.onRowTap!(table.items.single);
      await tester.pumpAndSettle();
      table = _table(tester, 'actual');
      table.onRowTap!(table.items.single);
      await tester.pumpAndSettle();
      api.fingerprint = 'facts-2';
      await tester.tap(find.text('刷新实际原件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('旧行对应保留'), findsOneWidget);
      expect(_table(tester, 'source').items.single['__mapping'], '旧对应待核对');
      final compare = tester.widget<UtenButton>(
        find.widgetWithText(UtenButton, '逐列比对'),
      );
      expect(compare.onPressed, isNull);
      expect(api.comparisons, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
  testWidgets(
    'large source and actual reports mount only one page and private data stays retired after permission ABA',
    (tester) async {
      final grants = StateProvider<Set<String>>(
        (ref) => {
          Perm.financeReportView,
          Perm.financeViewAll,
          Perm.paymentStyleEdit,
        },
      );
      final api = _Api()
        ..sourceCount = 2000
        ..actualCount = 20000;
      final container = await _mount(
        tester,
        api,
        MemoryFormDraftStorage(),
        permissions: grants,
      );
      await tester.tap(find.text('导入原表'));
      await tester.pumpAndSettle();
      expect(_table(tester, 'source').items, hasLength(50));
      expect(_table(tester, 'source').totalPages, 40);
      expect(_table(tester, 'actual').items, hasLength(50));
      expect(_table(tester, 'actual').totalPages, 400);
      final old = container.read(grants);
      container.read(grants.notifier).state = {};
      await tester.pumpAndSettle();
      expect(find.textContaining('anonymous-original.xlsx'), findsNothing);
      expect(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
        findsNothing,
      );
      container.read(grants.notifier).state = old;
      await tester.pumpAndSettle();
      expect(find.textContaining('anonymous-original.xlsx'), findsNothing);
      expect(api.comparisons, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    },
  );
}

MasterDataTableView<Map<String, dynamic>> _table(
  WidgetTester tester,
  String suffix,
) => tester
    .widgetList<MasterDataTableView<Map<String, dynamic>>>(
      find.byType(MasterDataTableView<Map<String, dynamic>>),
    )
    .singleWhere(
      (table) => table.tableKey == 'finance.statement.compare.$suffix',
    );
Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Api api,
  MemoryFormDraftStorage storage, {
  String? resume,
  StateProvider<Set<String>>? permissions,
}) async {
  await tester.binding.setSurfaceSize(const Size(1380, 1000));
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
        }),
      sharedPreferencesProvider.overrideWithValue(prefs),
      formDraftStorageProvider.overrideWithValue(storage),
      financeEntryFilePickerProvider.overrideWithValue(
        () async => PlatformFile(
          name: 'anonymous-original.xlsx',
          size: 4,
          bytes: Uint8List.fromList([1, 2, 3, 4]),
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
              onPressed: () => showFinanceStatementCompareDialog(
                context,
                scope: _scope,
                resumeDraftId: resume,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return container;
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

const _labels = ['送货日期', '物料编码', '物料名称', '单位', '数量', '含税单价', '含税金额', '备注'];
const _keys = [
  'billDate',
  'goodsCode',
  'goodsName',
  'unit',
  'qty',
  'price',
  'amount',
  'remark',
];

class _Api extends ApiClient {
  _Api() : super(Dio());
  String fingerprint = 'facts-1';
  int sourceCount = 1, actualCount = 1, moneyWrites = 0;
  final comparisons = <Map<String, dynamic>>[];
  Map<String, dynamic> get source => {
    'importId': 'source-1',
    'sha256': 'a' * 64,
    'sourceName': 'anonymous-original.xlsx',
    'headers': _labels,
    'issues': <Object>[],
    'rows': [
      for (int row = 0; row < sourceCount; row++)
        {
          'sourceRow': row + 7,
          'issues': <Object>[],
          'cells': [
            for (int col = 0; col < 8; col++)
              {
                'column': col + 1,
                'kind': 'STRING',
                'text': col == 6
                    ? '80.000000000000000000000000'
                    : col == 0
                    ? '2026-09-05'
                    : 'source-$row-$col',
              },
          ],
        },
    ],
  };
  Map<String, dynamic> get actual => {
    'sourceFingerprint': fingerprint,
    'columns': [
      for (int col = 0; col < 8; col++)
        {
          'key': _keys[col],
          'label': _labels[col],
          'type': col >= 4 && col <= 6 ? 'money' : 'text',
        },
    ],
    'rows': [
      for (int row = 0; row < actualCount; row++)
        {
          for (int col = 0; col < 8; col++)
            _keys[col]: col == 6
                ? _precise
                : col == 0
                ? '2026-09-05'
                : 'actual-$row-$col',
        },
    ],
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => source;
  @override
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List bytes, {
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    Duration? sendTimeout,
    Duration? receiveTimeout,
  }) async => source;
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/preview')) return {'source': source, 'actual': actual};
    if (path == '/finance/statement-documents/comparisons') {
      comparisons.add(Map<String, dynamic>.from(body as Map));
      return {
        'results': [
          {
            'sourceRow': 7,
            'reportRowNumber': 1,
            'status': 'DIFFERENT',
            'cells': [
              {
                'column': 7,
                'label': '含税金额',
                'source': '80.000000000000000000000000',
                'actual': _precise,
                'status': 'DIFFERENT',
              },
            ],
          },
        ],
        'unmappedSourceRows': <Object>[],
        'unmappedActualRows': <Object>[],
      };
    }
    moneyWrites++;
    throw StateError('Unexpected financial write $path');
  }
}
