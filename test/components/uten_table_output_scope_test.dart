import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/feedback/uten_dialog_modules.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/data_display/uten_table_output_scope.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../support/dialog_fixture_capture.dart';

class _Api extends ApiClient {
  _Api({this.selectionVersion = 1, this.jobsAvailable = false}) : super(Dio());
  final int? selectionVersion;
  final bool jobsAvailable;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {
    'available': jobsAvailable,
    if (selectionVersion != null) 'selectionVersion': selectionVersion,
  };
  final bodies = <Map<String, dynamic>>[];
  final queries = <Map<String, dynamic>>[];
  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    bodies.add(Map<String, dynamic>.from(body! as Map));
    queries.add({...?query});
    throw StateError('capture only');
  }
}

Widget _app(_Api api, Widget child, {double scale = 1}) =>
    dialogFixtureBoundary(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'output-reader'),
          ),
          apiBaseUrlProvider.overrideWithValue('https://fixture.invalid'),
          currentPermissionsProvider.overrideWithValue(const {}),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: child,
        ),
      ),
    );

class _OutputPaths extends PathProviderPlatform {
  @override
  Future<String?> getDownloadsPath() async => r'C:\Output';
  @override
  Future<String?> getApplicationDocumentsPath() async => r'C:\Output';
}

void main() {
  setUpAll(loadDialogFixtureFonts);

  for (final jobs in [false, true]) {
    testWidgets(
      'old server cannot expand selected output to all rows with jobs=$jobs',
      (tester) async {
        final api = _Api(selectionVersion: null, jobsAvailable: jobs);
        await tester.pumpWidget(
          _app(
            api,
            const Scaffold(
              body: UtenExportButton(
                endpoint: '/master/moulds/export',
                report: '',
                queryParams: {},
                selectedIds: {'mould-a'},
              ),
            ),
          ),
        );
        await tester.tap(find.bySemanticsLabel('下载表格'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('table-output-selected')));
        await tester.tap(find.text('直接下载'));
        await tester.pumpAndSettle();
        expect(api.bodies, isEmpty);
        final owner = ProviderScope.containerOf(
          tester.element(find.byType(UtenExportButton)),
        );
        expect(
          owner.read(appNotificationProvider).map((notice) => notice.message),
          contains(contains('尚未支持选中范围输出')),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('old server keeps its all-row synchronous compatibility', (
    tester,
  ) async {
    final api = _Api(selectionVersion: null);
    await tester.pumpWidget(
      _app(
        api,
        const Scaffold(
          body: UtenExportButton(
            endpoint: '/master/moulds/export',
            report: '',
            queryParams: {},
            selectedIds: {'mould-a'},
          ),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('下载表格'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('直接下载'));
    await tester.pumpAndSettle();
    expect(api.bodies, hasLength(1));
    expect(api.bodies.single, isNot(contains('selectedIds')));
  });

  testWidgets(
    'large desktop preserves the original export controls and expands without vertical scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1080);
      tester.view.devicePixelRatio = 1;
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _OutputPaths();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDefaultTargetPlatformOverride = null;
        PathProviderPlatform.instance = oldPaths;
      });
      await tester.pumpWidget(
        _app(
          _Api(),
          const Scaffold(
            body: UtenExportButton(
              endpoint: '/master/moulds/export',
              report: '',
              queryParams: {},
              filename: '模具盘点清单',
              selectedIds: {'a', 'b'},
            ),
          ),
        ),
      );
      await tester.tap(find.bySemanticsLabel('下载表格'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenDialogSettingTile), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('仅已选（2 项）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('table-output-selected')));
      await tester.tap(find.text('设置密码'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate((w) => w is TextField && w.obscureText),
        'sample',
      );
      await tester.pumpAndSettle();
      for (final element
          in find
              .descendant(
                of: find.byType(UtenAlertDialog),
                matching: find.byType(Scrollable),
              )
              .evaluate()) {
        final state = (element as StatefulElement).state as ScrollableState;
        if (axisDirectionToAxis(state.position.axisDirection) ==
            Axis.vertical) {
          expect(state.position.maxScrollExtent, lessThanOrEqualTo(0.1));
        }
      }
      expect(tester.getRect(find.text('加密下载')).bottom, lessThan(1080));
      if (dialogFixtureCaptureEnabled) {
        await captureDialogFixture(
          tester,
          'export-original-style-desktop-expanded',
          outputDirectory: 'output/table-output-import-trace-20261105',
        );
      }
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'output-only report checkboxes feed an exact selected download and retain all filters',
    (tester) async {
      final api = _Api();
      final controller = TableColumnProjectionController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          api,
          TableColumnProjectionScope(
            controller: controller,
            child: Scaffold(
              body: MasterDataTableView<Map<String, dynamic>>(
                tableKey: 'output-fixture',
                items: const [
                  {'id': 'a', 'name': '货品甲'},
                  {
                    'id': 'b',
                    'name': '货品乙',
                    'amount': 90071992547409.0,
                    'amountExact': '90071992547409.0001',
                  },
                ],
                columns: [
                  MasterColumnDef(
                    key: 'name',
                    label: '货品名称',
                    width: 180,
                    value: (row) => row['name'] as String,
                  ),
                  MasterColumnDef(
                    key: 'amount',
                    label: '参考金额',
                    width: 180,
                    type: 'money',
                    value: (row) => row['amountExact']?.toString(),
                  ),
                ],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                toolbarActions: const [
                  UtenExportButton(
                    endpoint: '/fixture/export',
                    report: 'detail',
                    queryParams: {'keyword': '当前搜索'},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(3));
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('下载表格'));
      await tester.pumpAndSettle();
      expect(find.text('仅已选（1 项）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('table-output-selected')));
      await tester.pumpAndSettle();
      if (dialogFixtureCaptureEnabled) {
        await captureDialogFixture(
          tester,
          'output-scope-selected',
          outputDirectory: 'output/table-output-import-trace-20261105',
        );
      }
      await tester.tap(find.text('直接下载'));
      await tester.pumpAndSettle();
      expect(api.bodies, hasLength(1));
      expect(api.queries.single['keyword'], '当前搜索');
      expect((api.bodies.single['columnProjection'] as Map)['rowSelection'], [
        {'id': 'b', 'name': '货品乙', 'amount': '90071992547409.0001'},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty selection stays disabled and cancel makes no output request at narrow 200 percent',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _Api();
      await tester.pumpWidget(
        _app(
          api,
          const Scaffold(
            body: UtenExportButton(
              endpoint: '/fixture/export',
              report: '',
              queryParams: {},
            ),
          ),
          scale: 2,
        ),
      );
      await tester.tap(find.bySemanticsLabel('下载表格'));
      await tester.pumpAndSettle();
      expect(find.text('仅已选（0 项）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('table-output-selected')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('table-output-all')), findsOneWidget);
      if (dialogFixtureCaptureEnabled) {
        await captureDialogFixture(
          tester,
          'output-scope-narrow-large-text',
          outputDirectory: 'output/table-output-import-trace-20261105',
        );
      }
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(api.bodies, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelling print preparation closes its one busy overlay and discards late rows',
    (tester) async {
      final result = Completer<UtenPrintTable>();
      await tester.pumpWidget(
        _app(
          _Api(),
          Scaffold(
            body: UtenPrintPreviewButton(
              title: '打印测试',
              loader: () => result.future,
            ),
          ),
        ),
      );
      await tester.tap(find.bySemanticsLabel('预览打印'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-output-all')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      for (
        var frame = 0;
        frame < 12 && find.text('取消读取').evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.tap(find.text('取消读取'));
      await tester.pumpAndSettle();
      result.complete(
        const UtenPrintTable(
          headers: ['名称'],
          rows: [
            ['不得复活的旧结果'],
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.text('不得复活的旧结果'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'nullable selectors share one schema and opaque checkbox tokens use server record IDs for paper',
    () async {
      final rows = await rectangularUtenOutputRows([
        {'id': 'a'},
        {'id': 'b', 'colorId': 'c'},
      ], isCurrent: () => true);
      expect(rows, [
        {'id': 'a', 'colorId': null},
        {'id': 'b', 'colorId': 'c'},
      ]);
      final paper = await selectUtenPrintRows(
        const UtenPrintTable(
          headers: ['名称'],
          rows: [
            ['a'],
            ['b'],
          ],
          rowIds: ['a', 'b'],
        ),
        const UtenTableOutputSelection(
          ids: {'opaque-token'},
          rows: [
            {'@id': 'b'},
          ],
        ),
      );
      expect(paper.rows, [
        ['b'],
      ]);
    },
  );

  test(
    'selected print keeps the final row beyond the old 2000 prefix and rejects stale IDs',
    () async {
      final table = UtenPrintTable(
        headers: const ['名称'],
        columnKeys: const ['name'],
        rows: List.generate(50000, (i) => ['货品$i']),
        rowIds: List.generate(50000, (i) => 'id-$i'),
      );
      final selected = await selectUtenPrintRows(
        table,
        const UtenTableOutputSelection(ids: {'id-0', 'id-49999'}),
      );
      expect(selected.rows, [
        ['货品0'],
        ['货品49999'],
      ]);
      await expectLater(
        selectUtenPrintRows(
          table,
          const UtenTableOutputSelection(ids: {'id-49999', 'removed'}),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'grouped report print uses raw facts when document IDs repeat and fails ambiguous rows',
    () async {
      const selection = UtenTableOutputSelection(
        ids: {'selected-row'},
        rows: [
          {'doc': 'same', 'value': 'B'},
        ],
      );
      const table = UtenPrintTable(
        headers: ['值'],
        columnKeys: ['value'],
        rows: [
          ['A'],
          ['B'],
        ],
        rowIds: ['same', 'same'],
        factValues: [
          {'doc': 'same', 'value': 'A'},
          {'doc': 'same', 'value': 'B'},
        ],
      );
      expect((await selectUtenPrintRows(table, selection)).rows, [
        ['B'],
      ]);
      await expectLater(
        selectUtenPrintRows(
          const UtenPrintTable(
            headers: ['值'],
            rows: [
              ['B'],
              ['B'],
            ],
            factValues: [
              {'doc': 'same', 'value': 'B'},
              {'doc': 'same', 'value': 'B'},
            ],
          ),
          selection,
        ),
        throwsFormatException,
      );
    },
  );
}
