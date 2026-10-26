import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

typedef _Row = ({
  String id,
  String code,
  String name,
  int version,
  bool writable,
});

final _previewKey = GlobalKey();
final _appPreviewKey = GlobalKey();

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

Future<void> _pump(
  WidgetTester tester, {
  bool canEdit = true,
  bool writable = true,
  int totalPages = 1,
  Future<PagedResult<_Row>> Function(MasterPaneQuery)? loadPage,
  Size size = const Size(1200, 850),
  double textScale = 1,
  String? inlineCancelLabel,
  String? inlineDiscardNote,
  required Future<void> Function(String, Map<String, dynamic>, _Row) save,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(size);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final row = (
    id: 'g1',
    code: 'HP001',
    name: '原名称',
    version: 7,
    writable: writable,
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: _appPreviewKey,
      child: ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          sessionProvider.overrideWith(_Session.new),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'master-test-user'),
          ),
          apiClientProvider.overrideWithValue(ApiClient(Dio())),
          currentPermissionsProvider.overrideWithValue({
            Perm.goodsView,
            Perm.goodsEdit,
          }),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: _previewKey,
            child: Scaffold(
              body: MasterEntityDetailPane<_Row, _Row>(
                categoryId: 'cat',
                externalKeyword: null,
                config: MasterEntityPaneConfig(
                  noun: '货品',
                  icon: Icons.inventory_2_outlined,
                  defaultCodePrefix: 'HP',
                  columns: [
                    MasterColumnDef(
                      key: 'code',
                      label: '编号',
                      width: 140,
                      value: (r) => r.code,
                    ),
                    MasterColumnDef(
                      key: 'name',
                      label: '名称',
                      width: 200,
                      value: (r) => r.name,
                    ),
                  ],
                  idOf: (r) => r.id,
                  statusOf: (_) => '使用',
                  labelOf: (r) => r.name,
                  versionOf: (r) => r.version,
                  writableOf: (r) => r.writable,
                  loadCategory: (id) async => ProductCategoryDetail(
                    id: id,
                    code: 'C1',
                    name: '分类',
                    level: 0,
                    path: '分类',
                    childCount: 0,
                  ),
                  loadPage:
                      loadPage ??
                      (_) async => PagedResult(
                        items: [row],
                        page: 1,
                        size: 20,
                        total: totalPages,
                        totalPages: totalPages,
                      ),
                  loadFacets: (_) async =>
                      const MasterPaneFacets(fields: {}, nullCounts: {}),
                  batchEntityPath: '/master/goods',
                  statusResourceOf: (id) => '/master/goods/$id',
                  canCreate: false,
                  canEdit: canEdit,
                  canDelete: true,
                  canStatus: true,
                  onOpen: (_, _) async {},
                  inlineFields: {
                    'name': MasterInlineField(
                      key: 'name',
                      read: (r) => r.name,
                      required: true,
                    ),
                  },
                  onInlineSave: save,
                  inlineCancelLabel: inlineCancelLabel,
                  inlineDiscardNote: inlineDiscardNote,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _nameInput() => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.hintText == '名称',
);

Future<void> _activateName(WidgetTester tester, [String id = 'g1']) async {
  if (find
      .descendant(
        of: find.byKey(ValueKey('inline-$id-name')),
        matching: find.byType(TextField),
      )
      .evaluate()
      .isNotEmpty) {
    return;
  }
  await tester.tap(find.byKey(ValueKey('inline-activate-$id-name')));
  await tester.pumpAndSettle();
}

double _nameColumnWidth(WidgetTester tester) {
  final containers = tester.widgetList<Container>(
    find.ancestor(of: find.text('名称'), matching: find.byType(Container)),
  );
  for (final container in containers) {
    final constraints = container.constraints;
    if (constraints != null &&
        constraints.maxWidth.isFinite &&
        constraints.minWidth == constraints.maxWidth) {
      return constraints.maxWidth;
    }
  }
  fail('No fixed-width name header found');
}

Future<void> _capturePreview(WidgetTester tester, String name) async {
  if (Platform.environment['MASTER_INLINE_PREVIEW'] != '1') return;
  await tester.runAsync(() async {
    final boundary =
        _appPreviewKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final pixels = await boundary.toImage();
    final bytes = await pixels.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('.local-artifacts/inline-previews');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    pixels.dispose();
  });
}

void main() {
  testWidgets(
    'cancel real same-DTO destination navigation preserves page one editor and its complete raw draft',
    (tester) async {
      final reads = <int>[];
      var saves = 0;
      await _pump(
        tester,
        totalPages: 3,
        loadPage: (query) async {
          reads.add(query.page);
          return PagedResult<_Row>(
            items: [
              for (var i = 0; i < 20; i++)
                (
                  id: query.page == 1 && i == 0 ? 'g1' : 'g${query.page}-$i',
                  code: 'G${query.page}-$i',
                  name: '第${query.page}页货品$i',
                  version: 7,
                  writable: true,
                ),
            ],
            page: query.page,
            size: 20,
            total: 60,
            totalPages: 3,
          );
        },
        save: (_, _, _) async => saves++,
      );
      MasterDataTableView<_Row> table() =>
          tester.widget(find.byType(MasterDataTableView<_Row>));
      final rows = table().rowsController!;
      await rows.loadNextPage();
      await tester.pumpAndSettle();
      await rows.loadNextPage();
      await tester.pumpAndSettle();
      expect(rows.visiblePage, 1);
      table().onSelectedIdsChanged!({'g1'});
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      await _activateName(tester);
      const raw = TextEditingValue(
        text: ' 未完成 shuru ',
        selection: TextSelection(baseOffset: 5, extentOffset: 10),
        composing: TextRange(start: 5, end: 10),
      );
      tester.testTextInput.updateEditingValue(raw);
      await tester.pump();
      final input = _nameInput();
      final editable = find.descendant(
        of: input,
        matching: find.byType(EditableText),
      );
      final originalElement = tester.element(input);
      final originalState = tester.state<EditableTextState>(editable);
      final controller = originalState.widget.controller;
      final visibleIds = rows.items.map((row) => row.id).toList();
      final beforeReads = List<int>.of(reads);
      final position = find
          .descendant(
            of: find.byType(MasterDataTableView<_Row>),
            matching: find.byType(Scrollable),
          )
          .evaluate()
          .whereType<StatefulElement>()
          .map((element) => (element.state as ScrollableState).position)
          .firstWhere(
            (position) =>
                position.axis == Axis.vertical &&
                position.maxScrollExtent > 200,
          );
      final offset = position.pixels;
      rows.goToPage(3);
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(rows.visiblePage, 1);
      expect(rows.items.map((row) => row.id), visibleIds);
      expect(reads, beforeReads);
      expect(saves, 0);
      expect(position.pixels, closeTo(offset, .5));
      expect(table().selectedIds, {'g1'});
      expect(identical(tester.element(input), originalElement), isTrue);
      expect(
        identical(tester.state<EditableTextState>(editable), originalState),
        isTrue,
      );
      expect(controller.value, raw.copyWith(composing: TextRange.empty));
    },
  );

  for (final failReload in [false, true]) {
    testWidgets(
      'active IME cell survives a pending reload and ${failReload ? 'read error' : 'read success'}',
      (tester) async {
        Completer<PagedResult<_Row>>? pending;
        const row = (
          id: 'g1',
          code: 'HP001',
          name: '原名称',
          version: 7,
          writable: true,
        );
        PagedResult<_Row> page() => const PagedResult(
          items: [row],
          page: 1,
          size: 20,
          total: 1,
          totalPages: 1,
        );
        var writes = 0;
        await _pump(
          tester,
          loadPage: (_) => pending?.future ?? Future.value(page()),
          save: (_, _, _) async => writes++,
        );
        await tester.tap(find.text('编辑模式'));
        await tester.pumpAndSettle();
        await _activateName(tester);
        final input = _nameInput();
        final editable = find.descendant(
          of: input,
          matching: find.byType(EditableText),
        );
        final originalState = tester.state<EditableTextState>(editable);
        final focus = originalState.widget.focusNode;
        final text = originalState.widget.controller;
        const composing = TextEditingValue(
          text: '原名称 ',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 3, end: 4),
        );
        tester.testTextInput.updateEditingValue(composing);
        await tester.pump();
        expect(text.value, composing);
        pending = Completer<PagedResult<_Row>>();
        final pane =
            tester.state(find.byType(MasterEntityDetailPane<_Row, _Row>))
                as MasterEntityPaneController<_Row, _Row>;
        final loading = pane.reload();
        await tester.pump();
        expect(tester.state<EditableTextState>(editable), same(originalState));
        expect(focus.hasFocus, isTrue);
        expect(text.value, composing);
        expect(tester.widget<TextField>(input).readOnly, isTrue);
        if (failReload) {
          pending.completeError(ApiException('TEMPORARY', '读取失败'));
        } else {
          pending.complete(page());
        }
        await loading;
        await tester.pumpAndSettle();
        expect(tester.state<EditableTextState>(editable), same(originalState));
        expect(focus.hasFocus, isTrue);
        expect(text.value, composing);
        expect(tester.widget<TextField>(input).readOnly, failReload);
        expect(writes, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'lazy preview and its activated editor keep a usable column width and exit restores read-only metadata',
    (tester) async {
      await _pump(tester, save: (_, _, _) async {});
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      final editingTable = tester.widget<MasterDataTableView<_Row>>(
        find.byType(MasterDataTableView<_Row>),
      );
      expect(editingTable.temporaryLeadingColumnKeys, ['name']);
      final nameHeader = editingTable.columns.singleWhere(
        (column) => column.key == 'name',
      );
      expect(nameHeader.headerTrailingBuilder, isNotNull);
      expect(
        tester.getTopLeft(find.text('名称').first).dx,
        lessThan(tester.getTopLeft(find.text('编号').first).dx),
      );
      final previewWidth = _nameColumnWidth(tester);
      expect(previewWidth, greaterThanOrEqualTo(140));
      await _activateName(tester);
      expect(_nameColumnWidth(tester), previewWidth);
      await tester.tap(find.text('取消编辑'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<_Row>>(
        find.byType(MasterDataTableView<_Row>),
      );
      expect(table.temporaryLeadingColumnKeys, isEmpty);
      expect(
        table.columns
            .singleWhere((column) => column.key == 'name')
            .headerTrailingBuilder,
        isNull,
      );
      expect(
        table.columns
            .singleWhere((column) => column.key == 'name')
            .minimumWidthOf,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the same row can be saved twice using its refreshed version without leaving edit mode',
    (tester) async {
      var current = (
        id: 'g1',
        code: 'G1',
        name: '原名称',
        version: 7,
        writable: true,
      );
      final versions = <int>[];
      await _pump(
        tester,
        loadPage: (_) async => PagedResult(
          items: [current],
          page: 1,
          size: 20,
          total: 1,
          totalPages: 1,
        ),
        save: (_, patch, baseline) async {
          versions.add(baseline.version);
          current = (
            id: current.id,
            code: current.code,
            name: patch['name'] as String,
            version: current.version + 1,
            writable: true,
          );
        },
      );
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      await _activateName(tester);
      await tester.enterText(_nameInput(), '第一次保存');
      await tester.pump();
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      if (_nameInput().evaluate().isEmpty) await _activateName(tester);
      await tester.enterText(_nameInput(), '第二次保存');
      await tester.pump();
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      expect(versions, [7, 8]);
      expect(find.text('取消编辑'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mode feedback paints before activation and typing preserves the table widget',
    (tester) async {
      await _pump(
        tester,
        size: const Size(1440, 900),
        save: (_, _, _) async {},
      );
      await tester.tap(find.text('编辑模式'));
      await tester.pump();
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      expect(_nameInput(), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(_nameInput(), findsNothing);
      await _capturePreview(tester, 'desktop-edit-mode');
      await _activateName(tester);
      final originalTable = tester.widget<MasterDataTableView<_Row>>(
        find.byType(MasterDataTableView<_Row>),
      );
      await tester.enterText(_nameInput(), '第一段');
      await tester.pump();
      await tester.enterText(_nameInput(), '继续输入');
      await tester.pump();
      expect(
        identical(
          originalTable,
          tester.widget<MasterDataTableView<_Row>>(
            find.byType(MasterDataTableView<_Row>),
          ),
        ),
        isTrue,
        reason: 'ordinary keystrokes must not rebuild the entire pane/table',
      );
      expect(find.text('保存 1 行修改'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'slow save paints the shared overlay before the request and keeps the editor mounted',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      var progressVisibleBeforeRequest = false;
      await _pump(
        tester,
        size: const Size(390, 844),
        textScale: 2,
        save: (_, _, _) {
          calls++;
          progressVisibleBeforeRequest = find
              .byKey(const ValueKey('master-inline-saving'))
              .evaluate()
              .isNotEmpty;
          return pending.future;
        },
      );
      await tester.ensureVisible(find.text('编辑模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      await _activateName(tester);
      await tester.enterText(_nameInput(), '慢请求草稿');
      await tester.pump();
      await tester.ensureVisible(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(calls, 1);
      expect(progressVisibleBeforeRequest, isTrue);
      expect(
        find.byKey(const ValueKey('master-inline-saving')),
        findsOneWidget,
      );
      expect(_nameInput(), findsOneWidget);
      expect(tester.widget<TextField>(_nameInput()).readOnly, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('master-inline-saving')),
        findsOneWidget,
      );
      await _capturePreview(tester, 'narrow-large-text-saving');
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'committed rows are not retried when refresh fails, remaining drafts resume after a successful read',
    (tester) async {
      var rows = <_Row>[
        (id: 'g1', code: 'G1', name: '第一行', version: 7, writable: true),
        (id: 'g2', code: 'G2', name: '第二行', version: 9, writable: true),
      ];
      var readFails = false;
      final saved = <(String, int)>[];
      await _pump(
        tester,
        loadPage: (_) async {
          if (readFails) throw ApiException('NETWORK', '刷新连接失败');
          return PagedResult(
            items: rows,
            page: 1,
            size: 20,
            total: 2,
            totalPages: 1,
          );
        },
        save: (id, patch, original) async {
          saved.add((id, original.version));
          rows = [
            for (final row in rows)
              if (row.id == id)
                (
                  id: row.id,
                  code: row.code,
                  name: patch['name'] as String,
                  version: row.version + 1,
                  writable: true,
                )
              else
                row,
          ];
          if (saved.length == 1) readFails = true;
        },
      );
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      expect(_nameInput(), findsNothing);
      await _activateName(tester);
      await tester.enterText(_nameInput().at(0), '第一行已保存');
      await _activateName(tester, 'g2');
      await tester.enterText(_nameInput().at(1), '第二行保留草稿');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存 2 行修改'));
      await tester.pumpAndSettle();
      expect(saved, [('g1', 7)]);
      expect(_nameInput(), findsNWidgets(2));
      expect(
        tester
            .widgetList<TextField>(_nameInput())
            .every((field) => field.readOnly),
        isTrue,
      );
      expect(find.textContaining('修改已保存，但列表刷新失败'), findsWidgets);
      expect(
        tester
            .widget<UtenButton>(find.widgetWithText(UtenButton, '保存 1 行修改'))
            .onPressed,
        isNull,
      );

      readFails = false;
      tester
          .widget<MasterDataTableView<_Row>>(
            find.byType(MasterDataTableView<_Row>),
          )
          .onRetry!();
      await tester.pumpAndSettle();
      expect(find.text('第一行已保存'), findsOneWidget);
      expect(find.text('第二行保留草稿'), findsOneWidget);
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      expect(saved, [('g1', 7), ('g2', 9)]);
      await _activateName(tester);
      await tester.enterText(_nameInput().at(0), '第一行再次修改');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      expect(saved, [('g1', 7), ('g2', 9), ('g1', 8)]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pagination requires an explicit decision about unsaved cell changes',
    (tester) async {
      var saves = 0;
      await _pump(tester, totalPages: 2, save: (_, _, _) async => saves++);
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      await _activateName(tester);
      await tester.enterText(_nameInput(), '未保存翻页草稿');
      final table = tester.widget<MasterDataTableView<_Row>>(
        find.byType(MasterDataTableView<_Row>),
      );
      table.onPageChange!(2);
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('未保存翻页草稿'), findsOneWidget);
      expect(
        tester
            .widget<MasterDataTableView<_Row>>(
              find.byType(MasterDataTableView<_Row>),
            )
            .currentPage,
        1,
      );
      expect(saves, 0);
    },
  );

  setUpAll(() async {
    if (Platform.environment['MASTER_INLINE_PREVIEW'] != '1') return;
    final loader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await loader.load();
  });
  testWidgets(
    'edit mode writes changed cells with original row version and keeps code read-only',
    (tester) async {
      final saves = <(String, Map<String, dynamic>, _Row)>[];
      await _pump(
        tester,
        save: (id, patch, original) async => saves.add((id, patch, original)),
      );
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      expect(_nameInput(), findsNothing);
      await _activateName(tester);
      expect(_nameInput(), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == '编号',
        ),
        findsNothing,
      );
      final table = tester.widget<MasterDataTableView<_Row>>(
        find.byType(MasterDataTableView<_Row>),
      );
      expect(table.onRowTap, isNull);
      await tester.enterText(_nameInput(), '新名称');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      expect(saves, hasLength(1));
      expect(saves.single.$1, 'g1');
      expect(saves.single.$2, {'name': '新名称'});
      expect(saves.single.$3.version, 7);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel confirms draft discard and sends no writes', (
    tester,
  ) async {
    var saves = 0;
    await _pump(tester, save: (_, _, _) async => saves++);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await _activateName(tester);
    await tester.enterText(_nameInput(), '未保存');
    await tester.tap(find.text('取消编辑'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(_nameInput(), findsOneWidget);
    await tester.tap(find.text('取消编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(_nameInput(), findsNothing);
    expect(saves, 0);
  });

  testWidgets(
    'goods discard exits a clean edit session without writes or reloading the table',
    (tester) async {
      var saves = 0;
      var reads = 0;
      await _pump(
        tester,
        inlineCancelLabel: '不保存并退出',
        inlineDiscardNote: '仅放弃尚未保存的修改，已保存成功的修改会保留。',
        loadPage: (_) async {
          reads++;
          return const PagedResult(
            items: [
              (id: 'g1', code: 'G1', name: '原名称', version: 7, writable: true),
            ],
            page: 1,
            size: 20,
            total: 1,
            totalPages: 1,
          );
        },
        save: (_, _, _) async => saves++,
      );
      final tableState = tester.state(find.byType(MasterDataTableView<_Row>));
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      expect(find.text('取消编辑'), findsNothing);
      await tester.tap(find.text('不保存并退出'));
      await tester.pumpAndSettle();
      expect(find.text('编辑模式'), findsOneWidget);
      expect(find.text('放弃未保存的修改？'), findsNothing);
      expect(tester.state(find.byType(MasterDataTableView<_Row>)), tableState);
      expect(saves, 0);
      expect(reads, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'goods discard asks once and continuing preserves the draft before explicit discard',
    (tester) async {
      var saves = 0;
      await _pump(
        tester,
        inlineCancelLabel: '不保存并退出',
        inlineDiscardNote: '仅放弃尚未保存的修改，已保存成功的修改会保留。',
        save: (_, _, _) async => saves++,
      );
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      await _activateName(tester);
      await tester.enterText(_nameInput(), '本次未保存');
      await tester.tap(find.widgetWithText(UtenButton, '不保存并退出'));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      expect(find.text('仅放弃尚未保存的修改，已保存成功的修改会保留。'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '不保存并退出'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_nameInput()).controller!.text, '本次未保存');
      await tester.tap(find.widgetWithText(UtenButton, '不保存并退出'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '不保存并退出'));
      await tester.pumpAndSettle();
      expect(find.text('编辑模式'), findsOneWidget);
      expect(find.text('原名称'), findsOneWidget);
      expect(find.text('本次未保存'), findsNothing);
      expect(saves, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'goods discard after a partial save keeps committed rows and drops only remaining drafts',
    (tester) async {
      var rows = <_Row>[
        (id: 'g1', code: 'G1', name: '第一行', version: 7, writable: true),
        (id: 'g2', code: 'G2', name: '第二行', version: 9, writable: true),
      ];
      var reads = 0;
      final saved = <String>[];
      await _pump(
        tester,
        inlineCancelLabel: '不保存并退出',
        inlineDiscardNote: '仅放弃尚未保存的修改，已保存成功的修改会保留。',
        loadPage: (_) async {
          reads++;
          return PagedResult(
            items: rows,
            page: 1,
            size: 20,
            total: 2,
            totalPages: 1,
          );
        },
        save: (id, patch, original) async {
          saved.add(id);
          if (id == 'g2') throw ApiException('CONFLICT', '第二行保存失败');
          rows = [
            for (final row in rows)
              if (row.id == id)
                (
                  id: row.id,
                  code: row.code,
                  name: patch['name'] as String,
                  version: row.version + 1,
                  writable: true,
                )
              else
                row,
          ];
        },
      );
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      await _activateName(tester);
      await tester.enterText(_nameInput(), '第一行已保存');
      await _activateName(tester, 'g2');
      await tester.enterText(_nameInput().at(1), '第二行未保存');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存 2 行修改'));
      await tester.pumpAndSettle();
      expect(saved, ['g1', 'g2']);
      expect(find.text('保存 1 行修改'), findsOneWidget);
      final readsBeforeDiscard = reads;
      await tester.tap(find.widgetWithText(UtenButton, '不保存并退出'));
      await tester.pumpAndSettle();
      expect(find.text('仅放弃尚未保存的修改，已保存成功的修改会保留。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '不保存并退出'));
      await tester.pumpAndSettle();
      expect(find.text('第一行已保存'), findsOneWidget);
      expect(find.text('第二行'), findsOneWidget);
      expect(find.text('第二行未保存'), findsNothing);
      expect(find.text('编辑模式'), findsOneWidget);
      expect(saved, ['g1', 'g2']);
      expect(reads, readsBeforeDiscard);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('view-only and object read-only rows cannot expose cell inputs', (
    tester,
  ) async {
    await _pump(tester, canEdit: false, save: (_, _, _) async {});
    expect(find.text('编辑模式'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester, writable: false, save: (_, _, _) async {});
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    expect(_nameInput(), findsNothing);
    expect(find.text('HP001'), findsWidgets);
  });

  testWidgets('invalid required field stays in draft without server writes', (
    tester,
  ) async {
    var saves = 0;
    await _pump(tester, save: (_, _, _) async => saves++);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await _activateName(tester);
    await tester.enterText(_nameInput(), '');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存 1 行修改'));
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(_nameInput(), findsOneWidget);
  });

  testWidgets(
    'edit actions remain usable on a narrow viewport at large text scale',
    (tester) async {
      await _pump(
        tester,
        size: const Size(390, 844),
        textScale: 2,
        save: (_, _, _) async {},
      );
      await tester.ensureVisible(find.text('编辑模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      await _activateName(tester);
      await tester.enterText(_nameInput(), '窄屏修改');
      await tester.pumpAndSettle();
      expect(find.text('取消编辑'), findsOneWidget);
      expect(find.text('保存 1 行修改'), findsOneWidget);
      await tester.ensureVisible(find.text('保存 1 行修改'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('保存 1 行修改')).bottom,
        lessThanOrEqualTo(844),
      );
      expect(tester.takeException(), isNull);
      if (Platform.environment['MASTER_INLINE_PREVIEW'] == '1') {
        await tester.runAsync(() async {
          final boundary =
              _previewKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final pixels = await boundary.toImage();
          final bytes = await pixels.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '.tmp-master-inline-preview-narrow.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          pixels.dispose();
        });
      }
    },
  );
}
