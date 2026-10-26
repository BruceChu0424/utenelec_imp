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
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_widgets.dart';
import '../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('UTEN_CAPTURE_PLATFORM_RECOVERY');
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
  _Layout(super.tableKey);
  @override
  PlatformTableLayout build() => const PlatformTableLayout(added: [_note]);
  @override
  void persist() {}
}

class _Repository extends PlatformTableRepository {
  _Repository() : super(ApiClient(Dio()));
  bool fail = true, allowed = true;
  String value = '原值';
  String? failingId;
  Completer<void>? gate;
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
  }) async => [_note];
  @override
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async {
    reads++;
    if (gate case final pending?) await pending.future;
    if (fail || failingId != null && ids.contains(failingId)) {
      throw NetworkTimeoutException();
    }
    return [
      for (final id in ids)
        PlatformRowValues(
          recordId: id,
          version: value == '原值' ? 1 : 2,
          canWrite: true,
          cells: [
            PlatformColumnCell(
              columnId: 'note',
              definition: _note,
              value: value,
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
    throw StateError('Read recovery must never resubmit a write');
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Repository repo,
  Widget child, {
  String language = 'zh',
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 1100);
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
        ).overrideWith(() => _Layout('recovery.table')),
      ],
      child: MaterialApp(
        locale: Locale(language),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: _capture
            ? auditScreenshotTheme(
                buildDarkTheme(),
                fontFamilyFallback: [?koreanFont],
              )
            : buildDarkTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
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
        '$language ${editable ? 'grid' : 'master'} shows the cause and recovers without replacing base input',
        (tester) async {
          final repo = _Repository();
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
            find.textContaining(
              platformTableRecoveryTexts['timeoutReason']![[
                'zh',
                'en',
                'ko',
              ].indexOf(language)],
            ),
            findsOneWidget,
          );
          if (_capture) {
            await saveAuditScreenshot(
              tester,
              _captureKey,
              'platform-recovery-$language-${editable ? 'grid' : 'master'}',
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
