import 'package:uten_imp/core/router/permission_by_path.dart';
import '../../support/audit_screenshot_support.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/history/record_history_action.dart';
import 'package:uten_imp/shared/history/record_history_area.dart';
import 'package:uten_imp/shared/history/record_history_page.dart';
import 'package:uten_imp/shared/history/record_history_repository.dart'
    as history;
import 'package:uten_imp/shared/history/record_revision_page.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

final _grants = StateProvider<Set<String>>((_) => {'company_file:view'});
final _admin = StateProvider<bool>((_) => false);

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot(generation: 1);
}

Map<String, Object?> _entry(RecordHistoryArea area) => {
  'id': '1',
  'entityType': area == RecordHistoryArea.companyFiles ? 'files' : 'users',
  'recordId': 'record-1',
  'recordLabel': area == RecordHistoryArea.companyFiles
      ? '产品装配说明.pdf'
      : '张师傅（000123）',
  'recordName': area == RecordHistoryArea.companyFiles
      ? '产品装配说明.pdf'
      : '张师傅（000123）',
  'action': 'EDIT',
  'actorName': '王经理（000015）',
  'recordedAt': '2026-11-01T03:30:00Z',
  'sourceType': area == RecordHistoryArea.companyFiles ? 'RECORD' : 'ACCESS',
  'summary': area == RecordHistoryArea.companyFiles
      ? '名称、说明'
      : '授予 · 查看货品资料（goods:view）',
  'affectedCount': 1,
  'canRestoreBefore': false,
  'canRestoreAfter': false,
  'blockedReason': '历史仅供核对；调整请通过当前业务流程保存。',
  'changes': [
    {
      'label': area == RecordHistoryArea.companyFiles
          ? '名称'
          : '查看货品资料（goods:view）',
      'beforeValue': area == RecordHistoryArea.companyFiles
          ? '装配说明初稿.pdf'
          : '未配置',
      'afterValue': area == RecordHistoryArea.companyFiles
          ? '产品装配说明.pdf'
          : '已配置',
    },
  ],
};

class _Api {
  final RecordHistoryArea area;
  _Api(this.area);
  final requests = <RequestOptions>[];
  Completer<Map<String, Object?>>? pending;
  bool fail = false;
  bool hideEntries = false;
  String? nextCursor;
  late final api = () {
    final dio = Dio(BaseOptions(baseUrl: 'https://history.invalid/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) async {
          requests.add(request);
          if (fail) {
            handler.reject(
              DioException(
                requestOptions: request,
                response: Response(
                  requestOptions: request,
                  statusCode: 503,
                  data: {'message': '稍后重试'},
                ),
              ),
            );
            return;
          }
          final data = request.path == area.apiPath
              ? await (pending?.future ??
                    Future.value({
                      'entries': hideEntries
                          ? <Map<String, Object?>>[]
                          : [
                              {
                                ..._entry(area),
                                if (request.queryParameters['cursor'] != null)
                                  'recordLabel': '第二页文件.pdf',
                                if (request.queryParameters['cursor'] != null)
                                  'recordName': '第二页文件.pdf',
                              },
                            ],
                      'nextCursor': request.queryParameters['cursor'] == null
                          ? nextCursor
                          : null,
                    }))
              : _entry(area);
          handler.resolve(
            Response(requestOptions: request, statusCode: 200, data: data),
          );
        },
      ),
    );
    return ApiClient(dio);
  }();
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Api api, {
  bool admin = false,
  Set<String>? grants,
  Size size = const Size(1400, 900),
  bool dark = false,
  double scale = 1,
  bool pending = false,
  bool startAtOwner = false,
}) async {
  await loadAuditScreenshotFonts(tester);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final area = api.area;
  final router = GoRouter(
    initialLocation: startAtOwner ? area.parentPath : area.routePath,
    routes: [
      GoRoute(
        path: area.parentPath,
        builder: (_, _) => Scaffold(
          appBar: AppBar(actions: [RecordHistoryAction(area: area)]),
          body: const TextField(key: Key('owner-draft')),
        ),
      ),
      GoRoute(
        path: area.routePath,
        builder: (_, _) => RecordHistoryPage(area: area),
      ),
      GoRoute(
        path: '${area.routePath}/:entityType/:id',
        builder: (_, state) => RecordRevisionPage(
          area: area,
          entityType: state.pathParameters['entityType']!,
          id: state.pathParameters['id']!,
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        _grants.overrideWith((_) => grants ?? {'company_file:view'}),
        _admin.overrideWith((_) => admin),
        currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
        isSuperAdminProvider.overrideWith((ref) => ref.watch(_admin)),
        authenticatedScopeProvider.overrideWith(
          (_) => const AuthenticatedScope(userId: 'history-reader'),
        ),
        apiBaseUrlProvider.overrideWithValue('https://history.invalid/api'),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        history.masterRecordHistoryRepositoryProvider.overrideWithValue(
          history.MasterRecordHistoryRepository(api.api),
        ),
      ],
      child: RepaintBoundary(
        key: const Key('preview'),
        child: MaterialApp.router(
          routerConfig: router,
          theme: auditScreenshotTheme(
            dark ? buildDarkTheme() : buildLightTheme(),
          ),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
      ),
    ),
  );
  if (pending) {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  } else {
    await tester.pumpAndSettle();
  }
  return ProviderScope.containerOf(
    tester.element(find.byKey(const Key('preview'))),
  );
}

Future<void> _screenshot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('preview')),
    );
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final directory = Directory('build/history-previews');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  testWidgets(
    'company history revalidates local ACL when returning from a detail',
    (tester) async {
      final api = _Api(RecordHistoryArea.companyFiles);
      await _pump(tester, api);
      final row = find.text('产品装配说明.pdf').first;
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(row);
      await tester.pumpAndSettle();
      api.hideEntries = true;
      await tester.tap(find.byType(UtenBackButton));
      await tester.pumpAndSettle();
      expect(find.text('产品装配说明.pdf'), findsNothing);
      expect(
        api.requests.where((r) => r.path == api.area.apiPath),
        hasLength(2),
      );
    },
  );
  testWidgets(
    'company history revisiting a page rechecks object ACL instead of replaying cached rows',
    (tester) async {
      final api = _Api(RecordHistoryArea.companyFiles)
        ..nextCursor = 'opaque-next';
      await _pump(tester, api);
      await tester.tap(find.byKey(const ValueKey('master-table-page-next')));
      await tester.pumpAndSettle();
      expect(find.text('第二页文件.pdf'), findsOneWidget);
      api.hideEntries = true;
      await tester.tap(
        find.byKey(const ValueKey('master-table-page-previous')),
      );
      await tester.pumpAndSettle();
      expect(find.text('产品装配说明.pdf'), findsNothing);
      expect(
        api.requests.where(
          (r) =>
              r.path == api.area.apiPath && r.queryParameters['cursor'] == null,
        ),
        hasLength(2),
      );
    },
  );
  test(
    'history list and deep-link routes require their owning module permission',
    () {
      for (final suffix in ['', '/files/1', '?recordId=private-record']) {
        expect(requiredAnyPermFor('/company-files/history$suffix'), [
          'company_file:view',
        ]);
        expect(requiredAnyPermFor('/admin/permissions/history$suffix'), [
          'authorization:manage',
        ]);
      }
    },
  );
  for (final area in [
    RecordHistoryArea.companyFiles,
    RecordHistoryArea.permissions,
  ]) {
    testWidgets(
      '${area.name} history entrance and back preserve the owner draft',
      (tester) async {
        final api = _Api(area);
        await _pump(
          tester,
          api,
          startAtOwner: true,
          admin: area == RecordHistoryArea.permissions,
          grants: {
            area == RecordHistoryArea.permissions
                ? 'authorization:manage'
                : 'company_file:view',
          },
        );
        await tester.enterText(find.byKey(const Key('owner-draft')), '尚未保存的修改');
        await tester.tap(find.text('修改历史'));
        await tester.pumpAndSettle();
        expect(find.byType(RecordHistoryPage), findsOneWidget);
        await tester.tap(find.byType(UtenBackButton));
        await tester.pumpAndSettle();
        expect(find.text('尚未保存的修改'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'permission detail clears protected fields when administrator access is revoked',
    (tester) async {
      final api = _Api(RecordHistoryArea.permissions);
      final container = await _pump(
        tester,
        api,
        admin: true,
        grants: {'authorization:manage'},
      );
      final row = find.text('张师傅（000123）').first;
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('未配置'), findsOneWidget);
      container.read(_admin.notifier).state = false;
      await tester.pumpAndSettle();
      expect(find.text('未配置'), findsNothing);
      expect(find.text('当前没有资料历史查看权限'), findsOneWidget);
    },
  );
  testWidgets(
    'company history uses scoped transport and shared list/detail without master-only columns',
    (tester) async {
      final api = _Api(RecordHistoryArea.companyFiles);
      await _pump(tester, api);
      expect(find.text('公司资料修改历史'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('master-column-filter-categoryName')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('master-column-filter-recordCode')),
        findsNothing,
      );
      expect(api.requests.first.path, RecordHistoryArea.companyFiles.apiPath);
      expect(
        api.requests.first.queryParameters.keys,
        containsAll(['dateFrom', 'dateTo', 'size']),
      );
      await _screenshot(tester, 'company-wide-list');
      await tester.tap(find.text('产品装配说明.pdf').first);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(find.text('产品装配说明.pdf').first);
      await tester.pumpAndSettle();
      expect(api.requests.last.path, '/company-files/record-history/1');
      expect(find.text('装配说明初稿.pdf'), findsOneWidget);
      expect(find.widgetWithText(UtenButton, '恢复到此次修改前'), findsNothing);
      expect(find.widgetWithText(UtenButton, '恢复到此次修改后'), findsNothing);
      await _screenshot(tester, 'company-wide-detail');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'permission history shares comparison and hides stale data immediately after privilege loss',
    (tester) async {
      final api = _Api(RecordHistoryArea.permissions);
      final container = await _pump(
        tester,
        api,
        admin: true,
        grants: {'authorization:manage'},
      );
      expect(find.text('张师傅（000123）'), findsOneWidget);
      await _screenshot(tester, 'permissions-wide-list');
      container.read(_admin.notifier).state = false;
      await tester.pumpAndSettle();
      expect(find.text('张师傅（000123）'), findsNothing);
      expect(find.text('当前没有资料历史查看权限'), findsOneWidget);
    },
  );
  testWidgets('late permission response cannot repopulate a revoked view', (
    tester,
  ) async {
    final api = _Api(RecordHistoryArea.permissions)..pending = Completer();
    final container = await _pump(
      tester,
      api,
      admin: true,
      grants: {'authorization:manage'},
      pending: true,
    );
    container.read(_grants.notifier).state = {};
    await tester.pump();
    api.pending!.complete({
      'entries': [_entry(api.area)],
      'nextCursor': null,
    });
    await tester.pumpAndSettle();
    expect(find.text('张师傅（000123）'), findsNothing);
  });
  for (final area in [
    RecordHistoryArea.companyFiles,
    RecordHistoryArea.permissions,
  ]) {
    testWidgets(
      '${area.name} dark narrow large-text list and detail remain usable',
      (tester) async {
        final api = _Api(area);
        await _pump(
          tester,
          api,
          admin: area == RecordHistoryArea.permissions,
          grants: {
            area == RecordHistoryArea.permissions
                ? 'authorization:manage'
                : 'company_file:view',
          },
          size: const Size(480, 900),
          scale: 1.5,
          dark: true,
        );
        await _screenshot(tester, '${area.name}-narrow-list');
        await tester.tap(
          find.text(_entry(area)['recordLabel']! as String).first,
        );
        await tester.pump(const Duration(milliseconds: 30));
        await tester.tap(
          find.text(_entry(area)['recordLabel']! as String).first,
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            area == RecordHistoryArea.companyFiles ? '装配说明初稿.pdf' : '未配置',
          ),
          findsOneWidget,
        );
        await _screenshot(tester, '${area.name}-narrow-detail');
        expect(tester.takeException(), isNull);
      },
    );
  }
  test('shared history entrance requires both authorization privileges', () {
    expect(
      RecordHistoryArea.permissions.canRead(false, {'authorization:manage'}),
      isFalse,
    );
    expect(RecordHistoryArea.permissions.canRead(true, {}), isFalse);
    expect(
      RecordHistoryArea.permissions.canRead(true, {'authorization:manage'}),
      isTrue,
    );
    expect(
      RecordHistoryArea.companyFiles.canRead(false, {'company_file:view'}),
      isTrue,
    );
  });
  testWidgets('account-support-only users have no permission history action', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPermissionsProvider.overrideWithValue({'account:support'}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: RecordHistoryAction(area: RecordHistoryArea.permissions),
          ),
        ),
      ),
    );
    expect(find.text('修改历史'), findsNothing);
  });
}
