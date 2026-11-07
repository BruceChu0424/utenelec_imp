import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/shared/export/report_export_job_dialog.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _ExportApi extends ApiClient {
  _ExportApi({this.jobsAvailable = true}) : super(Dio());

  final bool jobsAvailable;
  final jobs = <Map<String, dynamic>>[];
  final direct = <({Map<String, dynamic> query, Map<String, dynamic> body})>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {'available': jobsAvailable, 'selectionVersion': 1};

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    jobs.add(Map<String, dynamic>.from(body! as Map));
    throw ApiException('FIXTURE_CAPTURE', '已记录完整导出请求');
  }

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    direct.add((
      query: Map<String, dynamic>.from(query!),
      body: Map<String, dynamic>.from(body! as Map),
    ));
    throw ApiException('FIXTURE_CAPTURE', '已记录完整导出请求');
  }
}

Future<void> _openExport(
  WidgetTester tester,
  _ExportApi api, {
  required String endpoint,
  String report = '',
  String format = 'pdf',
  Map<String, dynamic> body = const {},
  Set<String>? selectedIds,
}) async {
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'complete-export-reader'),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: UtenExportButton(
            endpoint: endpoint,
            report: report,
            queryParams: const {
              'sort': 'code',
              'order': 'desc',
              'search.name': '=原始条件',
            },
            bodyParams: body,
            selectedIds: selectedIds,
            prepareExport: () async => UtenExportSelection(extension: format),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('下载表格'));
  await tester.pumpAndSettle();
  if (selectedIds != null) {
    await tester.tap(find.byKey(const Key('table-output-selected')));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('直接下载'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const masters = {
    'goods': 'goods',
    'clients': 'client',
    'suppliers': 'supplier',
    'accounts': 'account',
    'currencies': 'currency',
    'colors': 'color',
    'units': 'unit',
    'moulds': 'mould',
    'warehouses': 'warehouse',
    'reference-methods/settlement-admin': 'settlement_method',
  };
  for (final master in masters.entries) {
    testWidgets('${master.value} PDF uses the complete durable source', (
      tester,
    ) async {
      final api = _ExportApi();
      final contact = {'client', 'supplier', 'account'}.contains(master.value);
      await _openExport(
        tester,
        api,
        endpoint: '/master/${master.key}/export',
        body: {
          'format': 'pdf',
          if (contact)
            'sensitiveFilter': {
              'keyword': '私有联系方式',
              'columnSearch': {'phone': '+00123'},
            },
        },
      );
      expect(find.byType(ReportExportJobDialog), findsOneWidget);
      final request = api.jobs.single;
      expect(request['domain'], 'master');
      expect(request['report'], master.value);
      expect(request['format'], 'pdf');
      final filter =
          jsonDecode((request['parameters'] as Map)['filter'] as String) as Map;
      final columnSearch = filter['columnSearch'] as Map;
      expect(columnSearch['name'], '=原始条件');
      if (contact) {
        expect(filter['keyword'], '私有联系方式');
        expect(columnSearch['phone'], '+00123');
      }
      expect(api.direct, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  const tabularEndpoints = {
    '/sales/reports/export': 'sales',
    '/purchase/reports/export': 'purchase',
    '/subcontract/reports/export': 'subcontract',
    '/production/reports/export': 'production',
    '/stock/reports/export': 'stock',
    '/finance/reports/export': 'finance',
    '/admin/audit-logs/export': 'audit',
    '/operations/workbench/purchase/export': 'workbench_purchase',
    '/operations/workbench/subcontract/export': 'workbench_subcontract',
  };
  for (final endpoint in tabularEndpoints.entries) {
    testWidgets(
      '${endpoint.value} PDF retains its complete source and format',
      (tester) async {
        final api = _ExportApi();
        await _openExport(
          tester,
          api,
          endpoint: endpoint.key,
          report: 'current-report',
          body: {
            'format': 'pdf',
            if (endpoint.value == 'finance')
              'sensitiveFilter': {
                'columnSearch': {'phone': '+00123'},
              },
          },
        );
        expect(find.byType(ReportExportJobDialog), findsOneWidget);
        final request = api.jobs.single;
        expect(request['domain'], endpoint.value);
        expect(request['format'], 'pdf');
        expect(request['sort'], 'code');
        expect(request['order'], 'desc');
        expect(api.direct, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final jobsAvailable in [false, true]) {
    for (final format in jobsAvailable ? ['xlsx', 'pdf'] : ['xlsx']) {
      testWidgets(
        'goods $format retains all 1201 selected identities with jobs=$jobsAvailable',
        (tester) async {
          final api = _ExportApi(jobsAvailable: jobsAvailable);
          final selectedIds = {
            for (var index = 1; index <= 1201; index++)
              '00000001-0000-0000-0000-${index.toRadixString(16).padLeft(12, '0')}',
          };
          await _openExport(
            tester,
            api,
            endpoint: '/master/goods/export',
            format: format,
            selectedIds: selectedIds,
          );
          final List<dynamic> selected;
          if (jobsAvailable) {
            final request = api.jobs.single;
            expect(request['format'], format);
            final parameters = request['parameters'] as Map;
            selected = jsonDecode(parameters['selectedIds'] as String) as List;
            expect(parameters, isNot(contains('page')));
            expect(parameters, isNot(contains('size')));
            expect(api.direct, isEmpty);
          } else {
            final request = api.direct.single;
            selected = request.body['selectedIds'] as List;
            expect(request.query, isNot(contains('page')));
            expect(request.query, isNot(contains('size')));
            expect(api.jobs, isEmpty);
          }
          expect(selected.length, 1201);
          expect(selected.toSet(), selectedIds);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('unavailable PDF jobs cannot deliver an XLSX with a PDF name', (
    tester,
  ) async {
    final api = _ExportApi(jobsAvailable: false);
    await _openExport(tester, api, endpoint: '/master/goods/export');
    expect(api.jobs, isEmpty);
    expect(api.direct, isEmpty);
    final notifications = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold)),
    ).read(appNotificationProvider);
    expect(
      notifications.map((notification) => notification.message),
      contains('当前服务器尚未开启此报表的PDF导出，请更新服务端后重试；本次未生成文件'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'business document bodies retain their original endpoint contract',
    (tester) async {
      final api = _ExportApi();
      await _openExport(
        tester,
        api,
        endpoint: '/sales/reports/export',
        body: const {
          'templateIds': ['original-template'],
        },
      );
      expect(api.jobs, isEmpty);
      expect(api.direct.single.body['templateIds'], ['original-template']);
      expect(tester.takeException(), isNull);
    },
  );
}
