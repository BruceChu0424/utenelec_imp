import '../../support/native_detail_reader_overrides.dart';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/finance/models/finance_doc.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_detail_page.dart';
import 'package:uten_imp/features/finance/pages/finance_doc_edit_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_grid_columns.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/features/finance/config/finance_doc_config.dart';
import 'package:uten_imp/platform_table_registry.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../support/document_scope_capability_overrides.dart';
import '../../support/memory_cas_storage.dart';
import '../../support/audit_screenshot_support.dart';

const _oldDepartment = 'aaaaaaaa-0000-0000-0000-000000000001';
const _newDepartment = 'aaaaaaaa-0000-0000-0000-000000000002';

class _FinanceApi extends ApiClient {
  _FinanceApi() : super(Dio());
  final reads = <String>[];
  final saved = <Map<String, dynamic>>[];
  Object? departmentFailure;
  bool historicalName = true;
  List<Map<String, dynamic>> get departments => [
    {
      'id': _oldDepartment,
      'code': 'DEP_OLD',
      'name': '生产一部',
      'level': '一级部门',
      'children': <Object>[],
    },
    {
      'id': _newDepartment,
      'code': 'DEP_NEW',
      'name': '生产二部',
      'level': '一级部门',
      'children': <Object>[],
    },
  ];
  Map<String, dynamic> get detail => {
    'id': 'expense-1',
    'billNo': 'FY20260930000001',
    'billDate': '2026-09-30',
    'version': 0,
    'status': 0,
    'makerId': 'maker-1',
    'accountId': 'account-1',
    'currencyId': 'currency-1',
    'exchangeRateExact': '1',
    'amountOriginalExact': '12.3456789',
    'items': [
      {
        'id': 'line-1',
        'expenseStyleId': 'style-1',
        'incomeStyleId': 'style-1',
        'departmentId': _oldDepartment,
        if (historicalName) 'departmentName': '生产一部',
        'amountOriginalExact': '12.3456789',
        'amountLocalExact': '12.3456789',
        'qtyExact': '2',
        'priceExact': '6.17283945',
        'remark': '部门分摊保留精确金额',
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    if (path == '/auth/me') {
      return {
        'session': {
          'delegableSurfaceKeys': <String>[],
          'documentScopes': <String, Object>{},
          'preferences': <String, Object>{},
        },
      };
    }
    if (path == '/workbench/badges') {
      return {
        'entries': <String, Object>{},
        'modules': <String, Object>{},
        'totals': <String, Object>{},
      };
    }
    if (path.contains('/scope')) {
      return {
        'scope': 'finance',
        'writeAll': true,
        'writableOwnerIds': <String>[],
      };
    }
    if (path.contains('platform')) {
      return {'columns': <Object>[], 'rows': <Object>[]};
    }
    return detail;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    if (path.contains('/departments/')) {
      if (departmentFailure case final failure?) throw failure;
      return departments;
    }
    if (path == '/master/clients/dict') {
      return [
        {'id': _oldDepartment, 'name': '同 UUID 的客户陷阱'},
      ];
    }
    if (path == '/master/accounts/dict') {
      return [
        {
          'id': 'account-1',
          'name': '现金账户',
          'currencyId': 'currency-1',
          'currencyCode': 'CNY',
          'currencyName': '人民币',
          'baseCurrency': true,
          'status': '使用',
        },
      ];
    }
    if (path == '/master/currencies/dict') {
      return [
        {
          'id': 'currency-1',
          'name': '人民币',
          'code': 'CNY',
          'baseCurrency': true,
          'exchangeRate': 1,
        },
      ];
    }
    if (path == '/master/payment-styles/tree') {
      return [
        {
          'id': 'style-1',
          'code': 'STYLE1',
          'name': '分摊项目',
          'category': query?['category'] ?? 'EXPENSE',
          'status': '使用',
          'children': <Object>[],
        },
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    saved.add(Map<String, dynamic>.from(body! as Map));
    return detail;
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    saved.add(Map<String, dynamic>.from(body! as Map));
    return detail;
  }
}

Future<_FinanceApi> _pumpFinance(
  WidgetTester tester, {
  bool edit = false,
  FinanceDocType type = FinanceDocType.expense,
  _FinanceApi? api,
  bool fresh = false,
  String? draftId,
  MemoryCasStorage? storage,
  Size size = const Size(1440, 1100),
  GlobalKey? captureKey,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final server = api ?? _FinanceApi();
  final initial = fresh
      ? '/finance/${type.pathSegment}/new${draftId == null ? '' : '?draftId=$draftId'}'
      : '/';
  Widget page() => edit
      ? FinanceDocEditPage(docType: type, id: fresh ? null : 'expense-1')
      : FinanceDocDetailPage(docType: type, id: 'expense-1');
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/', builder: (_, _) => page()),
      GoRoute(path: '/finance/:type/new', builder: (_, _) => page()),
      GoRoute(
        path: '/finance/:type/:id',
        builder: (_, _) => const Scaffold(body: Text('已保存财务单据')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        ...nativeDetailReaderOverrides(includeServer: false),
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(server),
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(preferences, web: true),
        ),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'finance-user'),
        ),
        apiBaseUrlProvider.overrideWithValue('https://finance.example/api'),
        formDraftStorageProvider.overrideWithValue(
          storage ?? MemoryCasStorage(),
        ),
        financeWriteAllDocumentScope(),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.financeExpenseView,
          Perm.financeExpenseCreate,
          Perm.financeExpenseEdit,
          Perm.financeOtherIncomeView,
          Perm.financeOtherIncomeCreate,
          Perm.financeOtherIncomeEdit,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: captureKey == null
            ? buildLightTheme()
            : auditScreenshotTheme(buildLightTheme()),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (context, child) => captureKey == null
            ? child!
            : RepaintBoundary(
                key: captureKey,
                child: MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.5)),
                  child: child!,
                ),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return server;
}

void main() {
  for (final type in [FinanceDocType.expense, FinanceDocType.otherIncome]) {
    testWidgets(
      'current department name comes from document reference, never same-UUID client: $type',
      (tester) async {
        final api = await _pumpFinance(tester, type: type);
        final table = tester.widget<MasterDataTableView<FinanceDocItem>>(
          find.byType(MasterDataTableView<FinanceDocItem>),
        );
        final department = table.columns.singleWhere(
          (column) => column.label == '部门',
        );
        expect(department.value(table.items.single), '生产一部');
        expect(department.key, 'department');
        expect(api.reads, isNot(contains('/master/clients/dict')));
        expect(api.reads.where((p) => p.contains('/departments/')), isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
  testWidgets(
    'allocation department is selected with shared picker and remains a UUID',
    (tester) async {
      await _pumpFinance(tester, edit: true);
      final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
        find.byType(UtenEditableGrid<FinanceGridRow>),
      );
      expect(
        grid.columns.singleWhere((column) => column.key == 'department').label,
        '部门',
      );
      final picker = find.byType(UtenDepartmentPicker);
      expect(picker, findsOneWidget);
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('生产二部').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定').last);
      await tester.pumpAndSettle();
      expect(grid.controller.rows.single.department.text, _newDepartment);
      expect(grid.controller.rows.single.amount.text, '12.3456789');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final type in [FinanceDocType.expense, FinanceDocType.otherIncome]) {
    testWidgets(
      'selected department survives actual local persistence and reopening before official payload: $type',
      (tester) async {
        await _pumpFinance(tester, edit: true, type: type);
        var grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
          find.byType(UtenEditableGrid<FinanceGridRow>),
        );
        await tester.tap(find.byType(UtenDepartmentPicker));
        await tester.pumpAndSettle();
        await tester.tap(find.text('生产二部').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('确定').last);
        await tester.pumpAndSettle();
        final state =
            tester.state(find.byType(FinanceDocEditPage))
                as FormDraftMixin<FinanceDocEditPage>;
        final snapshot =
            jsonDecode(jsonEncode(state.captureFormDraft()))
                as Map<String, dynamic>;
        final restoredRow =
            (snapshot['rows'] as List).single as Map<String, dynamic>;
        expect(restoredRow['department'], _newDepartment);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        final storage = MemoryCasStorage();
        await _pumpFinance(
          tester,
          edit: true,
          fresh: true,
          storage: storage,
          type: type,
        );
        final newState =
            tester.state(find.byType(FinanceDocEditPage))
                as FormDraftMixin<FinanceDocEditPage>;
        await newState.restoreFormDraft(snapshot);
        await tester.pumpAndSettle();
        await newState.saveFormDraftNow();
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(FinanceDocEditPage)),
        );
        final savedDraft = container.read(formDraftsProvider).single;
        expect(storage.records, isNotEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        final api = await _pumpFinance(
          tester,
          edit: true,
          type: type,
          fresh: true,
          storage: storage,
          draftId: savedDraft.id,
        );
        grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
          find.byType(UtenEditableGrid<FinanceGridRow>),
        );
        expect(grid.controller.rows.single.department.text, _newDepartment);
        expect(grid.controller.rows.single.departmentReferenceName, '生产二部');
        expect(grid.controller.rows.single.amount.text, '12.3456789');
        await tester.tap(find.text('保存').hitTestable());
        await tester.pumpAndSettle();
        expect(api.saved, hasLength(1));
        final item =
            (api.saved.single['items'] as List).single as Map<String, dynamic>;
        expect(item['departmentId'], _newDepartment);
        expect(item.containsKey('departmentName'), false);
        expect(item['amountOriginal'], '12.3456789');
        expect(item['qty'], '2');
        expect(item['price'], '6.17283945');
        expect(find.text('已保存财务单据'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  for (final status in [403, 500]) {
    testWidgets(
      'department read $status preserves original reference and retry cannot clear it',
      (tester) async {
        final api = await _pumpFinance(
          tester,
          edit: true,
          api: _FinanceApi()
            ..departmentFailure = ApiException(
              'DENIED',
              '读取失败',
              httpStatus: status,
            ),
        );
        final grid = tester.widget<UtenEditableGrid<FinanceGridRow>>(
          find.byType(UtenEditableGrid<FinanceGridRow>),
        );
        expect(grid.controller.rows.single.department.text, _oldDepartment);
        expect(grid.controller.rows.single.departmentReferenceName, '生产一部');
        expect(
          tester
              .widget<UtenDepartmentPicker>(find.byType(UtenDepartmentPicker))
              .enabled,
          false,
        );
        api.departmentFailure = null;
        await tester.tap(find.byTooltip(RegExp('点击重试')));
        await tester.pumpAndSettle();
        expect(grid.controller.rows.single.department.text, _oldDepartment);
        expect(
          tester
              .widget<UtenDepartmentPicker>(find.byType(UtenDepartmentPicker))
              .enabled,
          true,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets(
    'old server or orphan reference displays original UUID, never a client fallback',
    (tester) async {
      final api = await _pumpFinance(
        tester,
        api: _FinanceApi()..historicalName = false,
      );
      final table = tester.widget<MasterDataTableView<FinanceDocItem>>(
        find.byType(MasterDataTableView<FinanceDocItem>),
      );
      expect(
        table.columns
            .singleWhere((c) => c.key == 'department')
            .value(table.items.single),
        _oldDepartment,
      );
      expect(api.reads, isNot(contains('/master/clients/dict')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final type in ['expense', 'otherIncome']) {
    test(
      'old dept layout retains order visibility width and pin for $type only',
      () {
        final row = FinanceGridRow(mode: ItemMode.allocate);
        addTearDown(row.dispose);
        final binding = resolvePlatformTable(
          PlatformTableDescriptor<FinanceGridRow>(
            kind: 'editable',
            tableKey: 'finance.$type.items',
            columnKeys: const ['department', 'amount'],
            rows: [row],
          ),
        )!;
        final controller = PlatformTableController<FinanceGridRow>()
          ..binding = binding
          ..layout = const PlatformTableLayout(
            order: ['dept', 'amount'],
            hidden: {'dept'},
            pinned: {'dept'},
            widths: {'dept': 245},
          );
        addTearDown(controller.dispose);
        final result = controller.localLayout([
          'amount',
          'department',
        ], defaultHidden: {});
        expect(result.order, ['department', 'amount']);
        expect(result.hidden, {'department'});
        expect(result.pinned, {'department'});
        expect(result.widths, {'department': 245});
        final detailBinding = resolvePlatformTable(
          PlatformTableDescriptor<FinanceDocItem>(
            kind: 'master',
            tableKey: 'finance.$type.items',
            columnKeys: const ['department', 'amount'],
            rows: const [FinanceDocItem()],
          ),
        )!;
        expect(detailBinding.columnAliases['dept'], 'department');
      },
    );
  }
  test(
    'allocation department alias does not alter bank transfer or receipt schemas',
    () {
      for (final type in ['bankTransfer', 'receipt']) {
        final binding = resolvePlatformTable(
          PlatformTableDescriptor<FinanceDocItem>(
            kind: 'master',
            tableKey: 'finance.$type.items',
            columnKeys: const ['dept'],
            rows: const [FinanceDocItem()],
          ),
        )!;
        expect(binding.columnAliases.containsKey('dept'), false);
      }
    },
  );

  if (Platform.environment['UTEN_CAPTURE_FINANCE_DEPARTMENT'] == 'true') {
    testWidgets('department picker narrow-screen visual', (tester) async {
      await loadAuditScreenshotFonts(tester);
      final capture = GlobalKey();
      await _pumpFinance(
        tester,
        edit: true,
        size: const Size(390, 844),
        captureKey: capture,
      );
      await Scrollable.ensureVisible(
        tester.element(find.byType(UtenDepartmentPicker)),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(UtenDepartmentPicker));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await saveAuditScreenshot(
        tester,
        capture,
        'finance-department-picker-390',
      );
      await tester.tap(find.text('生产二部').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await saveAuditScreenshot(
        tester,
        capture,
        'finance-department-selected-390',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
