import 'dart:typed_data';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';

Widget _app({required Set<String> permissions, required Widget child}) {
  return ProviderScope(
    overrides: [
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'a'),
      ),
      apiBaseUrlProvider.overrideWithValue('https://a.invalid'),
      currentPermissionsProvider.overrideWithValue(permissions),
    ],
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets(
    'ordinary export cannot revive after server A to B to A while password dialog is open',
    (tester) async {
      final server = StateProvider<String>((ref) => 'https://a.invalid');
      final api = _NoDownloadApi();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'a'),
          ),
          apiBaseUrlProvider.overrideWith((ref) => ref.watch(server)),
          currentPermissionsProvider.overrideWithValue({}),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: UtenExportButton(
                endpoint: '/export',
                report: 'quote',
                queryParams: {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('下载表格'));
      await tester.pumpAndSettle();
      container.read(server.notifier).state = 'https://b.invalid';
      await tester.pump();
      container.read(server.notifier).state = 'https://a.invalid';
      await tester.pump();
      await tester.tap(find.text('直接下载'));
      await tester.pumpAndSettle();
      expect(api.downloads, 0);
    },
  );

  testWidgets(
    'old request completion cannot release the new identity export busy state',
    (tester) async {
      final server = StateProvider<String>((ref) => 'https://a.invalid');
      final api = _QueuedDownloadApi();
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'a'),
          ),
          apiBaseUrlProvider.overrideWith((ref) => ref.watch(server)),
          currentPermissionsProvider.overrideWithValue({}),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: UtenExportButton(
                endpoint: '/export',
                report: 'quote',
                queryParams: {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('下载表格'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('直接下载'));
      await tester.pump();
      expect(api.results, hasLength(1));
      container.read(server.notifier).state = 'https://b.invalid';
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载表格'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('直接下载'));
      await tester.pump();
      expect(api.results, hasLength(2));
      api.results.first.completeError(StateError('old request failed'));
      await tester.pump();
      expect(
        tester.widget<UtenButton>(find.byType(UtenButton).first).isLoading,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      api.results.last.completeError(StateError('test finished'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'business identity change during password entry blocks dispatch',
    (tester) async {
      bool current = true;
      final api = _NoDownloadApi();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'a'),
            ),
            apiBaseUrlProvider.overrideWithValue('https://a.invalid'),
            currentPermissionsProvider.overrideWithValue({}),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: UtenExportButton(
                endpoint: '/export',
                report: 'quote',
                queryParams: const {},
                prepareExport: () async =>
                    UtenExportSelection(stillCurrent: () => current),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('下载表格'));
      await tester.pumpAndSettle();
      current = false;
      await tester.tap(find.text('直接下载'));
      await tester.pumpAndSettle();
      expect(api.downloads, 0);
    },
  );

  testWidgets(
    'a late response from a previous identity is never saved to disk',
    (tester) async {
      bool current = true;
      final api = _DeferredDownloadApi();
      final directory = Directory.systemTemp.createTempSync(
        'uten-export-fence-',
      );
      final oldPaths = PathProviderPlatform.instance;
      final paths = _CountingPaths(directory.path);
      PathProviderPlatform.instance = paths;
      addTearDown(() {
        PathProviderPlatform.instance = oldPaths;
        if (!directory.absolute.path.startsWith(
          Directory.systemTemp.absolute.path,
        )) {
          throw StateError('Unexpected test path');
        }
        directory.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'a'),
            ),
            apiBaseUrlProvider.overrideWithValue('https://a.invalid'),
            currentPermissionsProvider.overrideWithValue({}),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: UtenExportButton(
                endpoint: '/export',
                report: 'quote',
                queryParams: const {},
                prepareExport: () async =>
                    UtenExportSelection(stillCurrent: () => current),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('下载表格'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('直接下载'));
      await tester.pump();
      expect(api.downloads, 1);
      current = false;
      api.result.complete(Uint8List.fromList([1, 2, 3]));
      await tester.pumpAndSettle();
      expect(paths.calls, 0);
      expect(directory.listSync(), isEmpty);
    },
  );
  testWidgets(
    'revoking export permission while password dialog is open prevents download',
    (tester) async {
      final grants = StateProvider<Set<String>>(
        (ref) => {Perm.goodsCostExport},
      );
      final api = _NoDownloadApi();
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'a'),
          ),
          apiBaseUrlProvider.overrideWithValue('https://a.invalid'),
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWith((ref) => ref.watch(grants)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: UtenExportButton(
                endpoint: '/reports/export',
                report: 'cost',
                queryParams: {},
                requiredPermission: Perm.goodsCostExport,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('下载表格'));
      await tester.pumpAndSettle();
      container.read(grants.notifier).state = {};
      await tester.pump();
      await tester.tap(find.text('直接下载'));
      await tester.pumpAndSettle();
      expect(api.downloads, 0);
      expect(find.text('下载表格'), findsNothing);
    },
  );
  testWidgets('export button is hidden without its required permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        permissions: const {},
        child: const UtenExportButton(
          endpoint: '/reports/export',
          report: 'detail',
          queryParams: {},
          requiredPermission: Perm.salesReportExport,
        ),
      ),
    );

    expect(find.text('下载表格'), findsNothing);
  });

  testWidgets('export button is visible with its required permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        permissions: const {Perm.salesReportExport},
        child: const UtenExportButton(
          endpoint: '/reports/export',
          report: 'detail',
          queryParams: {},
          requiredPermission: Perm.salesReportExport,
        ),
      ),
    );

    expect(find.text('下载表格'), findsOneWidget);
  });

  testWidgets(
    'export dialog allows plain download and a one-character password',
    (tester) async {
      await tester.pumpWidget(
        _app(
          permissions: const {Perm.salesReportExport},
          child: const UtenExportButton(
            endpoint: '/reports/export',
            report: 'detail',
            queryParams: {},
            requiredPermission: Perm.salesReportExport,
          ),
        ),
      );

      await tester.tap(find.text('下载表格'));
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (w) =>
              w is TextField && w.decoration?.labelText == '打开密码(可选，1–128 位)',
        ),
        findsOneWidget,
      );
      expect(find.text('直接下载'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '确认密码',
        ),
        findsNothing,
      );

      await tester.enterText(find.byType(TextField), '1');
      await tester.pump();

      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '确认密码',
        ),
        findsOneWidget,
      );
      expect(find.text('加密下载'), findsOneWidget);
    },
  );

  testWidgets('print preview applies permission to its nested Excel action', (
    tester,
  ) async {
    Future<UtenPrintTable> loader() async =>
        const UtenPrintTable(headers: ['列'], rows: []);

    await tester.pumpWidget(
      _app(
        permissions: const {},
        child: UtenPrintPreviewButton(
          title: '测试报表',
          loader: loader,
          exportEndpoint: '/reports/export',
          exportPermission: Perm.financeReportExport,
        ),
      ),
    );
    await tester.tap(find.text('预览打印'));
    await tester.pumpAndSettle();

    expect(find.text('下载Excel'), findsNothing);
  });

  // 2026-10-20「导出组件」事故回归：纯展示列（树形身份格等）不进导出投影，
  // 否则后端以「列不存在或不在可导出范围」整单拒绝；全部列都不可导出时不送投影。
  testWidgets('export projection drops non-exportable columns', (tester) async {
    final api = _CapturingApi();
    final exported = await _runExportWithProjection(
      tester,
      api,
      const [
        TableProjectedColumn(
          key: 'treeIdentity',
          label: '层级 / 组件',
          width: 340,
          type: 'text',
          exportable: false,
        ),
        TableProjectedColumn(key: 'code', label: '编号', width: 110, type: 'text'),
      ],
    );
    expect(exported['columnProjection'], isA<Map<String, dynamic>>());
    final columns = (exported['columnProjection'] as Map<String, dynamic>)['columns']
        as List<dynamic>;
    expect(columns.map((c) => (c as Map<String, dynamic>)['key']), ['code']);
  });

  testWidgets('all columns non-exportable means no projection payload', (tester) async {
    final api = _CapturingApi();
    final exported = await _runExportWithProjection(
      tester,
      api,
      const [
        TableProjectedColumn(
          key: 'treeIdentity',
          label: '层级 / 组件',
          width: 340,
          type: 'text',
          exportable: false,
        ),
      ],
    );
    expect(exported.containsKey('columnProjection'), isFalse);
  });
}

/// 发布一张投影并跑完「下载表格 → 直接下载」，返回捕获到的请求体。
Future<Map<String, dynamic>> _runExportWithProjection(
  WidgetTester tester,
  ApiClient api,
  List<TableProjectedColumn> columns,
) async {
  final controller = TableColumnProjectionController();
  addTearDown(controller.dispose);
  final owner = Object();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'a'),
        ),
        apiBaseUrlProvider.overrideWithValue('https://a.invalid'),
        currentPermissionsProvider.overrideWithValue(const {}),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TableColumnProjectionScope(
          controller: controller,
          child: Scaffold(
            body: Builder(
              builder: (context) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  controller.publish(
                    owner,
                    TableColumnProjection(
                      tableKey: 'goods-bom-table',
                      columns: columns,
                    ),
                    contextOwner: ModalRoute.of(context),
                  );
                });
                return const UtenExportButton(
                  endpoint: '/export',
                  report: '',
                  queryParams: {},
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('下载表格'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('直接下载'));
  await tester.pumpAndSettle();
  expect(api.bodies, hasLength(1));
  return api.bodies.single!;
}

class _CapturingApi extends ApiClient {
  _CapturingApi() : super(Dio());
  final List<Map<String, dynamic>> bodies = [];
  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    if (body is Map<String, dynamic>) bodies.add(Map.of(body));
    throw StateError('capture only');
  }
}

class _CountingPaths extends PathProviderPlatform {
  _CountingPaths(this.path);
  final String path;
  int calls = 0;
  @override
  Future<String?> getDownloadsPath() async {
    calls++;
    return path;
  }
}

class _DeferredDownloadApi extends ApiClient {
  _DeferredDownloadApi() : super(Dio());
  int downloads = 0;
  final result = Completer<Uint8List>();
  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) {
    downloads++;
    return result.future;
  }
}

class _QueuedDownloadApi extends ApiClient {
  _QueuedDownloadApi() : super(Dio());
  final results = <Completer<Uint8List>>[];
  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) {
    final pending = Completer<Uint8List>();
    results.add(pending);
    return pending.future;
  }
}

class _NoDownloadApi extends ApiClient {
  _NoDownloadApi() : super(Dio());
  int downloads = 0;
  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    downloads++;
    throw StateError('Revoked export must not reach the network');
  }
}
