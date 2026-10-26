import 'dart:typed_data';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/export/report_export_job_dialog.dart';
import 'package:uten_imp/shared/export/report_export_jobs.dart';
import 'package:uten_imp/shared/export/master_export_job.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://a.invalid/api')));
  bool available = true;
  Object? capabilityError;
  bool loseCreate = false;
  bool asynchronousCancel = false;
  bool cancelRequested = false;
  Object? authorizationError;
  final authorizationChecks = <String>[];
  String status = 'SUCCEEDED';
  final creates = <Map<String, dynamic>>[];
  final reads = <String>[];
  final cancels = <String>[];
  final downloads = <({String path, Object? body})>[];
  List<Map<String, dynamic>> history = [];

  Map<String, dynamic> job(String id) {
    final request = creates.where((value) => value['id'] == id).lastOrNull;
    return {
      'id': id,
      'domain': request?['domain'] ?? 'sales',
      'report': request?['report'] ?? 'order/detail',
      'format': request?['format'] ?? 'xlsx',
      'status': status,
      'cancelRequested': cancelRequested,
      'rows': 2000,
      'snapshotAt': '2026-10-26T01:00:00Z',
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/capabilities')) {
      if (capabilityError != null) throw capabilityError!;
      return {'available': available};
    }
    if (path.endsWith('/download-authorization')) {
      authorizationChecks.add(path);
      if (authorizationError != null) throw authorizationError!;
      return {'authorized': true};
    }
    reads.add(path);
    return job(path.split('/').last);
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => history;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/cancel')) {
      cancels.add(path);
      if (asynchronousCancel) {
        cancelRequested = true;
      } else {
        status = 'CANCELLED';
      }
      return {};
    }
    final request = Map<String, dynamic>.from(body! as Map);
    creates.add(request);
    if (loseCreate) {
      loseCreate = false;
      throw NetworkTimeoutException();
    }
    return job(request['id'] as String);
  }

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    downloads.add((path: path, body: body));
    return Uint8List.fromList([1, 2, 3]);
  }
}

ReportExportJobRequest _request() => ReportExportJobRequest.create(
  domain: 'sales',
  report: 'order/detail',
  parameters: {
    'dateFrom': '2026-10-01',
    'f.currency': 'usd',
    'sort': 'amount',
    'order': 'desc',
    'password': 'never-store-this',
  },
);

Future<ReportExportJobsClient> _client(
  _Api api, {
  bool Function()? current,
}) async => ReportExportJobsClient(
  api,
  await api.captureRequestScope(isCurrent: current ?? () => true),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('capability is explicit and only absent old routes fall back', () async {
    final api = _Api();
    final client = await _client(api);
    expect(await client.available(), isTrue);
    api.available = false;
    expect(await client.available(), isFalse);
    api.capabilityError = ApiException('NOT_FOUND', '旧版本', httpStatus: 404);
    expect(await client.available(), isFalse);
    api.capabilityError = NetworkTimeoutException();
    await expectLater(
      client.available(),
      throwsA(isA<NetworkTimeoutException>()),
    );
    expect(
      reportExportJobDomain('/production/reports/where-used/export'),
      'where_used',
    );
    expect(reportExportJobDomain('/master/goods/export'), 'master');
    expect(reportExportJobDomain('/master/goods/bom/export'), isNull);
    expect(
      reportExportJobDomain('/operations/workbench/purchase/export'),
      'workbench_purchase',
    );
    expect(reportExportJobDomain('/stock/reports/export'), 'stock');
  });

  test(
    'legacy requests default to xlsx and PDF pending requests have their own namespace',
    () async {
      final api = _Api();
      final client = await _client(api);
      final preferences = await SharedPreferences.getInstance();
      final legacy = Map<String, dynamic>.from(_request().json)
        ..remove('format');
      final parsed = ReportExportJobRequest.fromJson(legacy);
      expect(parsed.format, 'xlsx');
      final xlsx = ReportExportPendingStore(
        preferences,
        client.scope.identity,
        'where_used',
        'where-used',
      );
      final explicitXlsx = ReportExportPendingStore(
        preferences,
        client.scope.identity,
        'where_used',
        'where-used',
        // The explicit legacy format must keep the original implicit namespace.
        // ignore: avoid_redundant_argument_values
        format: 'xlsx',
      );
      final pdf = ReportExportPendingStore(
        preferences,
        client.scope.identity,
        'where_used',
        'where-used',
        format: 'pdf',
      );
      expect(xlsx.key, explicitXlsx.key);
      expect(pdf.key, isNot(xlsx.key));
      await xlsx.save(parsed);
      final pdfRequest = ReportExportJobRequest.create(
        domain: 'where_used',
        report: 'where-used',
        parameters: {},
        format: 'pdf',
      );
      await pdf.save(pdfRequest);
      expect(xlsx.read()!.id, parsed.id);
      expect(pdf.read()!.id, pdfRequest.id);
      expect(pdf.read()!.format, 'pdf');
      expect(
        ReportExportJob.fromJson({
          'id': 'legacy',
          'domain': 'sales',
          'report': 'order/detail',
          'status': 'SUCCEEDED',
        }).format,
        'xlsx',
      );
    },
  );

  const masterEndpoints = {
    '/master/goods/export': 'goods',
    '/master/clients/export': 'client',
    '/master/suppliers/export': 'supplier',
    '/master/accounts/export': 'account',
    '/master/currencies/export': 'currency',
    '/master/colors/export': 'color',
    '/master/units/export': 'unit',
    '/master/moulds/export': 'mould',
    '/master/warehouses/export': 'warehouse',
    '/master/reference-methods/settlement-admin/export': 'settlement_method',
  };
  for (final entry in masterEndpoints.entries) {
    testWidgets(
      'master ${entry.value} button uses its exact durable source identity',
      (tester) async {
        final api = _Api();
        final preferences = await SharedPreferences.getInstance();
        final contact = entry.value == 'client' || entry.value == 'supplier';
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              sharedPreferencesProvider.overrideWithValue(preferences),
              authenticatedScopeProvider.overrideWithValue(
                const AuthenticatedScope(userId: 'reader'),
              ),
              currentPermissionsProvider.overrideWithValue({}),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: UtenExportButton(
                  endpoint: entry.key,
                  report: '',
                  queryParams: const {
                    'nullFields': 'status',
                    'sort': 'code',
                    'order': 'desc',
                  },
                  bodyParams: contact
                      ? const {
                          'sensitiveFilter': {
                            'keyword': 'private contact',
                            'mobile': 'private-mobile',
                          },
                        }
                      : const {},
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('下载表格'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('直接下载'));
        await tester.pumpAndSettle();
        expect(find.byType(ReportExportJobDialog), findsOneWidget);
        final request = api.creates.single;
        expect(request['domain'], 'master');
        expect(request['report'], entry.value);
        expect(request['sort'], 'code');
        expect(request['order'], 'desc');
        final filter =
            jsonDecode((request['parameters'] as Map)['filter'] as String)
                as Map;
        expect(filter['nullFields'], ['status']);
        if (contact) {
          expect(filter['keyword'], 'private contact');
          expect(filter['mobile'], 'private-mobile');
        }
        expect(request, isNot(contains('password')));
        expect(api.downloads, isEmpty);
        expect(masterExportJobReport(entry.key), entry.value);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
      },
    );
  }

  test(
    'unknown create preserves its ID and original query across reopen',
    () async {
      final api = _Api()..loseCreate = true;
      final client = await _client(api);
      final preferences = await SharedPreferences.getInstance();
      final store = ReportExportPendingStore(
        preferences,
        client.scope.identity,
        'sales',
        'order/detail',
      );
      final request = _request();
      await store.save(request);
      await expectLater(
        client.create(request),
        throwsA(isA<NetworkTimeoutException>()),
      );
      final restored = ReportExportPendingStore(
        preferences,
        client.scope.identity,
        'sales',
        'order/detail',
      ).read()!;
      expect(restored.id, request.id);
      expect(restored.json['password'], isNull);
      expect(restored.json['parameters'], isNot(contains('password')));
      expect(restored.json['sort'], 'amount');
      expect(restored.json['parameters'], containsPair('f.currency', 'usd'));
      expect((await client.read(restored.id)).id, request.id);
      expect(api.creates, hasLength(1));
      await client.create(restored); // Explicit same-ID retry only.
      expect(api.creates[1], api.creates[0]);
      await store.resolve('another-id');
      expect(store.read(), isNotNull);
      await store.resolve(request.id);
      expect(store.read(), isNull);
      expect(preferences.getKeys(), isEmpty);
    },
  );

  test(
    'cancel rechecks the task and download authorizes the original scope',
    () async {
      var current = true;
      final api = _Api();
      final client = await _client(api, current: () => current);
      final request = _request();
      expect((await client.cancel(request.id)).status, 'CANCELLED');
      expect(api.cancels.single, endsWith('/${request.id}/cancel'));
      expect(api.reads.single, endsWith('/${request.id}'));
      await client.download(request.id, 'ephemeral');
      expect(api.downloads.single.body, {'password': 'ephemeral'});
      expect(
        api.authorizationChecks.single,
        endsWith('/${request.id}/download-authorization'),
      );
      current = false;
      await expectLater(
        client.download(request.id, ''),
        throwsA(isA<ApiException>()),
      );
      expect(api.downloads, hasLength(1));
    },
  );
  test(
    'server scope withdrawn after receiving bytes prevents final publication',
    () async {
      final api = _Api();
      final client = await _client(api);
      final request = _request();
      api.authorizationError = ApiException(
        'CONFLICT',
        '实际数据范围已变化',
        httpStatus: 409,
      );
      await expectLater(
        client.download(request.id, ''),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'CONFLICT')),
      );
      expect(api.downloads, hasLength(1));
      expect(api.authorizationChecks, hasLength(1));
    },
  );

  Future<void> mountDialog(WidgetTester tester, _Api api) async {
    final client = await _client(api);
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ReportExportJobDialog(
              client: client,
              request: _request(),
              store: ReportExportPendingStore(
                preferences,
                client.scope.identity,
                'sales',
                'order/detail',
              ),
              stillCurrent: () => true,
              onDownload: (job) async => client.download(job.id, ''),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('unknown receipt is checked without creating another task', (
    tester,
  ) async {
    final api = _Api()..loseCreate = true;
    await mountDialog(tester, api);
    await tester.pumpAndSettle();
    expect(find.text('上次创建结果尚未确认，请先核查原任务。'), findsOneWidget);
    final id = api.creates.single['id'];
    await tester.tap(find.text('核查任务'));
    await tester.pumpAndSettle();
    expect(api.reads.single, endsWith('/$id'));
    expect(api.creates, hasLength(1));
    expect(find.text('已生成'), findsOneWidget);
    expect(find.text('下载文件'), findsOneWidget);
  });

  testWidgets('running task shows progress and cancellation is confirmed', (
    tester,
  ) async {
    final api = _Api()
      ..status = 'RUNNING'
      ..asynchronousCancel = true;
    await mountDialog(tester, api);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在生成'), findsOneWidget);
    expect(find.text('已处理 2000 行'), findsOneWidget);
    await tester.tap(find.text('取消任务'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在取消'), findsOneWidget);
    expect(find.text('已取消'), findsNothing);
    expect(find.text('取消任务'), findsNothing);
    api.status = 'CANCELLED';
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(api.cancels, hasLength(1));
    expect(find.text('已取消'), findsOneWidget);
  });

  testWidgets('report export button uses configured durable capability', (
    tester,
  ) async {
    final api = _Api();
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWithValue(preferences),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'reader'),
          ),
          currentPermissionsProvider.overrideWithValue({}),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: UtenExportButton(
              endpoint: '/sales/reports/export',
              report: 'order/detail',
              queryParams: {'dateFrom': '2026-10-01'},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('下载表格'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('直接下载'));
    await tester.pumpAndSettle();
    expect(find.byType(ReportExportJobDialog), findsOneWidget);
    expect(api.creates.single['domain'], 'sales');
    expect(api.creates.single['parameters'], {'dateFrom': '2026-10-01'});
    expect(api.creates.single, isNot(contains('password')));
    expect(api.downloads, isEmpty);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });
}
