import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_export_button.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../support/dialog_fixture_capture.dart';
import '../support/uten_test_actions.dart';

typedef _Row = Map<String, dynamic>;

const _tableKey = Key('table-output-identity-fixture');

class _OutputApi extends ApiClient {
  _OutputApi() : super(Dio());
  final bodies = <Map<String, dynamic>>[];
  final queries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {'available': false, 'selectionVersion': 1};

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    bodies.add(Map<String, dynamic>.from(body! as Map));
    queries.add({...?query});
    // Stop before any file picker or filesystem write, after the real export
    // control has frozen and sent its selected-output request.
    throw StateError('fixture captured selected output');
  }
}

/// Observes actual Element/State mounts, separately from cell-builder calls.
class _RowProbe extends StatefulWidget {
  const _RowProbe({
    super.key,
    required this.index,
    required this.name,
    required this.mounts,
  });
  final int index;
  final String name;
  final Map<int, int> mounts;

  @override
  State<_RowProbe> createState() => _RowProbeState();
}

class _RowProbeState extends State<_RowProbe> {
  @override
  void initState() {
    super.initState();
    widget.mounts.update(widget.index, (count) => count + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 32,
    child: Align(alignment: Alignment.centerLeft, child: Text(widget.name)),
  );
}

/// A JSON-shaped row whose key enumeration detects a full content-hash scan.
class _LineRow extends MapBase<String, dynamic> {
  _LineRow(String id, String name) : _data = {'__lineId': id, 'name': name};
  final Map<String, dynamic> _data;
  int keyEnumerations = 0;
  @override
  dynamic operator [](Object? key) => _data[key];
  @override
  void operator []=(String key, dynamic value) => _data[key] = value;
  @override
  Iterable<String> get keys {
    keyEnumerations++;
    return _data.keys;
  }

  @override
  void clear() => _data.clear();
  @override
  dynamic remove(Object? key) => _data.remove(key);
}

Future<void> _pumpTable(
  WidgetTester tester, {
  required _OutputApi api,
  required ValueNotifier<List<_Row>> source,
  required MasterDataTableRowsController<_Row> rows,
  required Map<int, int> mounts,
  bool explicitOutputSelection = false,
}) async {
  await setUtenTestSurfaceSize(tester, const Size(1100, 720));
  addTearDown(() => setUtenTestSurfaceSize(tester, null));
  final projection = TableColumnProjectionController();
  addTearDown(projection.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'output-identity-reader'),
        ),
        apiBaseUrlProvider.overrideWithValue('https://fixture.invalid'),
        currentPermissionsProvider.overrideWithValue(const {}),
      ],
      child: MaterialApp(
        theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TableColumnProjectionScope(
          controller: projection,
          child: Scaffold(
            body: ValueListenableBuilder<List<_Row>>(
              valueListenable: source,
              builder: (_, items, _) {
                final indexes = Map<_Row, int>.identity();
                for (var i = 0; i < items.length; i++) {
                  indexes[items[i]] = i;
                }
                return MasterDataTableView<_Row>(
                  key: _tableKey,
                  tableKey: 'output-identity',
                  items: items,
                  rowsController: rows,
                  // Leave primary/virtualized/idOf/rowKeyOf at their defaults:
                  // bounded anonymous rows must use the same public window.
                  expensiveRowMounts: false,
                  outputSelectionEnabled: explicitOutputSelection,
                  showColumnChooser: false,
                  showFullscreenToggle: false,
                  columns: [
                    MasterColumnDef<_Row>(
                      key: 'name',
                      label: 'Name',
                      width: 400,
                      value: (row) => row['name'] as String,
                      cellBuilder: (_, row) => _RowProbe(
                        key: ValueKey('output-probe:${indexes[row]}'),
                        index: indexes[row]!,
                        name: row['name'] as String,
                        mounts: mounts,
                      ),
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
                      queryParams: {'keyword': 'current-scope'},
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollController _body(WidgetTester tester) {
  final source = find.descendant(
    of: find.byKey(_tableKey),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is UtenPageScrollbarSource &&
          widget.debugLabel == 'master-table-body',
    ),
  );
  expect(source, findsOneWidget);
  expect(
    find.descendant(of: source, matching: find.byType(ListView)),
    findsOneWidget,
  );
  final controller = tester.widget<UtenPageScrollbarSource>(source).controller;
  expect(controller.hasClients, isTrue);
  expect(controller.positions, hasLength(1));
  expect(controller.position.axis, Axis.vertical);
  expect(controller.position.viewportDimension, greaterThan(0));
  expect(controller.position.maxScrollExtent, greaterThan(0));
  return controller;
}

Future<void> _downloadSelected(WidgetTester tester) async {
  await tapUtenTestAction(tester, find.bySemanticsLabel('下载表格'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('table-output-selected')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('直接下载'));
  await tester.pumpAndSettle();
}

Future<void> _selectText(WidgetTester tester, String text) async {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: find.text(text).last, matching: find.byType(RichText)),
  );
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
  );
  final start = paragraph.localToGlobal(
    Offset(boxes.first.left + .1, (boxes.first.top + boxes.first.bottom) / 2),
  );
  final end = paragraph.localToGlobal(
    Offset(boxes.last.right + 1, (boxes.last.top + boxes.last.bottom) / 2),
  );
  final mouse = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
  for (var i = 1; i <= 8; i++) {
    await mouse.moveTo(Offset.lerp(start, end, i / 8)!);
    await tester.pump(const Duration(milliseconds: 20));
  }
  await mouse.up();
  await tester.pumpAndSettle();
}

Future<void> _copy(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  String? clipboard;
  setUpAll(loadDialogFixtureFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'anonymous equal Maps retain every occurrence and mount distant rows directly with a real output toolbar',
    (tester) async {
      final source = ValueNotifier<List<_Row>>([
        for (var i = 0; i < 1000; i++)
          {'name': i < 3 ? 'Equal duplicate' : 'Line $i', 'amount': '1.0001'},
      ]);
      addTearDown(source.dispose);
      final rows = MasterDataTableRowsController<_Row>();
      final mounts = <int, int>{};
      final api = _OutputApi();
      await _pumpTable(
        tester,
        api: api,
        source: source,
        rows: rows,
        mounts: mounts,
      );
      expect(rows.items, hasLength(1000));
      expect(
        rows.items.where((row) => row['name'] == 'Equal duplicate'),
        hasLength(3),
      );
      for (var i = 0; i < 3; i++) {
        expect(find.byKey(ValueKey('output-probe:$i')), findsOneWidget);
        expect(
          tester.state(find.byKey(ValueKey('output-probe:$i'))),
          isA<_RowProbeState>(),
        );
      }
      expect(find.byType(UtenExportButton), findsOneWidget);
      expect(
        find.byType(Checkbox),
        findsWidgets,
        reason: 'the real output toolbar enables the public output selection',
      );
      expect(
        mounts.values.fold<int>(0, (sum, count) => sum + count),
        lessThan(160),
      );
      final body = _body(tester);
      body.position.jumpTo(body.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('output-probe:999')), findsOneWidget);
      expect(
        tester.state(find.byKey(const ValueKey('output-probe:999'))),
        isA<_RowProbeState>(),
      );
      body.position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('output-probe:0')), findsOneWidget);
      expect(
        mounts.values.fold<int>(0, (sum, count) => sum + count),
        lessThan(400),
        reason: 'far scrolling must not mount the intervening 1000 rows',
      );
      expect(rows.items, hasLength(1000));
      expect(
        rows.items.where((row) => row['name'] == 'Equal duplicate'),
        hasLength(3),
      );
      expect(api.bodies, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '__lineId output uses the fast path and sends only the selected authoritative line selector',
    (tester) async {
      final a = _LineRow('line-a', 'First line');
      final b = _LineRow('line-b', 'Second line');
      final source = ValueNotifier<List<_Row>>([a, b]);
      addTearDown(source.dispose);
      final api = _OutputApi();
      await _pumpTable(
        tester,
        api: api,
        source: source,
        rows: MasterDataTableRowsController<_Row>(),
        mounts: {},
        explicitOutputSelection: true,
      );
      expect(find.byType(Checkbox), findsNWidgets(3));
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      await _downloadSelected(tester);
      expect(api.bodies, hasLength(1));
      expect((api.bodies.single['columnProjection'] as Map)['rowSelection'], [
        {'__lineId': 'line-b'},
      ]);
      expect(api.queries.single['keyword'], 'current-scope');
      expect(
        a.keyEnumerations + b.keyEnumerations,
        0,
        reason:
            'stable line IDs avoid enumerating and hashing the whole raw Map',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-State line snapshots avoid raw scans while retaining current facts and native copied text',
    (tester) async {
      final source = ValueNotifier<List<_Row>>([
        {'name': 'First line', 'anonymous': true},
        {'name': 'Visible line', 'anonymous': true},
      ]);
      addTearDown(source.dispose);
      final rows = MasterDataTableRowsController<_Row>();
      final api = _OutputApi();
      await _pumpTable(
        tester,
        api: api,
        source: source,
        rows: rows,
        mounts: {},
        explicitOutputSelection: true,
      );
      final tableState = tester.state(find.byKey(_tableKey));
      final rowState = tester.state(
        find.byKey(const ValueKey('output-probe:1')),
      );
      final a = _LineRow('line-a', 'First line')..['privateRaw'] = 'before-a';
      final b = _LineRow('line-b', 'Visible line')..['privateRaw'] = 'before-b';
      source.value = [a, b];
      await tester.pumpAndSettle();
      expect(tester.state(find.byKey(_tableKey)), same(tableState));
      expect(rows.items[1], same(b));
      expect(
        a.keyEnumerations + b.keyEnumerations,
        0,
        reason:
            'same-State anonymous-to-line replacement must keep the fast path',
      );
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      await _selectText(tester, 'Visible line');
      await _copy(tester);
      expect(clipboard, 'Visible line');

      final freshA = _LineRow('line-a', 'First line')
        ..['privateRaw'] = 'current-a';
      final freshB = _LineRow('line-b', 'Visible line')
        ..['privateRaw'] = 'current-b';
      source.value = [freshA, freshB];
      await tester.pumpAndSettle();
      expect(tester.state(find.byKey(_tableKey)), same(tableState));
      expect(
        tester.state(find.byKey(const ValueKey('output-probe:1'))),
        same(rowState),
      );
      expect(rows.items, hasLength(2));
      expect(rows.items[1], same(freshB));
      expect(rows.items[1]['privateRaw'], 'current-b');
      expect(tester.widget<Checkbox>(find.byType(Checkbox).last).value, isTrue);
      clipboard = 'not the selected text';
      await _copy(tester);
      expect(clipboard, 'Visible line');
      tester
          .state<SelectionAreaState>(
            find
                .ancestor(
                  of: find.text('Visible line'),
                  matching: find.byType(SelectionArea),
                )
                .first,
          )
          .selectableRegion
          .clearSelection();
      await tester.pumpAndSettle();
      await _downloadSelected(tester);
      expect(api.bodies, hasLength(1));
      expect((api.bodies.single['columnProjection'] as Map)['rowSelection'], [
        {'__lineId': 'line-b'},
      ]);
      expect(api.queries.single['keyword'], 'current-scope');
      expect(
        a.keyEnumerations +
            b.keyEnumerations +
            freshA.keyEnumerations +
            freshB.keyEnumerations,
        0,
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'hidden raw changes retain native copied text while newly selected output captures the current raw facts',
    (tester) async {
      final source = ValueNotifier<List<_Row>>([
        {'id': 'source-before', 'name': 'Visible label'},
      ]);
      addTearDown(source.dispose);
      final mounts = <int, int>{};
      final api = _OutputApi();
      await _pumpTable(
        tester,
        api: api,
        source: source,
        rows: MasterDataTableRowsController<_Row>(),
        mounts: mounts,
        explicitOutputSelection: true,
      );
      final before = tester.state(find.byKey(const ValueKey('output-probe:0')));
      await _selectText(tester, 'Visible label');
      await _copy(tester);
      expect(clipboard, 'Visible label');
      source.value = [
        {'id': 'source-after', 'name': 'Visible label'},
      ];
      await tester.pumpAndSettle();
      expect(
        tester.state(find.byKey(const ValueKey('output-probe:0'))),
        same(before),
      );
      clipboard = 'not the selected text';
      await _copy(tester);
      expect(
        clipboard,
        'Visible label',
        reason: 'a hidden output fact is not native text-selection identity',
      );
      // End the already-verified native text selection through its public API;
      // the following real checkbox click starts a separate output action.
      tester
          .state<SelectionAreaState>(
            find
                .ancestor(
                  of: find.text('Visible label'),
                  matching: find.byType(SelectionArea),
                )
                .first,
          )
          .selectableRegion
          .clearSelection();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      await _downloadSelected(tester);
      expect(api.bodies, hasLength(1));
      expect((api.bodies.single['columnProjection'] as Map)['rowSelection'], [
        {'id': 'source-after', 'name': 'Visible label'},
      ]);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );
}
