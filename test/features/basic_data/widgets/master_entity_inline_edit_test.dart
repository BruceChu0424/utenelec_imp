import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
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

Future<void> _pump(
  WidgetTester tester, {
  bool canEdit = true,
  bool writable = true,
  int totalPages = 1,
  Future<PagedResult<_Row>> Function(MasterPaneQuery)? loadPage,
  Size size = const Size(1200, 850),
  double textScale = 1,
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
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
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
    'lazy preview and its activated editor keep a usable column width and exit restores read-only metadata',
    (tester) async {
      await _pump(tester, save: (_, _, _) async {});
      await tester.tap(find.text('编辑模式'));
      await tester.pumpAndSettle();
      final previewWidth = _nameColumnWidth(tester);
      expect(previewWidth, greaterThanOrEqualTo(140));
      await _activateName(tester);
      expect(_nameColumnWidth(tester), previewWidth);
      await tester.tap(find.text('取消编辑'));
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<_Row>>(
        find.byType(MasterDataTableView<_Row>),
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
      expect(tester.widget<TextField>(_nameInput()).enabled, isFalse);
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
      expect(_nameInput(), findsNothing);
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
