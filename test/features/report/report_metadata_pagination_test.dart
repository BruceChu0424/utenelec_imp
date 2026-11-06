import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/pages/finance_account_flow_page.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_overview_page.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/features/finance/pages/finance_statement_page.dart';
import 'package:uten_imp/features/production/config/production_report_config.dart';
import 'package:uten_imp/features/production/pages/production_report_page.dart';
import 'package:uten_imp/features/purchase/config/purchase_report_config.dart';
import 'package:uten_imp/features/purchase/pages/purchase_report_table_page.dart';
import 'package:uten_imp/features/report/shared/report_filter_prefs.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_report_config.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_report_table_page.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_report_config.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_report_table_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';
import '../../support/uten_test_actions.dart';
import '../../support/native_facet_fake_transport.dart';

class _Permissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};
  void replace(Set<String> value) => state = value;
}

final _permissions = NotifierProvider<_Permissions, Set<String>>(
  _Permissions.new,
);

class _StatementPrefs extends FinanceStatementReportPrefsNotifier {
  @override
  ReportFilterPrefs build() =>
      const ReportFilterPrefs(extra: {'partyId': 'party-1'});
}

const _fixturePhone = '12345678';

class _ReportHttpBoundary extends ApiClient {
  _ReportHttpBoundary(super.dio);

  Future<Map<String, dynamic>> nativeFormOverHttp(
    String path, {
    required Map<String, dynamic> body,
  }) => super.postForm(path, body: body);
}

class _CandidateHttpTransport implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 404;

  ResponseBody response(int status) {
    final body = requests.last.data as Map;
    return ResponseBody.fromString(
      jsonEncode(
        status == 404
            ? {'code': 'NOT_FOUND', 'message': '匿名候选接口不存在'}
            : {
                'field': body['__facetField'],
                'page': body['__facetPage'],
                'size': body['__facetSize'],
                'items': [
                  {
                    'value': _fixturePhone,
                    'label': _fixturePhone,
                    'count': 101,
                  },
                ],
                'hasMore': false,
                'readScopeVersion': 'fixture-v1',
              },
      ),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path != '/finance/reports/column-candidates') {
      throw StateError('Unexpected native candidate HTTP fixture path');
    }
    requests.add(options);
    return response(status);
  }

  @override
  void close({bool force = false}) {}
}

class _CandidateWidgetTransport {
  final requests = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? gate;

  Map<String, dynamic> response() => {
    'field': requests.last['__facetField'],
    'page': requests.last['__facetPage'],
    'size': requests.last['__facetSize'],
    'items': [
      {'value': _fixturePhone, 'label': _fixturePhone, 'count': 101},
    ],
    'hasMore': false,
    'readScopeVersion': 'fixture-v1',
  };

  static ApiException missing() =>
      ApiException('NOT_FOUND', '匿名候选接口不存在', httpStatus: 404);

  Future<Map<String, dynamic>> fetch(
    String path,
    Map<String, dynamic> body,
  ) async {
    expect(path, '/finance/reports/column-candidates');
    requests.add(Map.unmodifiable(body));
    return gate?.future ?? (throw missing());
  }
}

class _ReportApi extends ApiClient with NativeFacetFakeTransport {
  _ReportApi({Dio? dio}) : super(dio ?? Dio());
  final queries = <Map<String, dynamic>>[];
  final candidateFormReads = <({String path, Map<String, dynamic> body})>[];
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
  candidateTransport;
  Object? candidateError;
  int pages = 2;
  bool previewClamp = false;
  int? largePreviewRows;
  bool headerFacts = false;
  int headerRows = 1;
  bool failHeaders = false;
  final postBodies = <Object?>[];

  @override
  Future<Map<String, dynamic>> postForm(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    candidateFormReads.add((path: path, body: Map.unmodifiable(body)));
    candidateError = null;
    try {
      return await (candidateTransport?.call(path, body) ??
          super.postForm(path, body: body));
    } catch (error) {
      candidateError = error;
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/finance/reports/column-candidates') {
      if (!headerFacts ||
          query?['report'] != 'ar-ap/overview' ||
          query?['column'] != 'phone') {
        throw StateError('Unexpected report column candidate fixture scope');
      }
      return {
        'value': [
          {'value': _fixturePhone, 'label': _fixturePhone, 'count': headerRows},
        ],
      };
    }
    if (!path.contains('/reports/')) return {};
    final parameters = Map<String, dynamic>.of(query ?? {});
    queries.add(parameters);
    if (failHeaders &&
        parameters.keys.any((key) => key.startsWith('f.search.'))) {
      throw StateError('fixture header read failed');
    }
    if (headerFacts) {
      final statement = path.contains('/statement/');
      final page = parameters['page'] as int? ?? 1;
      final size = parameters['size'] as int? ?? 50;
      return {
        'readScopeVersion': 'fixture-v1',
        'columns': statement
            ? [
                {'key': 'billDate', 'label': '开单日期', 'type': 'date'},
                {'key': 'currencyCode', 'label': '币别', 'type': 'text'},
                {'key': 'refNo', 'label': '关联单号', 'type': 'text'},
                {
                  'key': 'receiptOriginal',
                  'label': '冲减应收金额(外)',
                  'type': 'money',
                },
                {'key': 'balanceLocal', 'label': '应收余额(本)', 'type': 'money'},
              ]
            : [
                {'key': 'partyName', 'label': '往来单位', 'type': 'text'},
                {'key': 'phone', 'label': '电话', 'type': 'text'},
                {'key': 'receivable', 'label': '应收金额', 'type': 'money'},
              ],
        'columnSearchKeys': statement
            ? [
                'billDate',
                'currencyCode',
                'refNo',
                'receiptOriginal',
                'balanceLocal',
              ]
            : ['partyName', 'phone', 'receivable'],
        'facets': statement
            ? {
                'currencyCode': [
                  {
                    'value': '00000000-0000-4000-8000-000000000001',
                    'label': '美金',
                    'count': 1,
                  },
                ],
              }
            : <String, dynamic>{},
        'rows': [
          for (
            var index = (page - 1) * size;
            index < headerRows && index < page * size;
            index++
          )
            statement
                ? <String, dynamic>{
                    'billDate': '2026-10-12',
                    'currencyCode': '美金',
                    'refNo': 'TARGET',
                    'receiptOriginal': '0.123456789012',
                    'receiptOriginalExact': '0.123456789012',
                    'balanceLocal': '525',
                  }
                : <String, dynamic>{
                    'partyName': headerRows == 1
                        ? '服务器往来单位'
                        : '服务器往来单位${index + 1}',
                    'phone': _fixturePhone,
                    'receivable': '30',
                    'receivableExact': '30',
                  },
        ],
        'page': parameters['page'] ?? 1,
        'size': parameters['size'] ?? 50,
        'total': headerRows,
        'totalPages': (headerRows / size).ceil(),
      };
    }
    final page = parameters['page'] as int? ?? 1;
    final omitted = parameters['includeCount'] == false;
    if (largePreviewRows case final int total when parameters['size'] == 500) {
      final start = (page - 1) * 500;
      final length = (total - start).clamp(0, 500).toInt();
      return {
        'readScopeVersion': 'fixture-v1',
        'page': page,
        'size': 500,
        'total': omitted ? -1 : total,
        'totalPages': omitted ? -1 : (total / 500).ceil(),
        if (parameters['includeColumns'] != false)
          'columns': [
            {'key': 'proof', 'label': '记录', 'type': 'text'},
          ],
        'rows': List.generate(
          length,
          (index) => {
            'id': 'finance-line-${start + index + 1}',
            'proof': '完整打印第${start + index + 1}行',
          },
        ),
      };
    }
    if (previewClamp && parameters['size'] == 500) {
      return {
        'readScopeVersion': 'fixture-v1',
        'page': page,
        'size': 2,
        'total': omitted ? -1 : 3,
        'totalPages': omitted ? -1 : 2,
        if (parameters['includeColumns'] != false)
          'columns': [
            {'key': 'proof', 'label': '记录', 'type': 'text'},
          ],
        'rows': [
          if (page == 1) ...[
            {'id': 'repeated-head', 'proof': '预览第一行'},
            {'id': 'repeated-head', 'proof': '预览第二行'},
          ],
          if (page == 2) {'id': 'repeated-head', 'proof': '预览第三行'},
        ],
      };
    }
    final size = (parameters['size'] as int? ?? 50).clamp(1, 50).toInt();
    final total = pages == 2 ? 51 : pages * size;
    final offset = (page - 1) * size;
    return {
      'readScopeVersion': 'fixture-v1',
      'statisticsGeneratedAt': omitted ? null : '2026-10-25T00:00:00Z',
      'columns': [
        {'key': 'proof', 'label': '记录', 'type': 'text', 'width': 280},
      ],
      'rows': [
        for (
          var index = offset;
          index < total && index < offset + size;
          index++
        )
          {
            'id': 'report-line-${index + 1}',
            'proof': index == offset
                ? '服务端第$page页'
                : '服务端第$page页第${index - offset + 1}行',
          },
      ],
      'page': page,
      'size': size,
      'total': omitted ? -1 : total,
      'totalPages': omitted ? -1 : (total / size).ceil(),
      'facets': omitted
          ? <String, dynamic>{}
          : {
              'proof': [
                {'value': 'source', 'label': '原始来源', 'count': total},
              ],
            },
      'totals': omitted
          ? <dynamic>[]
          : [
              {
                'key': 'qty',
                'label': '数量',
                'type': 'number',
                'groupKey': 'unit',
                'groups': [
                  {'unit': '箱', 'identity': 'box', 'value': '1000.00000001'},
                ],
              },
            ],
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.businessReferenceAccounts ||
        path.contains('/accounts/')) {
      return [
        {'id': 'account-1', 'name': '账户', 'code': 'A1'},
      ];
    }
    if (path.endsWith('/clients/dict') || path.endsWith('/suppliers/dict')) {
      return [
        {'id': 'party-1', 'name': '往来单位', 'code': 'P1'},
      ];
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async => {};

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    postBodies.add(body);
    return get(path, query: query);
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  Widget page,
  _ReportApi api,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await setUtenTestSurfaceSize(tester, const Size(1500, 1000));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'report-reader'),
        ),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        financeStatementReportPrefsProvider.overrideWith(_StatementPrefs.new),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(api.queries, isNotEmpty);
  return ProviderScope.containerOf(
    tester.element(find.byType(page.runtimeType)),
  );
}

void main() {
  for (final statement in [false, true]) {
    testWidgets(
      '${statement ? 'party statement' : 'overview'} failed new header query keeps controls but publishes no old facts',
      (tester) async {
        final api = _ReportApi()..headerFacts = true;
        await _mount(
          tester,
          statement
              ? const FinanceStatementPage()
              : const FinanceArApOverviewPage(),
          api,
        );
        MasterDataTableView<Map<String, dynamic>> table() => tester.widget(
          find.byType(MasterDataTableView<Map<String, dynamic>>),
        );
        expect(table().items, hasLength(1));
        api.failHeaders = true;
        final key = statement ? 'search.refNo' : 'search.partyName';
        table().onFilterChanged(key, '新条件失败');
        await tester.pumpAndSettle();
        expect(table().items, isEmpty);
        expect(table().filters[key], '新条件失败');
        expect(table().error, isNotNull);
        expect(table().summaryBar, isNull);
        api.failHeaders = false;
        table().onRetry!();
        await tester.pumpAndSettle();
        expect(table().items, hasLength(1));
        expect(table().error, isNull);
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(milliseconds: 800));
      },
    );
  }
  testWidgets(
    'party statement typed header uses exact selected currency and clears dependent conditions',
    (tester) async {
      final api = _ReportApi()..headerFacts = true;
      await _mount(tester, const FinanceStatementPage(), api);
      MasterDataTableView<Map<String, dynamic>> table() =>
          tester.widget(find.byType(MasterDataTableView<Map<String, dynamic>>));
      expect(
        table().columns
            .firstWhere((column) => column.key == 'receiptOriginal')
            .columnSearchEnabled,
        isFalse,
      );
      table().onFilterChanged(
        'currencyCode',
        '00000000-0000-4000-8000-000000000001',
      );
      await tester.pumpAndSettle();
      expect(
        table().columns
            .firstWhere((column) => column.key == 'receiptOriginal')
            .columnSearchEnabled,
        isTrue,
      );
      await tester.tap(find.text('冲减应收金额(外)'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '>=0.123456789012',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(api.queries.last['f.search.receiptOriginal'], '>=0.123456789012');
      expect(
        api.queries.last['f.currencyCode'],
        '00000000-0000-4000-8000-000000000001',
      );
      expect(table().items, hasLength(1));
      final print = _toolbarAction<UtenPrintPreviewButton>(tester);
      expect(
        print.exportQuery!['f.search.receiptOriginal'],
        '>=0.123456789012',
      );
      table().onFilterChanged('currencyCode', null);
      await tester.pumpAndSettle();
      expect(table().filters.containsKey('search.receiptOriginal'), isFalse);
      expect(
        api.queries.last.containsKey('f.search.receiptOriginal'),
        isFalse,
        reason: api.queries.toString(),
      );
      expect(
        table().columns
            .firstWhere((column) => column.key == 'receiptOriginal')
            .columnSearchEnabled,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 800));
    },
  );
  testWidgets(
    'overview phone headers keep private body criteria in list print and export scopes',
    (tester) async {
      final api = _ReportApi()..headerFacts = true;
      await _mount(tester, const FinanceArApOverviewPage(), api);
      await tester.tap(find.text('电话'));
      await tester.pumpAndSettle();
      expect(api.candidateFormReads, isNotEmpty);
      expect(
        api.candidateFormReads.first.path,
        '/finance/reports/column-candidates',
      );
      expect(
        api.candidateFormReads.first.body,
        containsPair('report', 'ar-ap/overview'),
      );
      expect(
        api.candidateFormReads.first.body,
        containsPair('column', 'phone'),
      );
      expect(
        api.candidateFormReads.first.body,
        containsPair('__facetSize', 100),
      );
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '1234 5678',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(
        api.queries.every((query) => !query.containsKey('f.search.phone')),
        isTrue,
      );
      expect(api.postBodies.last, {
        'columnSearch': {'phone': '1234 5678'},
      });
      final export = _toolbarAction<UtenExportButton>(tester);
      expect(export.queryParams.containsKey('f.search.phone'), isFalse);
      expect(export.bodyParams, {
        'sensitiveFilter': {
          'columnSearch': {'phone': '1234 5678'},
        },
      });
      final print = _toolbarAction<UtenPrintPreviewButton>(tester);
      expect(print.exportBody, export.bodyParams);
      await tester.runAsync(print.loader);
      expect(api.postBodies.last, {
        'columnSearch': {'phone': '1234 5678'},
      });
      expect(
        api.queries.every((query) => !query.containsKey('f.search.phone')),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 800));
    },
  );
  for (final status in [404, 200]) {
    test(
      'native candidate HTTP $status preserves private form and read-only semantics',
      () async {
        final transport = _CandidateHttpTransport()..status = status;
        final dio = Dio()..httpClientAdapter = transport;
        var writes = 0;
        dio.interceptors.add(DataWriteRevisionInterceptor((_) => writes++));
        addTearDown(() => dio.close(force: true));
        final api = _ReportHttpBoundary(dio);
        final read = api.nativeFormOverHttp(
          '/finance/reports/column-candidates',
          body: {
            'report': 'ar-ap/overview',
            'column': 'phone',
            'f.search.phone': '1234 5678',
            '__facetField': 'value',
            '__facetKeyword': '5678',
            '__facetPage': 1,
            '__facetSize': 100,
          },
        );
        if (status == 404) {
          await expectLater(
            read,
            throwsA(
              isA<ApiException>().having(
                (error) => error.httpStatus,
                'HTTP status',
                404,
              ),
            ),
          );
        } else {
          expect((await read)['items'], [
            {'value': _fixturePhone, 'label': _fixturePhone, 'count': 101},
          ]);
        }
        expect(transport.requests, hasLength(1));
        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(request.queryParameters, isEmpty);
        expect(request.contentType, Headers.formUrlEncodedContentType);
        expect((request.data as Map)['f.search.phone'], '1234 5678');
        expect(writes, 0);
      },
    );
  }
  for (final outcome in ['close', 'retry', 'escape']) {
    testWidgets(
      'candidate HTTP 404 releases busy and preserves private input on $outcome',
      (tester) async {
        final transport = _CandidateWidgetTransport();
        final api = _ReportApi()
          ..headerFacts = true
          ..headerRows = 101
          ..candidateTransport = transport.fetch;
        await _mount(tester, const FinanceArApOverviewPage(), api);
        MasterDataTableView<Map<String, dynamic>> table() => tester.widget(
          find.byType(MasterDataTableView<Map<String, dynamic>>),
        );
        table().onFilterChanged('search.phone', '1234 5678');
        await tester.pumpAndSettle();
        expect(table().items, hasLength(101));
        transport.gate = Completer<Map<String, dynamic>>();
        await tester.tap(
          find.byKey(const ValueKey('master-column-filter-phone')),
        );
        await tester.pump();
        expect(transport.requests, hasLength(1));
        expect(find.byType(UtenBusyOverlay), findsOneWidget);
        transport.gate!.completeError(_CandidateWidgetTransport.missing());
        transport.gate = null;
        await tester.pumpAndSettle();
        expect(
          api.candidateError,
          isA<ApiException>().having(
            (error) => error.httpStatus,
            'HTTP status',
            404,
          ),
        );
        expect(find.byType(UtenBusyOverlay), findsNothing);
        const failure = '候选加载失败，点击重试';
        expect(find.text(failure), findsOneWidget);
        final input = find.byKey(const Key('uten-column-keyword-input'));
        expect(tester.widget<TextField>(input).controller!.text, '1234 5678');
        await tester.enterText(input, '5678');
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        expect(transport.requests, hasLength(2));
        expect(find.text(failure), findsOneWidget);
        expect(tester.widget<TextField>(input).controller!.text, '5678');
        expect(table().filters['search.phone'], '1234 5678');
        if (outcome != 'close') {
          transport.gate = Completer<Map<String, dynamic>>();
          final retryPoint = tester.getCenter(find.text(failure));
          await tester.tapAt(retryPoint);
          await tester.pump();
          expect(find.byType(UtenBusyOverlay), findsOneWidget);
          expect(transport.requests, hasLength(3));
          await tester.pump();
          expect(
            find.byType(UtenBusyOverlayCard).hitTestable(),
            findsOneWidget,
          );
          expect(input, findsOneWidget, reason: 'retry keeps the open input');
          for (var repeat = 0; repeat < 8; repeat++) {
            await tester.tapAt(retryPoint);
            await tester.pump();
            expect(input, findsOneWidget, reason: 'held retry tap $repeat');
          }
          expect(transport.requests, hasLength(3));
          if (outcome == 'escape') {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pump();
            expect(input, findsNothing);
            expect(find.byType(UtenBusyOverlay), findsNothing);
          }
          transport.gate!.complete(transport.response());
          transport.gate = null;
          await tester.pumpAndSettle();
          expect(find.byType(UtenBusyOverlay), findsNothing);
          expect(find.text(failure), findsNothing);
          if (outcome == 'escape') {
            expect(
              input,
              findsNothing,
              reason: 'late success keeps read retired',
            );
          } else {
            expect(tester.widget<TextField>(input).controller!.text, '5678');
          }
        }
        expect(
          transport.requests.every(
            (request) => request['f.search.phone'] == '1234 5678',
          ),
          isTrue,
        );
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(input, findsNothing);
        expect(table().filters['search.phone'], '1234 5678');
        final privateBody = {
          'sensitiveFilter': {
            'columnSearch': {'phone': '1234 5678'},
          },
        };
        expect(
          _toolbarAction<UtenExportButton>(tester).bodyParams,
          privateBody,
        );
        expect(
          _toolbarAction<UtenPrintPreviewButton>(tester).exportBody,
          privateBody,
        );
        final reads = api.queries.length,
            candidateReads = transport.requests.length;
        await tester.drag(
          find.byType(MasterDataTableView<Map<String, dynamic>>),
          const Offset(0, -10000),
        );
        await tester.pumpAndSettle();
        expect(api.queries, hasLength(reads));
        expect(transport.requests, hasLength(candidateReads));
        expect(table().items, hasLength(101));
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'finance ordinary page print reads all 2501 rows beyond the former prefix ceiling',
    (tester) async {
      final api = _ReportApi();
      await _mount(tester, const FinanceReportTablePage(cardId: 'detail'), api);
      final button = _toolbarAction<UtenPrintPreviewButton>(tester);
      api.largePreviewRows = 2501;
      final before = api.queries.length;
      final printed = await tester.runAsync(button.loader);
      expect(printed!.rows, hasLength(2501));
      expect(printed.rows.first, ['完整打印第1行']);
      expect(printed.rows.last, ['完整打印第2501行']);
      expect(printed.rowIds!.toSet(), hasLength(2501));
      final reads = api.queries.skip(before).toList();
      expect(reads.map((query) => query['page']), [1, 2, 3, 4, 5, 6]);
      expect(reads.map((query) => query['size']), everyElement(500));
      expect(reads.map((query) => query['includeCount']), everyElement(true));
      expect(reads.map((query) => query['includeTotals']), everyElement(true));
      for (final entry in button.exportQuery!.entries) {
        expect(reads.every((query) => query[entry.key] == entry.value), isTrue);
      }
      expect(tester.takeException(), isNull);
    },
  );
  final pages = <String, Widget>{
    'sales': const SalesReportPage(kind: SalesReportKind.summary),
    'purchase': const PurchaseReportTablePage(kind: PurchaseReportKind.summary),
    'subcontract': const SubcontractReportTablePage(
      kind: SubcontractReportKind.summary,
    ),
    'warehouse': const WarehouseReportTablePage(
      kind: WarehouseReportKind.summary,
    ),
    'production': const ProductionReportPage(
      kind: ProductionReportKind.summary,
    ),
    'finance': const FinanceReportTablePage(cardId: 'detail'),
    'statement': const FinanceStatementPage(),
    'account': const FinanceAccountFlowPage(),
    'ar-ap': const FinanceArApOverviewPage(),
    'customer drilldown': const SalesClientDetailDialog(
      docType: SalesReportDocType.order,
      docSeg: 'orders',
      clientId: 'client-1',
      currencyId: 'usd',
      clientName: '客户',
      dateFrom: '2026-10-01',
      dateTo: '2026-10-25',
    ),
  };
  for (final entry in pages.entries) {
    testWidgets(
      '${entry.key} print loader respects actual server pages and reads the complete filtered scope',
      (tester) async {
        final api = _ReportApi();
        await _mount(tester, entry.value, api);
        final button = _toolbarAction<UtenPrintPreviewButton>(tester);
        api.previewClamp = true;
        final before = api.queries.length;
        final preview = await tester.runAsync(button.loader);
        expect(preview!.rows, [
          ['预览第一行'],
          ['预览第二行'],
          ['预览第三行'],
        ]);
        expect(preview.rowIds, [
          'repeated-head',
          'repeated-head',
          'repeated-head',
        ]);
        final reads = api.queries.skip(before).toList();
        expect(reads.map((query) => query['page']), [1, 2]);
        expect(reads.map((query) => query['size']), everyElement(500));
        expect(reads.map((query) => query['includeCount']), everyElement(true));
        expect(
          reads.map((query) => query['includeTotals']),
          everyElement(true),
        );
        expect(button.subtitle, contains('全部筛选结果'));
        for (final filter
            in (button.exportQuery ?? const <String, dynamic>{}).entries) {
          expect(
            reads.first[filter.key],
            filter.value,
            reason: 'Print and export share ${filter.key}',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${entry.key} completes server metadata${entry.key == 'account' ? ' and retains balance chronology' : ' and reloads on sorting'}',
      (tester) async {
        final api = _ReportApi();
        await _mount(tester, entry.value, api);
        final finder = find.byWidgetPredicate(
          (widget) => widget is MasterDataTableView<Map<String, dynamic>>,
        );
        MasterDataTableView<Map<String, dynamic>> table() =>
            tester.widget(finder);
        expect(table().items, hasLength(51));
        expect(table().items.first['id'], 'report-line-1');
        expect(table().items.last['id'], 'report-line-51');
        expect(table().currentPage, 1);
        expect(table().totalPages, 1);
        expect(api.queries.map((query) => query['page']), [1, 2]);
        expect(api.queries.first['includeCount'], isNull);
        expect(api.queries.last, containsPair('includeCount', false));
        expect(api.queries.last, containsPair('includeFacets', false));
        expect(api.queries.last, containsPair('includeTotals', false));
        final completedRequests = api.queries.length;
        await tester.drag(finder, const Offset(0, -4000));
        await tester.pumpAndSettle();
        expect(api.queries, hasLength(completedRequests));
        expect(find.text('服务端第2页'), findsOneWidget);
        if (entry.key != 'ar-ap') {
          expect(find.textContaining('1000.00000001'), findsWidgets);
        }
        if (const {
          'sales',
          'purchase',
          'subcontract',
          'warehouse',
          'production',
          'finance',
        }.contains(entry.key)) {
          expect(table().facets['proof']!.single.label, '原始来源');
          expect(table().facets['proof']!.single.count, 51);
        }
        final beforeReturn = api.queries.length;
        await tester.drag(finder, const Offset(0, 4000));
        await tester.pumpAndSettle();
        expect(table().currentPage, 1);
        expect(table().totalPages, 1);
        expect(
          api.queries.length,
          beforeReturn,
          reason: 'Scrolling the complete report returns without RPC',
        );
        expect(find.text('服务端第1页'), findsOneWidget);
        final beforeSort = api.queries.length;
        if (entry.key == 'account') {
          expect(table().onSortChange, isNull);
          expect(table().columns.every((column) => !column.sortable), isTrue);
        } else {
          table().onSortChange!('proof', false);
          await tester.pumpAndSettle();
          final sorted = api.queries
              .skip(beforeSort)
              .firstWhere((q) => q['page'] == 1);
          expect(sorted['includeCount'], isNull);
          expect(sorted['includeFacets'], isNull);
          expect(sorted['includeTotals'], isNull);
          expect(table().currentPage, 1);
        }
        if (const {'statement', 'account', 'ar-ap'}.contains(entry.key)) {
          api.pages = 80;
          final beforeLongRead = api.queries.length;
          table().onRetry!();
          await tester.pumpAndSettle();
          expect(table().items, hasLength(4000));
          expect(
            api.queries.skip(beforeLongRead).map((query) => query['page']),
            [for (var page = 1; page <= 80; page++) page],
          );
          final beforeScroll = api.queries.length;
          await tester.drag(finder, const Offset(0, -200000));
          await tester.pumpAndSettle();
          expect(api.queries, hasLength(beforeScroll));
          expect(table().items.last['id'], 'report-line-4000');
          final beforeRefresh = api.queries.length;
          table().onRetry!();
          await tester.pumpAndSettle();
          expect(
            api.queries.skip(beforeRefresh).first['page'],
            1,
            reason:
                'An explicit retry starts a new complete read from its first bounded batch',
          );
          expect(
            api.queries.skip(beforeRefresh).map((query) => query['page']),
            [for (var page = 1; page <= 80; page++) page],
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

// These tests verify the report loader/query contract. The shared responsive
// toolbar may retain an action in its overflow menu without mounting it yet.
T _toolbarAction<T extends Widget>(WidgetTester tester) {
  final visible = find.byWidgetPredicate((widget) => widget is T);
  if (visible.evaluate().isNotEmpty) return tester.widget<T>(visible.first);
  for (final table
      in tester.widgetList<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      )) {
    for (final action in table.toolbarActions ?? const <Widget>[]) {
      if (action is T) return action;
    }
  }
  throw StateError('The owning report did not declare action $T');
}
