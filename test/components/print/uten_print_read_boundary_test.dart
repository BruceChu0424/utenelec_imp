import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

final _boundary = NotifierProvider<_Boundary, SensitiveReadBoundary>(
  _Boundary.new,
);

class _Boundary extends Notifier<SensitiveReadBoundary> {
  @override
  SensitiveReadBoundary build() => SensitiveReadBoundary(
    identity: const AuthenticatedScope(userId: 'a'),
    api: ApiClient(Dio()),
    permissions: const {Perm.stockView, Perm.stockReportExport},
    superAdmin: false,
  );

  void replace(SensitiveReadBoundary value) => state = value;
}

const _table = UtenPrintTable(
  columnKeys: ['qty'],
  headers: ['数量'],
  rows: [
    ['旧账号库存'],
  ],
  factValues: [
    {'qty': '7'},
  ],
);

const _invalidated = '账号、服务器或权限已变化，请关闭后重新预览';

class _DelayedProjection extends PlatformTableRepository {
  _DelayedProjection() : super(ApiClient(Dio()));

  final ready = Completer<List<PlatformTableCapabilities>>();
  bool requested = false;

  @override
  Future<List<PlatformTableCapabilities>> scopes() {
    requested = true;
    return ready.future;
  }

  @override
  Future<List<PlatformColumnDefinition>> search(
    String scope,
    String query, {
    List<String>? ids,
  }) async => const [
    PlatformColumnDefinition(
      id: 'calc',
      scope: 'view_warehouse',
      name: '库存计算列',
      type: 'CALCULATED',
      formula: PlatformFormula(base: PlatformFormulaOperand(fact: 'qty')),
    ),
  ];
}

Future<ProviderContainer> _open(
  WidgetTester tester, {
  Future<UtenPrintTable> Function()? loader,
  _DelayedProjection? repository,
}) async {
  final projection = TableColumnProjectionController();
  addTearDown(projection.dispose);
  final container = ProviderContainer(
    overrides: [
      sensitiveReadBoundaryProvider.overrideWith((ref) => ref.watch(_boundary)),
      authenticatedScopeProvider.overrideWith(
        (ref) => ref.watch(_boundary).identity,
      ),
      apiBaseUrlProvider.overrideWithValue('https://test.invalid'),
      apiClientProvider.overrideWith((ref) => ref.watch(_boundary).api),
      currentPermissionsProvider.overrideWithValue(const {
        Perm.stockView,
        Perm.stockReportExport,
      }),
      if (repository != null)
        platformTableRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);
  var published = false;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TableColumnProjectionScope(
        controller: projection,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              if (repository != null && !published) {
                published = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  projection.publish(
                    Object(),
                    const TableColumnProjection(
                      tableKey: 'inventory',
                      scope: 'view_warehouse',
                      columns: [
                        TableProjectedColumn(
                          key: 'platform:calc',
                          label: '库存计算列',
                          width: 120,
                          type: 'number',
                        ),
                      ],
                    ),
                    contextOwner: ModalRoute.of(context),
                  );
                });
              }
              return Scaffold(
                body: UtenPrintPreviewButton(
                  title: '库存报表',
                  tableKey: repository == null ? null : 'inventory',
                  loader: loader ?? () async => _table,
                  exportEndpoint: '/stock/reports/export',
                  exportReport: 'instant-inventory',
                  exportPermission: Perm.stockReportExport,
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('预览打印'));
  await tester.pump();
  return container;
}

UtenButton _printButton(WidgetTester tester) =>
    tester.widget<UtenButton>(find.widgetWithText(UtenButton, '打印'));

void main() {
  testWidgets(
    'a data-scope revision permanently retires an already loaded paper even after ABA',
    (tester) async {
      final container = await _open(tester);
      await tester.pumpAndSettle();
      expect(find.text('旧账号库存'), findsOneWidget);
      container.read(readScopeRevisionProvider.notifier).state = 1;
      await tester.pump();
      container.read(readScopeRevisionProvider.notifier).state = 0;
      await tester.pump();
      expect(find.text('旧账号库存'), findsNothing);
      expect(find.text(_invalidated), findsOneWidget);
      expect(_printButton(tester).onPressed, isNull);
    },
  );
  for (final change in ['permissions', 'identity', 'server']) {
    testWidgets('loaded preview is cleared permanently after $change changes', (
      tester,
    ) async {
      final container = await _open(tester);
      await tester.pumpAndSettle();
      expect(find.text('旧账号库存'), findsOneWidget);
      expect(_printButton(tester).onPressed, isNotNull);
      final export = tester.widget<UtenExportButton>(
        find.byType(UtenExportButton),
      );
      final selection = await export.prepareExport!();
      final original = container.read(_boundary);
      container
          .read(_boundary.notifier)
          .replace(
            SensitiveReadBoundary(
              identity: change == 'identity'
                  ? const AuthenticatedScope(userId: 'b')
                  : original.identity,
              api: change == 'server' ? ApiClient(Dio()) : original.api,
              permissions: change == 'permissions'
                  ? const {}
                  : original.permissions,
              superAdmin: false,
            ),
          );
      await tester.pumpAndSettle();
      expect(find.text('旧账号库存'), findsNothing);
      expect(find.text(_invalidated), findsOneWidget);
      expect(_printButton(tester).onPressed, isNull);
      expect(
        tester.widget<UtenExportButton>(find.byType(UtenExportButton)).enabled,
        isFalse,
      );
      expect(selection!.stillCurrent!(), isFalse);
      container.read(_boundary.notifier).replace(original);
      await tester.pumpAndSettle();
      expect(find.text('旧账号库存'), findsNothing);
      expect(_printButton(tester).onPressed, isNull);
      await tester.tap(find.byTooltip(RegExp(r'^(关闭|Close|닫기)$')));
      await tester.pumpAndSettle();
      container
          .read(_boundary.notifier)
          .replace(
            SensitiveReadBoundary(
              identity: null,
              api: original.api,
              permissions: const {},
              superAdmin: false,
            ),
          );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an old loader cannot revive after account A to B to A', (
    tester,
  ) async {
    final ready = Completer<UtenPrintTable>();
    final container = await _open(tester, loader: () => ready.future);
    final original = container.read(_boundary);
    container
        .read(_boundary.notifier)
        .replace(
          SensitiveReadBoundary(
            identity: const AuthenticatedScope(userId: 'b'),
            api: original.api,
            permissions: original.permissions,
            superAdmin: false,
          ),
        );
    await tester.pump();
    container.read(_boundary.notifier).replace(original);
    await tester.pump();
    ready.complete(_table);
    await tester.pumpAndSettle();
    expect(find.text(_invalidated), findsOneWidget);
    expect(find.text('旧账号库存'), findsNothing);
    expect(_printButton(tester).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late column projection cannot restore a revoked preview', (
    tester,
  ) async {
    final repository = _DelayedProjection();
    final container = await _open(tester, repository: repository);
    await tester.pump();
    expect(repository.requested, isTrue);
    final original = container.read(_boundary);
    container
        .read(_boundary.notifier)
        .replace(
          SensitiveReadBoundary(
            identity: original.identity,
            api: original.api,
            permissions: const {},
            superAdmin: false,
          ),
        );
    await tester.pump();
    repository.ready.complete(const [
      PlatformTableCapabilities(
        scope: 'view_warehouse',
        facts: [PlatformTableFact(key: 'qty', name: '数量')],
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text(_invalidated), findsOneWidget);
    expect(find.text('库存计算列'), findsNothing);
    expect(find.text('7'), findsNothing);
    expect(_printButton(tester).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission change during font loading never dispatches a PDF', (
    tester,
  ) async {
    final container = await _open(tester);
    await tester.pumpAndSettle();
    final font = Completer<ByteData?>();
    var requested = false;
    var prints = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMessageHandler('flutter/assets', (message) {
      final asset = utf8.decode(message!.buffer.asUint8List());
      if (asset == 'assets/fonts/NotoSansSCFull.ttf') {
        requested = true;
        return font.future;
      }
      return Future.value();
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('net.nfet.printing'),
      (call) async {
        prints++;
        return true;
      },
    );
    addTearDown(() {
      messenger.setMockMessageHandler('flutter/assets', null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('net.nfet.printing'),
        null,
      );
    });
    await tester.tap(find.widgetWithText(UtenButton, '打印'));
    await tester.pump();
    expect(requested, isTrue);
    expect(_printButton(tester).isLoading, isTrue);
    final original = container.read(_boundary);
    container
        .read(_boundary.notifier)
        .replace(
          SensitiveReadBoundary(
            identity: original.identity,
            api: original.api,
            permissions: const {},
            superAdmin: false,
          ),
        );
    await tester.pump();
    // Invalid bytes must never even reach PDF parsing after this boundary changes.
    font.complete(ByteData(1));
    await tester.pumpAndSettle();
    expect(prints, 0);
    expect(find.text(_invalidated), findsOneWidget);
    expect(find.text('生成打印件失败，请稍后重试'), findsNothing);
    expect(_printButton(tester).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('standalone previews still work without a ProviderScope', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenPrintPreviewButton(
            title: '独立报表',
            loader: () async => _table,
          ),
        ),
      ),
    );
    await tester.tap(find.text('预览打印'));
    await tester.pumpAndSettle();
    expect(find.text('旧账号库存'), findsOneWidget);
    expect(_printButton(tester).onPressed, isNotNull);
    await tester.tap(find.byTooltip(RegExp(r'^(关闭|Close|닫기)$')));
    await tester.pumpAndSettle();
    expect(find.text('预览 · 独立报表'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
