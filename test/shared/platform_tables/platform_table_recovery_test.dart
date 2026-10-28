import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/l10n/platform_table_recovery_text.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_widgets.dart';
import '../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('UTEN_CAPTURE_PLATFORM_RECOVERY');
const _captureDesktop = bool.fromEnvironment(
  'UTEN_CAPTURE_PLATFORM_RECOVERY_DESKTOP',
);
final _captureKey = GlobalKey();

const _note = PlatformColumnDefinition(
  id: 'note',
  scope: 'recovery',
  name: '扩展说明',
);

class _Row extends EditableGridRow {
  _Row(this.id);
  final String id;
}

class _Layout extends PlatformTableLayoutNotifier {
  _Layout(super.tableKey, this.initial);
  final PlatformTableLayout initial;
  @override
  PlatformTableLayout build() => initial;
  @override
  void persist() {}
}

class _Repository extends PlatformTableRepository {
  _Repository() : super(ApiClient(Dio()));
  bool fail = true, allowed = true;
  String value = '原值';
  String? failingId;
  String? omittedId;
  int? responseVersion;
  bool nullValues = false;
  List<PlatformColumnDefinition> definitions = [_note];
  final List<List<String>> requestedColumns = [];
  final Map<String, String> responseIds = {};
  Completer<void>? gate;
  Completer<PlatformRowValues>? saveGate;
  int reads = 0, scopeReads = 0, invalidations = 0, writes = 0;
  @override
  void invalidateScopes() {
    invalidations++;
    super.invalidateScopes();
  }

  @override
  Future<List<PlatformTableCapabilities>> scopes() async {
    scopeReads++;
    return allowed
        ? [
            const PlatformTableCapabilities(
              scope: 'recovery',
              canWrite: true,
              canCreate: true,
              canDefine: true,
            ),
          ]
        : [];
  }

  @override
  Future<List<PlatformColumnDefinition>> search(
    String scope,
    String query, {
    List<String>? ids,
  }) async => definitions;
  @override
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async {
    reads++;
    requestedColumns.add(List.of(columnIds));
    if (gate case final pending?) await pending.future;
    if (fail || failingId != null && ids.contains(failingId)) {
      throw NetworkTimeoutException();
    }
    return [
      for (final id in ids.where((id) => id != omittedId))
        PlatformRowValues(
          recordId: responseIds[id] ?? id,
          version: responseVersion ?? (value == '原值' ? 1 : 2),
          canWrite: true,
          cells: [
            PlatformColumnCell(
              columnId: 'note',
              definition: _note,
              value: nullValues ? null : value,
            ),
          ],
        ),
    ];
  }

  @override
  Future<PlatformRowValues> save(
    String scope,
    String recordId, {
    required int expectedVersion,
    required List<Map<String, dynamic>> cells,
  }) async {
    writes++;
    if (saveGate case final pending?) return pending.future;
    throw StateError('Read recovery must never resubmit a write');
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Repository repo,
  Widget child, {
  String language = 'zh',
  double width = 390,
  PlatformTableLayout initial = const PlatformTableLayout(added: [_note]),
}) async {
  tester.view.physicalSize = Size(_captureDesktop ? 1100 : width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  String? koreanFont;
  if (_capture) {
    await loadAuditScreenshotFonts(tester);
    koreanFont = await loadAuditKoreanScreenshotFont(
      tester,
      requiredForCapture: true,
    );
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        platformTableRepositoryProvider.overrideWithValue(repo),
        platformTableLayoutProvider(
          'recovery.table',
        ).overrideWith(() => _Layout('recovery.table', initial)),
      ],
      child: MaterialApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: _capture
            ? auditScreenshotTheme(
                _captureDesktop ? buildLightTheme() : buildDarkTheme(),
                fontFamilyFallback: [?koreanFont],
              )
            : buildDarkTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(_captureDesktop ? 1 : 1.6),
          ),
          child: child!,
        ),
        home: RepaintBoundary(
          key: _captureKey,
          child: Scaffold(body: ListView(children: [child])),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'unread formula cells show read availability before calculation diagnostics',
    (tester) async {
      const formula = PlatformColumnDefinition(
        id: 'formula',
        scope: 'recovery',
        name: '计算补充列',
        type: 'CALCULATED',
        formula: PlatformFormula(
          base: PlatformFormulaOperand(fact: 'quantity'),
        ),
      );
      final repo = _Repository()..definitions = [formula];
      final row = _Row('record');
      addTearDown(row.dispose);
      final controller = PlatformTableController<_Row>();
      addTearDown(controller.dispose);
      await _mount(
        tester,
        repo,
        Builder(
          builder: (context) {
            controller.configure(
              context,
              descriptor: PlatformTableDescriptor<_Row>(
                kind: 'master',
                rows: [row],
                columnKeys: const ['base'],
                tableKey: 'recovery.table',
              ),
              explicitBinding: PlatformTableBinding<_Row>(
                tableKey: 'recovery.table',
                scope: 'recovery',
                recordIdOf: (row) => row.id,
              ),
            );
            return ListenableBuilder(
              listenable: controller,
              builder: (_, _) => PlatformColumnValue(
                controller: controller,
                row: row,
                column: formula,
              ),
            );
          },
        ),
        initial: const PlatformTableLayout(added: [formula]),
      );
      expect(find.text('暂不可用'), findsOneWidget);
      expect(find.text('计算不可用'), findsNothing);
      repo.fail = false;
      await controller.retryRead();
      await tester.pumpAndSettle();
      expect(controller.error, isNull);
      expect(find.text('暂不可用'), findsNothing);
      expect(find.text('计算不可用'), findsOneWidget);
      expect(repo.writes, 0);
    },
  );
  testWidgets(
    'obsolete layout columns repair themselves while valid fields and unsaved input survive',
    (tester) async {
      const obsolete = PlatformColumnDefinition(
        id: 'obsolete',
        scope: 'recovery',
        name: '旧环境列',
      );
      final repo = _Repository()..fail = false;
      final row = _Row('record');
      addTearDown(row.dispose);
      final controller = PlatformTableController<_Row>();
      addTearDown(controller.dispose);
      row.platformFields.setValue(_note, '未提交原文');
      await _mount(
        tester,
        repo,
        Builder(
          builder: (context) {
            controller.configure(
              context,
              descriptor: PlatformTableDescriptor<_Row>(
                kind: 'editable',
                rows: [row],
                columnKeys: const ['base'],
                tableKey: 'recovery.table',
              ),
              explicitBinding: PlatformTableBinding<_Row>(
                tableKey: 'recovery.table',
                scope: 'recovery',
                recordIdOf: (row) => row.id,
                draftOf: (row) => row.platformFields,
              ),
            );
            return const SizedBox();
          },
        ),
        initial: const PlatformTableLayout(
          added: [_note, obsolete],
          order: ['base', 'platform:obsolete'],
          pinned: {'platform:obsolete'},
          widths: {'base': 180, 'platform:obsolete': 120},
          sortColumn: 'platform:obsolete',
        ),
      );
      expect(controller.error, isNull);
      expect(controller.layout.added.map((d) => d.id), ['note']);
      expect(controller.layout.order, ['base']);
      expect(controller.layout.pinned, isEmpty);
      expect(controller.layout.widths, {'base': 180});
      expect(controller.layout.sortColumn, isNull);
      expect(repo.requestedColumns, everyElement(['note']));
      expect(row.platformFields.snapshot.cells.single.value, '未提交原文');
      expect(repo.writes, 0);
    },
  );
  testWidgets(
    'complete rows containing null values remain a valid atomic read',
    (tester) async {
      final repo = _Repository()
        ..fail = false
        ..nullValues = true
        ..responseVersion = 2;
      final rows = [for (var i = 0; i < 201; i++) _Row('record-$i')];
      for (final row in rows) {
        addTearDown(row.dispose);
      }
      final controller = PlatformTableController<_Row>();
      addTearDown(controller.dispose);
      await _mount(
        tester,
        repo,
        Builder(
          builder: (context) {
            controller.configure(
              context,
              descriptor: PlatformTableDescriptor<_Row>(
                kind: 'master',
                rows: rows,
                columnKeys: const ['base'],
                tableKey: 'recovery.table',
              ),
              explicitBinding: PlatformTableBinding<_Row>(
                tableKey: 'recovery.table',
                scope: 'recovery',
                recordIdOf: (row) => row.id,
              ),
            );
            return const Text('Nullable values are facts');
          },
        ),
      );
      expect(controller.error, isNull);
      expect(controller.readFailure, isNull);
      expect(controller.capabilities, isNotNull);
      expect(controller.rowValues(rows.last)!.version, 2);
      expect(controller.value(rows.last, _note), isNull);
      expect(repo.reads, 2);
      expect(repo.writes, 0);
    },
  );
  for (final malformed in ['duplicate', 'foreign']) {
    testWidgets(
      '$malformed record ids cannot replace any prior inline-table values',
      (tester) async {
        final repo = _Repository()..fail = false;
        final rows = [for (var i = 0; i < 201; i++) _Row('record-$i')];
        for (final row in rows) {
          addTearDown(row.dispose);
        }
        final controller = PlatformTableController<_Row>();
        addTearDown(controller.dispose);
        await _mount(
          tester,
          repo,
          Builder(
            builder: (context) {
              controller.configure(
                context,
                descriptor: PlatformTableDescriptor<_Row>(
                  kind: 'master',
                  rows: rows,
                  columnKeys: const ['base'],
                  tableKey: 'recovery.table',
                ),
                explicitBinding: PlatformTableBinding<_Row>(
                  tableKey: 'recovery.table',
                  scope: 'recovery',
                  recordIdOf: (row) => row.id,
                ),
              );
              return const Text('Inline values');
            },
          ),
        );
        repo.value = '新值';
        repo.responseIds[malformed == 'duplicate'
            ? 'record-199'
            : 'record-200'] = malformed == 'duplicate'
            ? 'record-0'
            : 'foreign-record';
        await controller.reload();
        await tester.pumpAndSettle();
        expect(controller.readFailure, PlatformTableReadFailure.recordsChanged);
        expect(controller.capabilities, isNotNull);
        expect(controller.value(rows.first, _note), '原值');
        expect(controller.value(rows.last, _note), '原值');
        repo.responseIds.clear();
        await controller.retryRead();
        await tester.pumpAndSettle();
        expect(controller.value(rows.last, _note), '新值');
        expect(repo.writes, 0);
      },
    );
  }
  testWidgets(
    'a late successful save cannot roll back a newer authoritative read version',
    (tester) async {
      final repo = _Repository()..fail = false;
      final row = _Row('record');
      addTearDown(row.dispose);
      final controller = PlatformTableController<_Row>();
      addTearDown(controller.dispose);
      await _mount(
        tester,
        repo,
        Builder(
          builder: (context) {
            controller.configure(
              context,
              columnEditingEnabled: true,
              descriptor: PlatformTableDescriptor<_Row>(
                kind: 'master',
                rows: [row],
                columnKeys: const ['base'],
                tableKey: 'recovery.table',
              ),
              explicitBinding: PlatformTableBinding<_Row>(
                tableKey: 'recovery.table',
                scope: 'recovery',
                recordIdOf: (row) => row.id,
                canEditValues: true,
              ),
            );
            return const Text('Current record');
          },
        ),
      );
      repo.saveGate = Completer<PlatformRowValues>();
      final saving = controller.saveCell(row, _note, '本次写入');
      repo.value = '后来已核定的版本';
      repo.responseVersion = 3;
      await controller.reload();
      await tester.pumpAndSettle();
      repo.saveGate!.complete(
        PlatformRowValues(
          recordId: row.id,
          version: 2,
          canWrite: true,
          cells: [
            const PlatformColumnCell(
              columnId: 'note',
              definition: _note,
              value: '较早保存结果',
            ),
          ],
        ),
      );
      await saving;
      await tester.pumpAndSettle();
      expect(controller.rowValues(row)!.version, 3);
      expect(controller.value(row, _note), '后来已核定的版本');
    },
  );

  testWidgets(
    'a superseded table save neither blocks nor releases the current table writer',
    (tester) async {
      final repo = _Repository()..fail = false;
      final row = _Row('record');
      addTearDown(row.dispose);
      final key = ValueNotifier('recovery.table');
      addTearDown(key.dispose);
      final controller = PlatformTableController<_Row>();
      addTearDown(controller.dispose);
      await _mount(
        tester,
        repo,
        ValueListenableBuilder<String>(
          valueListenable: key,
          builder: (context, table, _) {
            controller.configure(
              context,
              columnEditingEnabled: true,
              descriptor: PlatformTableDescriptor<_Row>(
                kind: 'master',
                rows: [row],
                columnKeys: const ['base'],
                tableKey: table,
              ),
              explicitBinding: PlatformTableBinding<_Row>(
                tableKey: table,
                scope: 'recovery',
                recordIdOf: (row) => row.id,
                canEditValues: true,
              ),
            );
            return const Text('Current table');
          },
        ),
      );
      final oldGate = Completer<PlatformRowValues>();
      repo.saveGate = oldGate;
      final oldSave = controller.saveCell(row, _note, '原表请求');
      repo.responseVersion = 3;
      key.value = 'recovery.other';
      await tester.pumpAndSettle();
      expect(
        controller.canEdit(row, _note),
        isTrue,
        reason: 'The previous table cannot reserve the new table writer slot',
      );
      final newGate = Completer<PlatformRowValues>();
      repo.saveGate = newGate;
      final currentSave = controller.saveCell(row, _note, '当前表请求');
      oldGate.complete(
        PlatformRowValues(recordId: row.id, version: 99, canWrite: true),
      );
      await oldSave;
      await tester.pumpAndSettle();
      expect(
        controller.canEdit(row, _note),
        isFalse,
        reason:
            'Finishing an old writer cannot release the current writer slot',
      );
      expect(controller.rowValues(row)!.version, 3);
      newGate.complete(
        PlatformRowValues(recordId: row.id, version: 4, canWrite: true),
      );
      await currentSave;
      await tester.pumpAndSettle();
      expect(controller.rowValues(row)!.version, 4);
    },
  );

  testWidgets(
    'a successful but incomplete batch cannot publish a mixed record snapshot',
    (tester) async {
      final repo = _Repository()..fail = false;
      final rows = [for (var i = 0; i < 201; i++) _Row('record-$i')];
      for (final row in rows) {
        addTearDown(row.dispose);
      }
      final controller = PlatformTableController<_Row>();
      addTearDown(controller.dispose);
      await _mount(
        tester,
        repo,
        Builder(
          builder: (context) {
            controller.configure(
              context,
              descriptor: PlatformTableDescriptor<_Row>(
                kind: 'editable',
                rows: rows,
                columnKeys: const ['base'],
                tableKey: 'recovery.table',
              ),
              explicitBinding: PlatformTableBinding<_Row>(
                tableKey: 'recovery.table',
                scope: 'recovery',
                recordIdOf: (row) => row.id,
                canEditValues: true,
                draftOf: (row) => row.platformFields,
              ),
            );
            return const Text('Host remains mounted');
          },
        ),
      );
      rows.first.platformFields.setValue(_note, '本机精确输入');
      repo.value = '新值';
      repo.omittedId = 'record-200';
      await controller.reload();
      await tester.pumpAndSettle();
      expect(
        controller.value(rows[1], _note),
        '原值',
        reason:
            'No earlier successful batch may be published until every requested record is present',
      );
      expect(controller.readFailure, PlatformTableReadFailure.recordsChanged);
      expect(rows.first.platformFields.cells.single.value, '本机精确输入');
      expect(rows.first.platformFields.version, 1);
      repo.omittedId = null;
      await controller.retryRead();
      await tester.pumpAndSettle();
      expect(controller.value(rows[1], _note), '新值');
      expect(rows.first.platformFields.cells.single.value, '本机精确输入');
      expect(repo.writes, 0);
    },
  );

  testWidgets(
    'a late cell-save response cannot restore values after a fresh access rejection',
    (tester) async {
      final repo = _Repository()..fail = false;
      final row = _Row('record');
      addTearDown(row.dispose);
      final controller = PlatformTableController<_Row>();
      addTearDown(controller.dispose);
      await _mount(
        tester,
        repo,
        Builder(
          builder: (context) {
            controller.configure(
              context,
              columnEditingEnabled: true,
              descriptor: PlatformTableDescriptor<_Row>(
                kind: 'master',
                rows: [row],
                columnKeys: const ['base'],
                tableKey: 'recovery.table',
              ),
              explicitBinding: PlatformTableBinding<_Row>(
                tableKey: 'recovery.table',
                scope: 'recovery',
                recordIdOf: (row) => row.id,
                canEditValues: true,
              ),
            );
            return const Text('Host remains mounted');
          },
        ),
      );
      repo.saveGate = Completer<PlatformRowValues>();
      final saving = controller.saveCell(row, _note, '已发出保存');
      await tester.pump();
      repo.allowed = false;
      await controller.retryRead();
      await tester.pumpAndSettle();
      expect(controller.rowValues(row), isNull);
      repo.saveGate!.complete(
        PlatformRowValues(
          recordId: row.id,
          version: 7,
          canWrite: true,
          cells: [
            const PlatformColumnCell(
              columnId: 'note',
              definition: _note,
              value: '迟到的服务器返回',
            ),
          ],
        ),
      );
      await saving;
      await tester.pumpAndSettle();
      expect(
        controller.rowValues(row),
        isNull,
        reason:
            'A successful old command is not authority for the current reader',
      );
      expect(controller.readFailure, PlatformTableReadFailure.forbidden);
      expect(repo.writes, 1);
    },
  );

  test(
    'explicit capability cache invalidation rechecks the actual repository response',
    () async {
      var requests = 0;
      var allowed = true;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: allowed
                      ? [
                          {'scope': 'recovery', 'canWrite': true},
                        ]
                      : <Map<String, dynamic>>[],
                ),
              );
            },
          ),
        );
      final repo = PlatformTableRepository(ApiClient(dio));
      expect((await repo.scopes()).single.scope, 'recovery');
      allowed = false;
      expect((await repo.scopes()).single.scope, 'recovery');
      expect(requests, 1);
      repo.invalidateScopes();
      expect(await repo.scopes(), isEmpty);
      expect(requests, 2);
    },
  );

  for (final language in ['zh', 'en', 'ko']) {
    for (final editable in [false, true]) {
      testWidgets(
        '$language ${editable ? 'grid' : 'master'} retries an incomplete successful response without replacing base input',
        (tester) async {
          final repo = _Repository()
            ..fail = false
            ..omittedId = 'record';
          final row = _Row('record');
          final input = TextEditingController(text: '未保存原文');
          addTearDown(input.dispose);
          final grid = UtenEditableGridController<_Row>(initial: [row]);
          addTearDown(grid.dispose);
          final binding = PlatformTableBinding<_Row>(
            tableKey: 'recovery.table',
            scope: 'recovery',
            recordIdOf: (row) => row.id,
            canEditValues: true,
          );
          final table = editable
              ? UtenEditableGrid<_Row>(
                  tableKey: 'recovery.table',
                  platformBinding: binding,
                  controller: grid,
                  showAddRow: false,
                  showRowDelete: false,
                  showColumnSettings: false,
                  showSelectAllToggle: false,
                  showRemoveRowsAction: false,
                  columns: [
                    EditableGridColumn<_Row>(
                      key: 'base',
                      label: '基础资料',
                      width: 240,
                      cellBuilder: (_, _) => TextField(
                        key: const Key('base-input'),
                        controller: input,
                      ),
                    ),
                  ],
                )
              : MasterDataTableView<_Row>(
                  tableKey: 'recovery.table',
                  embedded: true,
                  platformBinding: binding,
                  items: [row],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  columns: [
                    MasterColumnDef<_Row>(
                      key: 'base',
                      label: '基础资料',
                      width: 240,
                      value: (_) => '基础资料',
                      cellBuilder: (_, _) => TextField(
                        key: const Key('base-input'),
                        controller: input,
                      ),
                    ),
                  ],
                );
          await _mount(tester, repo, table, language: language);
          await tester.tap(
            find.byKey(const ValueKey('platform-table-read-details')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is SelectableText &&
                  widget.data ==
                      platformTableRecoveryTexts['incompleteReason']![[
                        'zh',
                        'en',
                        'ko',
                      ].indexOf(language)],
            ),
            findsOneWidget,
          );
          await tester.tap(
            find.text(
              platformTableRecoveryTexts['close']![[
                'zh',
                'en',
                'ko',
              ].indexOf(language)],
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('base-input')),
            '输入原文继续保留',
          );
          final oldState = tester.state<EditableTextState>(
            find.descendant(
              of: find.byKey(const Key('base-input')),
              matching: find.byType(EditableText),
            ),
          );
          repo.omittedId = null;
          await tester.tap(
            find.byKey(const ValueKey('platform-table-read-retry')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('platform-table-read-error')),
            findsNothing,
          );
          expect(input.text, '输入原文继续保留');
          expect(
            tester.state<EditableTextState>(
              find.descendant(
                of: find.byKey(const Key('base-input')),
                matching: find.byType(EditableText),
              ),
            ),
            same(oldState),
          );
          expect(repo.writes, 0);
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        '$language ${editable ? 'grid' : 'master'} shows the cause and recovers without replacing base input',
        (tester) async {
          final repo = _Repository()..nullValues = true;
          final row = _Row('record');
          final input = TextEditingController(text: '基础资料草稿');
          addTearDown(input.dispose);
          final grid = UtenEditableGridController<_Row>(initial: [row]);
          addTearDown(grid.dispose);
          final binding = PlatformTableBinding<_Row>(
            tableKey: 'recovery.table',
            scope: 'recovery',
            recordIdOf: (row) => row.id,
            canEditValues: true,
          );
          final table = editable
              ? UtenEditableGrid<_Row>(
                  tableKey: 'recovery.table',
                  platformBinding: binding,
                  controller: grid,
                  showAddRow: false,
                  showRowDelete: false,
                  showColumnSettings: false,
                  showSelectAllToggle: false,
                  showRemoveRowsAction: false,
                  columns: [
                    EditableGridColumn<_Row>(
                      key: 'base',
                      label: '基础资料',
                      width: 240,
                      cellBuilder: (_, _) => TextField(
                        key: const Key('base-input'),
                        controller: input,
                      ),
                    ),
                  ],
                )
              : MasterDataTableView<_Row>(
                  tableKey: 'recovery.table',
                  embedded: true,
                  platformBinding: binding,
                  items: [row],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  columns: [
                    MasterColumnDef<_Row>(
                      key: 'base',
                      label: '基础资料',
                      width: 240,
                      value: (_) => '基础资料',
                      cellBuilder: (_, _) => TextField(
                        key: const Key('base-input'),
                        controller: input,
                      ),
                    ),
                  ],
                );
          await _mount(tester, repo, table, language: language);
          expect(
            find.byKey(const ValueKey('platform-table-read-error')),
            findsOneWidget,
          );
          expect(
            find.text(
              platformTableRecoveryTexts['cellUnavailable']![[
                'zh',
                'en',
                'ko',
              ].indexOf(language)],
            ),
            findsOneWidget,
          );
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Tooltip &&
                  widget.message!.contains(
                    platformTableRecoveryTexts['details']![[
                      'zh',
                      'en',
                      'ko',
                    ].indexOf(language)],
                  ),
            ),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const ValueKey('platform-table-read-details')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is SelectableText &&
                  widget.data ==
                      platformTableRecoveryTexts['timeoutReason']![[
                        'zh',
                        'en',
                        'ko',
                      ].indexOf(language)],
            ),
            findsOneWidget,
          );
          await tester.tap(
            find.text(
              platformTableRecoveryTexts['close']![[
                'zh',
                'en',
                'ko',
              ].indexOf(language)],
            ),
          );
          await tester.pumpAndSettle();
          if (_capture) {
            await saveAuditScreenshot(
              tester,
              _captureKey,
              'platform-recovery-$language-${editable ? 'grid' : 'master'}${_captureDesktop ? '-desktop-light' : ''}',
            );
          }
          final retry = find.byKey(const ValueKey('platform-table-read-retry'));
          expect(
            find.text(
              platformTableRecoveryTexts['retry']![[
                'zh',
                'en',
                'ko',
              ].indexOf(language)],
            ),
            findsOneWidget,
          );
          await tester.enterText(
            find.byKey(const Key('base-input')),
            '正在编辑，保持原文',
          );
          final state = tester.state<EditableTextState>(
            find.descendant(
              of: find.byKey(const Key('base-input')),
              matching: find.byType(EditableText),
            ),
          );
          repo.fail = false;
          repo.gate = Completer<void>();
          await tester.ensureVisible(retry);
          await tester.tap(retry);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 30));
          expect(tester.widget<UtenButton>(retry).isLoading, isTrue);
          expect(repo.invalidations, 1);
          expect(tester.widget<UtenButton>(retry).onPressed, isNull);
          repo.gate!.complete();
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('platform-table-read-error')),
            findsNothing,
          );
          expect(input.text, '正在编辑，保持原文');
          expect(find.text('—'), findsOneWidget);
          expect(
            tester.state<EditableTextState>(
              find.descendant(
                of: find.byKey(const Key('base-input')),
                matching: find.byType(EditableText),
              ),
            ),
            same(state),
          );
          expect(repo.writes, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'a later batch failure preserves the complete prior snapshot and dirty drafts; lost access masks it',
    (tester) async {
      final repo = _Repository()..fail = false;
      final rows = [for (var i = 0; i < 201; i++) _Row('record-$i')];
      for (final row in rows) {
        addTearDown(row.dispose);
      }
      final controller = PlatformTableController<_Row>();
      addTearDown(controller.dispose);
      await _mount(
        tester,
        repo,
        Builder(
          builder: (context) {
            controller.configure(
              context,
              descriptor: PlatformTableDescriptor<_Row>(
                kind: 'editable',
                rows: rows,
                columnKeys: const ['base'],
                tableKey: 'recovery.table',
              ),
              explicitBinding: PlatformTableBinding<_Row>(
                tableKey: 'recovery.table',
                scope: 'recovery',
                recordIdOf: (row) => row.id,
                canEditValues: true,
                draftOf: (row) => row.platformFields,
              ),
            );
            return ListenableBuilder(
              listenable: controller,
              builder: (context, _) => Column(
                children: [
                  const Text('基础表仍在'),
                  PlatformTableStatus(
                    error: controller.error,
                    failure: controller.readFailure,
                    loading: controller.loading,
                    retry: controller.retryRead,
                  ),
                ],
              ),
            );
          },
        ),
      );
      expect(controller.value(rows[1], _note), '原值');
      rows.first.platformFields.setValue(_note, '未提交的精确原文');
      repo.value = '新值';
      repo.failingId = 'record-200';
      await controller.reload();
      await tester.pumpAndSettle();
      expect(controller.value(rows[1], _note), '原值');
      expect(rows.first.platformFields.snapshot.cells.single.value, '未提交的精确原文');
      expect(controller.readFailure, PlatformTableReadFailure.connection);
      repo.failingId = null;
      await controller.retryRead();
      await tester.pumpAndSettle();
      expect(controller.value(rows[1], _note), '新值');
      expect(rows.first.platformFields.snapshot.cells.single.value, '未提交的精确原文');
      expect(rows.first.platformFields.version, 1);
      repo.allowed = false;
      await controller.retryRead();
      await tester.pumpAndSettle();
      expect(controller.readFailure, PlatformTableReadFailure.forbidden);
      expect(controller.value(rows[1], _note), isNull);
      expect(rows.first.platformFields.canWrite, isFalse);
      expect(rows.first.platformFields.snapshot.cells.single.value, '未提交的精确原文');
      expect(repo.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
