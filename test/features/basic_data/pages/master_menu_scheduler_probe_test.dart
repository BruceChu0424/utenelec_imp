import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/uten_test_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/app.dart';
import 'package:uten_imp/features/shell/pages/main_shell_page.dart';
import 'package:uten_imp/core/router/business_window_host.dart';
import 'package:uten_imp/features/admin/widgets/server_update_popup_gate.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/maintenance/server_maintenance.dart';
import 'package:uten_imp/core/platform/platform_window_title.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/platform_tables_host.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
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
import '../../../support/pump_until.dart';

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
  'mould:status',
  'goods:export',
  'client:export',
  'supplier:export',
  'account:export',
  'currency:export',
  'color:export',
  'unit:export',
  'warehouse:export',
  'settlement_method:export',
  'color:status',
  'unit:status',
  'currency:status',
  'account:status',
  'warehouse:status',
};

class _QuietMaintenance extends ServerMaintenanceController {
  _QuietMaintenance({required super.read, required super.ready});
  @override
  Future<void> checkNow() async {}
}

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

class _CategorySession extends _Session {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'synthetic-print',
      code: 'SYNTHETIC',
      name: '合成分类查看员',
      permissions: [..._permissions, Perm.mouldCategoryView],
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
          if (platformHost && path == '/platform-columns/scopes') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: [
                  {
                    'scope': 'master_mould',
                    'priceVisible': true,
                    'supportsValues': true,
                  },
                ],
              ),
            );
            return;
          }
          if (platformHost &&
              path == '/platform-columns/master_mould/values:batch') {
            await holdPlatform?.future;
            final ids = (request.data as Map)['recordIds'] as List;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: [
                  for (final id in ids)
                    {
                      'recordId': id,
                      'version': 1,
                      'canWrite': false,
                      'cells': <Object>[],
                    },
                ],
              ),
            );
            return;
          }
          if (request.method == 'GET' && path == '/report-export-jobs') {
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: recentJobs,
              ),
            );
            return;
          }
          if (request.method == 'GET' &&
              recentJobs.any(
                (job) => path == '/report-export-jobs/${job['id']}',
              )) {
            jobReads.add(path);
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: recentJobs.firstWhere(
                  (job) => path.endsWith('/${job['id']}'),
                ),
              ),
            );
            return;
          }
          if (request.method == 'PATCH' && path.endsWith('/status')) {
            writes++;
            final id = path.split('/').reversed.skip(1).first;
            for (final row in rows.where((row) => row['id'] == id)) {
              row['status'] = (request.data as Map)['status'];
              row['version'] = (row['version'] as int) + 1;
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: <String, dynamic>{},
              ),
            );
            return;
          }
          if (request.method == 'POST' && path.endsWith('/batch-status')) {
            writes++;
            final items = (request.data as Map)['items'] as List;
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'succeeded': items.length,
                  'failed': 0,
                  'results': [
                    for (final item in items)
                      {'id': (item as Map)['id'], 'ok': true},
                  ],
                },
              ),
            );
            return;
          }
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
          if (forbidden &&
              (path == root ||
                  path == '$root/search' ||
                  path == '$root/page' ||
                  path == '$root/dict')) {
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.badResponse,
                response: Response<dynamic>(
                  requestOptions: request,
                  statusCode: 403,
                  data: {'code': 'FORBIDDEN', 'message': '合成服务端权限已收回'},
                ),
              ),
            );
            return;
          }
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
            if (domain == 'warehouses' && failContinuation) {
              handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.connectionTimeout,
                ),
              );
              return;
            }
            value = rows;
          } else if (request.method == 'GET' &&
              path.startsWith('$root/') &&
              rows.any((row) => path.endsWith('/${row['id']}'))) {
            value = rows.firstWhere((row) => path.endsWith('/${row['id']}'));
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
  bool platformHost = false;
  bool categoryPermissions = false;
  Completer<void>? holdPlatform;
  bool forbidden = false;
  int writes = 0;
  final recentJobs = <Map<String, dynamic>>[];
  final jobReads = <String>[];
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
    if (fixture.forbidden) {
      throw ApiException('FORBIDDEN', '合成服务端权限已收回', httpStatus: 403);
    }
    var offset = 0;
    while (offset < fixture.rows.length) {
      if (offset > 0) {
        if (fixture.failContinuation) {
          throw TimeoutException('continuation failed');
        }
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

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Fixture fixture, {
  bool realHost = false,
  bool fullApp = false,
}) async {
  await setUtenTestSurfaceSize(tester, const Size(1280, 720));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  FlutterSecureStorage.setMockInitialValues({});
  final router = fullApp
      ? GoRouter(
          navigatorKey: appNavigatorKey,
          initialLocation: '/basicinfo/mould',
          routes: [
            ShellRoute(
              builder: (_, _, child) => BusinessWindowHost(
                child: MainShellPage(
                  reminderBuilder: ServerUpdatePopupGate.new,
                  child: child,
                ),
              ),
              routes: [
                GoRoute(
                  path: '/basicinfo/mould',
                  builder: (_, _) => _page(fixture.domain),
                ),
              ],
            ),
          ],
        )
      : null;
  final connection = fullApp
      ? ConnectionRecoveryController(probe: () async => true)
      : null;
  final maintenance = fullApp
      ? _QuietMaintenance(
          read: () async => ServerMaintenanceSnapshot(
            phase: ServerMaintenancePhase.available,
            serverTime: DateTime.utc(2026, 11, 10),
          ),
          ready: () async => true,
        )
      : null;
  if (fullApp) {
    addTearDown(() {
      router!.dispose();
      maintenance!.dispose();
    });
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (fullApp) ...[
          appRouterProvider.overrideWithValue(router!),
          apiBaseUrlProvider.overrideWithValue('https://synthetic.invalid/api'),
          connectionRecoveryProvider.overrideWith((ref) => connection!),
          serverMaintenanceControllerProvider.overrideWithValue(maintenance!),
          platformWindowTitleSyncProvider.overrideWith((ref) {}),
          platformBrandingSnapshotProvider.overrideWithValue(
            PlatformBranding.defaults,
          ),
        ],
        sessionProvider.overrideWith(
          fixture.categoryPermissions ? _CategorySession.new : _Session.new,
        ),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'synthetic-print'),
        ),
        currentPermissionsProvider.overrideWithValue(
          fixture.categoryPermissions
              ? {..._permissions, Perm.mouldCategoryView}
              : _permissions,
        ),
        isSuperAdminProvider.overrideWithValue(false),
        apiClientProvider.overrideWithValue(fixture.api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
      ],
      child: fullApp
          ? const UtenApp()
          : MaterialApp(
              theme: realHost
                  ? buildLightTheme().copyWith(platform: TargetPlatform.windows)
                  : null,
              builder: realHost
                  ? (_, child) => PlatformTablesHost(
                      child: UtenDisplayZoomBox(
                        fontFactor: 1,
                        child: UtenControlTheme(
                          child: Column(children: [Expanded(child: child!)]),
                        ),
                      ),
                    )
                  : null,
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
  await pumpAndSettleWithIo(tester);
  return ProviderScope.containerOf(
    tester.element(find.byType(_page(fixture.domain).runtimeType)),
  );
}

void main() {
  for (final semanticsTiming in ['mount', 'beforeMenu']) {
    for (final semantics in [false, true]) {
      for (final hover in [false, true]) {
        testWidgets(
          'full App wide narrow actual ellipsis scheduler hover=$hover semantics=$semantics timing=$semanticsTiming',
          (tester) async {
            var semanticsHandle = semantics && semanticsTiming == 'mount'
                ? tester.ensureSemantics()
                : null;
            final priorTarget = debugDefaultTargetPlatformOverride;
            debugDefaultTargetPlatformOverride = TargetPlatform.windows;
            var phase = 'mount';
            final originalError = FlutterError.onError;
            FlutterError.onError = (details) {
              debugPrintSynchronously(
                'MENU-FIRST-ERROR phase=$phase library=${details.library} context=${details.context}',
              );
              debugPrintSynchronously(details.exceptionAsString());
              debugPrintSynchronously(details.stack.toString());
              originalError?.call(details);
            };
            try {
              final fixture = _Fixture('moulds', total: 1626)
                ..platformHost = true
                ..categoryPermissions = true;
              await _pump(tester, fixture, realHost: true, fullApp: true);
              final mouse = await tester.createGesture(
                kind: PointerDeviceKind.mouse,
              );
              await mouse.addPointer(location: const Offset(2, 2));
              addTearDown(mouse.removePointer);
              final category = find.text('全部模具').first;
              await mouse.moveTo(tester.getCenter(category));
              await mouse.down(tester.getCenter(category));
              await mouse.up();
              await pumpAndSettleWithIo(tester);
              if (hover) {
                phase = 'tree-tooltip-wide';
                await mouse.moveTo(tester.getCenter(find.text('全部模具').first));
                await pumpWithIo(tester, const Duration(milliseconds: 900));
                await pumpAndSettleWithIo(tester);
              }
              phase = 'shrink714';
              await setUtenTestSurfaceSize(tester, const Size(714, 764));
              await pumpAndSettleWithIo(tester);
              expect(
                tester.takeException(),
                isNull,
                reason: 'the repaired first shrink must remain clean',
              );
              final trigger = find.byTooltip('表格操作').hitTestable();
              expect(trigger, findsOneWidget);
              if (hover) {
                phase = 'menu-tooltip';
                await mouse.moveTo(tester.getCenter(trigger));
                await pumpWithIo(tester, const Duration(milliseconds: 900));
                await pumpAndSettleWithIo(tester);
              }
              if (semantics && semanticsTiming == 'beforeMenu') {
                phase = 'enable-semantics-narrow';
                semanticsHandle = tester.ensureSemantics();
                await pumpWithIo(tester);
              }
              if (semantics) {
                expect(SemanticsBinding.instance.semanticsEnabled, isTrue);
              }
              debugPrintSynchronously(
                'MENU-SEMANTICS requested=$semantics actual=${SemanticsBinding.instance.semanticsEnabled} timing=$semanticsTiming',
              );
              phase = 'open-actual-ellipsis';
              await mouse.moveTo(tester.getCenter(trigger));
              await mouse.down(tester.getCenter(trigger));
              await mouse.up();
              await pumpAndSettleWithIo(tester);
              expect(find.text('导出模具').hitTestable(), findsOneWidget);
              expect(find.text('预览打印').hitTestable(), findsOneWidget);
              expect(tester.takeException(), isNull);
              phase = 'escape';
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await pumpAndSettleWithIo(tester);
              phase = 'restore-wide';
              await setUtenTestSurfaceSize(tester, const Size(1280, 900));
              await pumpAndSettleWithIo(tester);
              expect(tester.takeException(), isNull);
              expect(fixture.exports, isEmpty);
              phase = 'dispose';
              await tester.pumpWidget(const SizedBox());
              await pumpAndSettleWithIo(tester);
            } finally {
              semanticsHandle?.dispose();
              debugDefaultTargetPlatformOverride = priorTarget;
              FlutterError.onError = originalError;
            }
          },
        );
      }
    }
  }
}
