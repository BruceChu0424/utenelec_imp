import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/complete_read_plan_batches.dart';
import '../../../support/pump_until.dart';
import '../../../support/uten_test_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/features/basic_data/pages/account_workspace_page.dart';
import 'package:uten_imp/features/basic_data/pages/client_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/color_page.dart';
import 'package:uten_imp/features/basic_data/pages/currency_page.dart';
import 'package:uten_imp/features/basic_data/pages/mould_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/product_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/supplier_category_page.dart';
import 'package:uten_imp/features/basic_data/pages/unit_page.dart';
import 'package:uten_imp/features/basic_data/pages/warehouse_page.dart';
import 'package:uten_imp/features/basic_data/pages/settlement_method_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';

import '../../../shared/drafts/memory_form_draft_storage.dart';

const _domains = [
  'goods',
  'clients',
  'suppliers',
  'accounts',
  'currencies',
  'colors',
  'units',
  'moulds',
  'warehouses',
  'settlement_methods',
];
const _permissions = {
  'goods:view',
  'client:view',
  'supplier:view',
  'account:view',
  'currency:view',
  'color:view',
  'unit:view',
  'mould:view',
  'warehouse:view',
  'stock:view',
  'settlement_method:view',
  'mould:export',
};

class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'synthetic-print',
      code: 'SYNTHETIC',
      name: '合成查看员',
      permissions: _permissions.toList(),
    ),
  );
}

class _Fixture {
  _Fixture(this.domain, {this.total = 601}) {
    final dio = Dio(BaseOptions(baseUrl: 'https://synthetic.invalid/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          final path = request.path;
          if (path == '/report-export-jobs/capabilities') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {'available': true, 'selectionVersion': 1},
              ),
            );
            return;
          }
          if (path == '/report-export-jobs' && request.method == 'POST') {
            exports.add(Map<String, dynamic>.from(request.data as Map));
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: request,
                  statusCode: 409,
                  data: {'code': 'FIXTURE_CAPTURE', 'message': '已记录导出请求'},
                ),
              ),
            );
            return;
          }
          Object value = <String, dynamic>{};
          final root = domain == 'settlement_methods'
              ? '/master/reference-methods/settlement-admin'
              : '/master/$domain';
          if (path == root || path == '$root/search' || path == '$root/page') {
            final page =
                (request.queryParameters['page'] as num?)?.toInt() ?? 1;
            // The server's own page maximum (Pageables.MAX_PAGE_SIZE) is the
            // shared complete-read plan's bounded batch.
            final size =
                ((request.queryParameters['size'] as num?)?.toInt() ?? 20)
                    .clamp(1, CompleteReadBatchPlan.progressive.maxBatchSize);
            calls.add((page: page, size: size));
            // Late pages: every continuation batch waits for the test.
            if (page > 1) {
              await holdSecond?.future;
              if (failContinuation) {
                handler.reject(
                  DioException(
                    requestOptions: request,
                    type: DioExceptionType.connectionTimeout,
                  ),
                );
                return;
              }
            }
            value = {
              'items': rows.skip((page - 1) * size).take(size).toList(),
              'page': page,
              'size': size,
              'total': rows.length,
              'totalPages': (rows.length / size).ceil(),
            };
          } else if (path == '$root/dict') {
            value = rows;
          } else if (path.endsWith('/tree') || path.endsWith('/subtree')) {
            value = path.contains('categories') ? [category] : <Object>[];
          } else if (path.contains('categories') && !path.endsWith('/facets')) {
            value = category;
          } else if (path.endsWith('/facets')) {
            value = {
              'fields': <String, Object>{},
              'nullCounts': <String, int>{},
            };
          } else if (path.endsWith('/dict') ||
              path.endsWith('/lookup') ||
              path.endsWith('/scopes') ||
              path.endsWith('/assignments') ||
              path.contains('/reference-methods/') ||
              path.endsWith('/workshops')) {
            value = <Object>[];
          } else if (path.contains('/stock/')) {
            value = {
              'items': <Object>[],
              'page': 1,
              'size': 100,
              'total': 0,
              'totalPages': 0,
            };
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: value,
            ),
          );
        },
      ),
    );
    api = _FixtureApi(dio, this);
  }
  final String domain;
  final int total;
  final exports = <Map<String, dynamic>>[];
  final projection = TableColumnProjectionController();
  late final ApiClient api;
  final calls = <({int page, int size})>[];
  Completer<void>? holdSecond;
  bool failContinuation = false;
  static const category = {
    'id': '20000000-0000-4000-8000-000000000001',
    'code': 'CAT',
    'name': '合成类别',
    'level': 0,
    'path': '/CAT/',
    'children': <Object>[],
    'childCount': 0,
  };
  late final rows = List.generate(
    total,
    (index) => <String, dynamic>{
      'id': '10000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
      'code': domain == 'warehouses' && index == 0 ? '001' : 'CODE$index',
      'name': '合成原名龘$index',
      'status': '使用',
      'categoryId': category['id'],
      'version': 1,
      'writable': false,
      'exchangeRate': 1,
      'baseCurrency': index == 0,
      'parentId': index == 0 ? null : '10000000-0000-4000-8000-000000000000',
      'accountable': true,
      'lineSide': false,
      'defective': false,
      'selectableForNew': true,
      'accountType': 'BANK',
      'currencyName': '人民币',
      'fullName': '合成原名龘$index',
    },
  );
}

class _FixtureApi extends ApiClient {
  _FixtureApi(super.dio, this.fixture);
  final _Fixture fixture;
  @override
  Future<T> postSummaryStream<T>(
    String path, {
    required Object body,
    required Future<T> Function(Stream<Map<String, dynamic>>) consume,
  }) => consume(_frames());

  Stream<Map<String, dynamic>> _frames() async* {
    var offset = 0;
    while (offset < fixture.rows.length) {
      if (offset > 0) {
        if (fixture.failContinuation)
          throw TimeoutException('continuation failed');
      }
      final size = CompleteReadBatchPlan.progressive.sizeAt(offset);
      yield {
        'type': 'page',
        'value': {
          'items': fixture.rows.skip(offset).take(size).toList(),
          'page': offset ~/ size + 1,
          'size': size,
          'total': fixture.rows.length,
          'totalPages': (fixture.rows.length / size).ceil(),
          'readScopeVersion': 'a' * 64,
          'readSnapshotRevision': 'b' * 64,
          'readDataVersion': 'c' * 64,
        },
      };
      offset += size;
    }
    yield {
      'type': 'complete',
      'total': fixture.rows.length,
      'readScopeVersion': 'a' * 64,
      'readSnapshotRevision': 'b' * 64,
      'readDataVersion': 'c' * 64,
    };
  }
}

Widget _page(String domain) => switch (domain) {
  'goods' => const ProductCategoryPage(),
  'clients' => const ClientCategoryPage(),
  'suppliers' => const SupplierCategoryPage(),
  'accounts' => const AccountPage(),
  'currencies' => const CurrencyPage(),
  'colors' => const ColorPage(),
  'units' => const UnitPage(),
  'moulds' => const MouldCategoryPage(),
  'warehouses' => const WarehousePage(),
  'settlement_methods' => const SettlementMethodPage(),
  _ => throw StateError(domain),
};

Future<ProviderContainer> _pump(WidgetTester tester, _Fixture fixture) async {
  await setUtenTestSurfaceSize(tester, const Size(1600, 1000));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'synthetic-print'),
        ),
        currentPermissionsProvider.overrideWithValue(_permissions),
        isSuperAdminProvider.overrideWithValue(false),
        apiClientProvider.overrideWithValue(fixture.api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TableColumnProjectionScope(
          controller: fixture.projection,
          child: _page(fixture.domain),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(_page(fixture.domain).runtimeType)),
  );
}

void main() {
  testWidgets(
    'cold progressive failure cannot open print or create an export',
    (tester) async {
      final fixture = _Fixture('moulds')..failContinuation = true;
      await _pump(tester, fixture);
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton).first,
      );
      final print = tester.widget<UtenPrintPreviewButton>(
        find.byType(UtenPrintPreviewButton).first,
      );
      expect(export.enabled, isFalse);
      expect(print.enabled, isFalse);
      expect(fixture.exports, isEmpty);
      expect(find.text('MX-moulds-00000'), findsNothing);
    },
  );
  testWidgets(
    'accepted complete result stays usable after a same-query failed refresh',
    (tester) async {
      final fixture = _Fixture('moulds');
      await _pump(tester, fixture);
      expect(
        tester
            .widget<UtenExportButton>(find.byType(UtenExportButton).first)
            .enabled,
        isTrue,
      );
      fixture.failContinuation = true;
      final controller =
          tester.state(
                find
                    .byWidgetPredicate((w) => w is MasterEntityDetailPane)
                    .first,
              )
              as MasterEntityPaneController;
      final refresh = controller.reload();
      await tester.pumpAndSettle();
      await refresh;
      expect(
        tester
            .widget<UtenExportButton>(find.byType(UtenExportButton).first)
            .enabled,
        isTrue,
      );
      expect(
        tester
            .widget<UtenPrintPreviewButton>(
              find.byType(UtenPrintPreviewButton).first,
            )
            .enabled,
        isTrue,
      );
      expect(controller.page!.items, hasLength(fixture.total));
    },
  );
  for (final selected in [false, true]) {
    testWidgets(
      'mould actual export sends all 1626 identities with selected=$selected',
      (tester) async {
        final fixture = _Fixture('moulds', total: 1626);
        await _pump(tester, fixture);
        if (selected) {
          // The first checkbox is the real header selection control. It selects
          // the complete loaded scope, including rows outside the viewport.
          await tester.tap(
            find
                .descendant(
                  of: find.byWidgetPredicate(
                    (widget) => widget is MasterDataTableView,
                  ),
                  matching: find.byType(Checkbox),
                )
                .first,
          );
          await tester.pumpAndSettle();
          expect(
            fixture.projection.resolve()!.outputSelection.ids,
            hasLength(1626),
          );
        }
        await tester.tap(find.text('导出模具'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            ValueKey(selected ? 'table-output-selected' : 'table-output-all'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('直接下载'));
        await tester.pumpAndSettle();
        final request = fixture.exports.single;
        expect(request['report'], 'mould');
        final parameters = request['parameters'] as Map;
        expect(parameters, isNot(contains('page')));
        expect(parameters, isNot(contains('size')));
        if (selected) {
          expect(
            (jsonDecode(parameters['selectedIds'] as String) as List).toSet(),
            fixture.rows.map((row) => row['id']).toSet(),
          );
        } else {
          expect(parameters, isNot(contains('selectedIds')));
        }
        final columns =
            ((request['columnProjection'] as Map)['columns'] as List)
                .map((column) => (column as Map)['key'])
                .toList();
        expect(columns, isNot(contains('mouldType')));
        expect(columns, containsAll(['code', 'name', 'manufacturer']));
        expect(tester.takeException(), isNull);
      },
    );
  }
  // Actual page consumers must only publish columns their owning export
  // service can resolve. Keep this check at the page boundary: a common button
  // test alone cannot detect an incorrectly declared placeholder column.
  const exportColumns = {
    'goods':
        'goodsId bomRef code name categoryPath clientGoodsName nameEn colorName series owningWarehouseName owningWorkshopName model cNumber spec paper mouldCode mouldName rearInsertCode unitName material sourceType price currencyId discount stockQty minOrderQty orderMultipleQty goods color unit colorLegacyId unitLegacyId owningWarehouse owningWorkshop source',
    'clients':
        'code name fullName nameEn defaultSettlementMethodName clientXz tday region placeId ownerEmployeeName legalPerson linkman mobile phone phone2 fax postcode address bank bankAccount taxId credit creditFloor website goods',
    'suppliers':
        'name description priceStyle tday lossRate place ownerEmployeeName legalPerson linkman mobile phone phone2 fax postcode address bank bankAccount taxId website shipVia shipAddress goods',
    'accounts':
        'code name accountType currencyName bankAccountNo balanceCurrent status goods currencyId',
    'currencies': 'code name exchangeRate status goods',
    'colors': 'code name status remark goods',
    'units': 'code name status goods',
    'moulds':
        'code name qty tqty categoryName place mstatus manufacturer remark status goods',
    'warehouses':
        'code name parentName defective location remark workshopDepartmentName workshopDepartmentId accountable keepers status goods parent',
    'settlement_methods':
        'code name status systemRole termsBase dueRule defaultDueDays fixedDayOfMonth monthsAhead terms goods',
  };
  for (final domain in _domains) {
    testWidgets(
      '$domain actual export header has no unsupported display columns',
      (tester) async {
        final fixture = _Fixture(domain);
        await _pump(tester, fixture);
        if (domain == 'warehouses') {
          await tester.tap(find.text('表格视图'));
          await tester.pumpAndSettle();
        }
        final projection = fixture.projection.resolve();
        expect(projection, isNotNull);
        final keys = projection!.columns
            .where((column) => column.exportable)
            .map((column) => column.key)
            .toSet();
        final allowed = exportColumns[domain]!.split(' ').toSet();
        expect(
          keys.difference(allowed),
          isEmpty,
          reason:
              '$domain published a column absent from its server export schema',
        );
        expect(keys, contains('name'));
        if (domain == 'moulds') {
          expect(
            projection.columns.map((column) => column.key),
            contains('mouldType'),
          );
          expect(keys, isNot(contains('mouldType')));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final domain in _domains) {
    testWidgets(
      '$domain actual page prints every authorized server page beyond 500',
      (tester) async {
        final fixture = _Fixture(domain);
        await _pump(tester, fixture);
        fixture.calls.clear();
        expect(find.text('预览打印'), findsWidgets);
        await tester.tap(find.text('预览打印').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('table-output-all')));
        await tester.pumpAndSettle();
        expect(find.textContaining('共 601 行'), findsWidgets);
        // Every server page of the shared plan beyond the old 500 cap: the
        // first 50 rows, then aligned batches up to the server maximum.
        expect(fixture.calls, completeReadPlanBatches(601));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a scope revision during a real shared pane print never publishes its late pages',
    (tester) async {
      final fixture = _Fixture('goods')..holdSecond = Completer<void>();
      final container = await _pump(tester, fixture);
      await tester.tap(find.text('预览打印').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-output-all')));
      // The print is in flight: its first continuation page is held.
      await pumpUntil(
        tester,
        () => fixture.calls.length == 2,
        reason: 'the print should request its first continuation page',
      );
      expect(fixture.calls, completeReadPlanBatches(601).take(2));
      container.read(readScopeRevisionProvider.notifier).state++;
      await tester.pump();
      fixture.holdSecond!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('共 601 行'), findsNothing);
      expect(find.text('账号、服务器或权限已变化，请关闭后重新预览'), findsOneWidget);
      // The retired read stops at the late page instead of reading on.
      expect(fixture.calls, completeReadPlanBatches(601).take(2));
    },
  );
}
