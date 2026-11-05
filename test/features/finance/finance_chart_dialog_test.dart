import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/finance/widgets/finance_chart_dialog.dart';
import 'package:uten_imp/features/finance/widgets/finance_entry_file_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'directory export preserves display schema, code identity and the current query',
    (tester) async {
      final projections = TableColumnProjectionController();
      addTearDown(projections.dispose);
      await _pump(
        tester,
        _ChartApi()..actualImports = 1,
        projections: projections,
      );
      MasterDataTableView<Map<String, dynamic>> table() => tester.widget(
        find.byWidgetPredicate(
          (widget) =>
              widget is MasterDataTableView<Map<String, dynamic>> &&
              widget.tableKey == 'finance.chart.directory',
        ),
      );
      UtenExportButton export() => table().toolbarActions!
          .whereType<UtenExportButton>()
          .singleWhere((button) => button.report == 'gl/chart-directory');
      expect(
        table().columns
            .where((column) => column.exportable)
            .map((column) => column.key),
        ['code', 'name', 'currencyName', 'classification', 'targets'],
      );
      expect(table().outputSelectorOf!(table().items.single), {'code': '1001'});
      await tester.tap(find.text('库存现金'));
      await tester.pumpAndSettle();
      final selected = await tester.runAsync(
        () => projections.tables.single.outputSelection.snapshot(),
      );
      expect(selected!.ids, {'1001'});
      expect(selected.rows, [
        {'code': '1001'},
      ]);
      final search = find.descendant(
        of: find.byType(UtenSearchBar),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, '1001 现金');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(table().items, hasLength(1));
      expect(export().queryParams, containsPair('keyword', '1001 现金'));
      table().onFilterChanged('classification', '待维护');
      await tester.pumpAndSettle();
      expect(export().queryParams, containsPair('f.classification', '待维护'));
      table().onSortChange!('code', false);
      await tester.pumpAndSettle();
      expect(export().queryParams, containsPair('sort', 'code'));
      expect(export().queryParams, containsPair('order', 'desc'));
      final template = table().toolbarActions!
          .whereType<UtenExportButton>()
          .singleWhere((button) => button.report == 'gl/chart-template');
      expect(template.showOutputScope, isFalse);
      expect(template.frozenProjection!.columns, hasLength(9));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'source reason preserves base currency and loss category can be selected by mouse',
    (tester) async {
      final api = _ChartApi();
      await _pump(tester, api, width: 1280, height: 720);
      await _tapTableAction(tester, '新增科目');
      Finder field(String label) => find.descendant(
        of: find.byWidgetPredicate((w) => w is UtenInput && w.label == label),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(field('科目编码'), '560301');
      await tester.enterText(field('科目名称'), '利息收入');
      await tester.enterText(field('新增依据'), '损益科目允许无余额；本期发生额保留用于利润计算。');
      await tester.pumpAndSettle();
      final currency = find.byWidgetPredicate(
        (w) => w is UtenDropdownField && w.label == '核算币别',
      );
      expect(tester.widget<UtenDropdownField>(currency).value, 'currency-cny');
      final classification = find.byWidgetPredicate(
        (w) => w is UtenDropdownField && w.label == '财务类别',
      );
      await tester.ensureVisible(classification);
      await tester.tap(classification);
      await tester.pumpAndSettle();
      await tester.tap(find.text('损益').last);
      await tester.pumpAndSettle();
      expect(tester.widget<UtenDropdownField>(classification).value, 'PROFIT');
      final category = find.byWidgetPredicate(
        (w) => w is UtenDropdownField && w.label == '同时补建核算类别',
      );
      await tester.ensureVisible(category);
      await tester.tap(category);
      await tester.pumpAndSettle();
      await tester.tap(find.text('收入').last);
      await tester.pumpAndSettle();
      expect(tester.widget<UtenDropdownField>(category).value, 'INCOME');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'lost apply reply retries only the original batch and closes no unknown work',
    (tester) async {
      final api = _ChartApi()..loseFirstApply = true;
      await _pump(tester, api);
      await _tapTableAction(tester, '导入科目目录');
      expect(find.textContaining('1条科目，0项错误'), findsOneWidget);
      await tester.tap(find.text('确认导入科目目录'));
      await tester.pumpAndSettle();
      expect(api.applies, ['batch-1']);
      expect(
        tester
            .widget<UtenCloseButton>(find.byType(UtenCloseButton).last)
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('核对并重试原批次'));
      await tester.pumpAndSettle();
      expect(api.applies, ['batch-1', 'batch-1']);
      expect(api.actualImports, 1);
      expect(api.uploads, 1);
      expect(find.text('1001'), findsOneWidget);
      expect(find.text('库存现金'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'definite validation rejection keeps the preview editable and does not trap the user',
    (tester) async {
      final api = _ChartApi()..rejectApply = true;
      await _pump(tester, api);
      await _tapTableAction(tester, '导入科目目录');
      await tester.tap(find.text('确认导入科目目录'));
      await tester.pumpAndSettle();
      expect(find.text('核对并重试原批次'), findsNothing);
      expect(
        tester
            .widget<UtenCloseButton>(find.byType(UtenCloseButton).last)
            .onPressed,
        isNotNull,
      );
      expect(find.textContaining('库存现金'), findsOneWidget);
      expect(api.actualImports, 0);
    },
  );

  testWidgets(
    'narrow enlarged text keeps financial directory controls and data reachable',
    (tester) async {
      final api = _ChartApi()..actualImports = 1;
      await _pump(tester, api, width: 390, scale: 1.5);
      expect(find.textContaining('库存现金'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _tapTableAction(WidgetTester tester, String label) async {
  if (find.text(label).evaluate().isEmpty) {
    await tester.tap(find.byTooltip('表格操作'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _ChartApi api, {
  double width = 1400,
  double height = 900,
  double scale = 1,
  TableColumnProjectionController? projections,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(
            userId: 'chart-test-user',
            businessDatasetId: 'chart-test-dataset',
          ),
        ),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.paymentStyleEdit,
          Perm.paymentStyleCreate,
          Perm.financeReportExport,
        }),
        financeEntryFilePickerProvider.overrideWithValue(
          () async => PlatformFile(
            name: 'chart.xls',
            size: 3,
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
        ),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: projections == null
              ? child!
              : TableColumnProjectionScope(
                  controller: projections,
                  child: child!,
                ),
        ),
        home: const FinanceChartDialog(canEdit: true),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ChartApi extends ApiClient {
  _ChartApi() : super(Dio());
  bool loseFirstApply = false, rejectApply = false;
  int uploads = 0, actualImports = 0;
  final applies = <String>[];
  final preview = <String, dynamic>{
    'importId': 'batch-1',
    'sourceName': 'chart.xls',
    'applied': false,
    'rows': [
      {'code': '1001', 'name': '库存现金', 'currencyName': ''},
    ],
    'issues': <Object>[],
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/chart/imports') return {'items': <Object>[]};
    if (path == '/finance/chart/options') {
      return {
        'currencies': [
          {
            'id': 'currency-cny',
            'name': '人民币',
            'code': 'CNY',
            'baseCurrency': true,
          },
        ],
      };
    }
    if (path.startsWith('/finance/chart/imports/')) {
      return {...preview, 'applied': actualImports > 0};
    }
    if (path == '/finance/chart') {
      return {
        'items': [
          if (actualImports > 0)
            {
              'code': '1001',
              'name': '库存现金',
              'version': 0,
              'targets': <Object>[],
              'lineKeys': <Object>[],
            },
        ],
      };
    }
    return {};
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
    return preview;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/chart/import-apply') {
      applies.add((body as Map)['importId'].toString());
      if (rejectApply) {
        throw ApiException(
          'VALIDATION_FAILED',
          '科目目录已变化，请重新预览',
          httpStatus: 422,
          hasResponseCode: true,
        );
      }
      actualImports = 1;
      if (loseFirstApply && applies.length == 1) {
        throw NetworkTimeoutException();
      }
      return {'status': 'APPLIED', 'imported': 1};
    }
    return {};
  }
}
