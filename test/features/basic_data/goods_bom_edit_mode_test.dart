import '../../support/table_read_status.dart';
import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_picker_icon_button.dart';
import 'package:uten_imp/components/inputs/uten_reference_picker_field.dart';
import 'package:uten_imp/components/inputs/uten_inline_edit_cell.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_ancestor_row_window.dart'
    show UtenRowMountPlaceholder;
import 'package:uten_imp/components/data_display/uten_table_row_drag.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/providers/goods_clipboard.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import '../../support/audit_screenshot_support.dart';
import '../../support/goods_bom_edit_test_api.dart' show activateBomEditor;

final _permissions = NotifierProvider<_Permissions, Set<String>>(
  _Permissions.new,
);

class _Permissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => {
    Perm.goodsView,
    Perm.goodsBomEdit,
    Perm.goodsBomCreate,
    Perm.goodsBomDelete,
    Perm.goodsBomAudit,
  };

  void replace(Set<String> value) => state = value;
}

Map<String, dynamic> _row(String id, String component, String name) => {
  'id': id,
  'componentGoodsId': component,
  'componentName': name,
  'componentCode': 'C-$component',
  'componentUnitName': '个',
  'qty': 2,
  'controlStage': 'FINISH',
  'consumptionBasis': 'PER_PACKAGE',
  'basisOutputQty': 10,
  'allowPartialPackage': false,
  'hardGate': true,
  'systemLearned': true,
  'actualQty': 3,
  'actualSampleCount': 8,
  'auditedAt': '2026-01-01T00:00:00Z',
};

class _Api extends ApiClient {
  _Api() : super(Dio());

  final commands = <(String, Map<String, dynamic>)>[];
  List<String> previewWarnings = const [];
  Completer<GoodsBomItem>? pendingAudit;
  final pendingSnapshots = <String, Completer<Map<String, dynamic>>>{};
  final snapshotCalls = <String>[];
  VoidCallback? onSnapshotRead;
  Completer<void>? pendingPreview;
  Completer<void>? pendingCommit;
  ApiException? commitFailure;
  bool masterWritable = false;
  bool includeMasterBatch = true;
  int learningCalls = 0;
  Completer<GoodsBomLearningSummary>? pendingLearning;
  final pendingCanonical = <String, Completer<List<GoodsBomItem>>>{};
  final canonicalCalls = <String>[];
  final tree = <String, List<Map<String, dynamic>>>{
    'source': [
      _row('row-frame', 'frame', '铁架'),
      _row('row-screw', 'screw', '螺丝'),
    ],
    'target': [_row('row-nut', 'nut', '螺母')],
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/snapshot')) {
      final goodsId = path.split('/').reversed.elementAt(3);
      snapshotCalls.add(goodsId);
      onSnapshotRead?.call();
      final pending = pendingSnapshots[goodsId];
      if (pending != null) return pending.future;
      return {
        'items': tree[goodsId] ?? [],
        'fingerprint': 'fp-$goodsId',
        'goods': {
          'id': goodsId,
          'version': 4,
          'model': '旧型号',
          'spec': '旧规格',
          'material': '旧材质',
          'sourceType': '采购',
          'componentGoodsWritable': masterWritable,
        },
        if (includeMasterBatch)
          'componentGoods': [
            for (final row in tree[goodsId] ?? <Map<String, dynamic>>[])
              {
                'id': row['componentGoodsId'],
                'version': 4,
                'model': '旧型号',
                'spec': '旧规格',
                'material': '旧材质',
                'sourceType': '采购',
                'componentGoodsWritable': masterWritable,
              },
          ],
      };
    }
    final id = path.split('/').last;
    return {
      'id': id,
      'name': switch (id) {
        'frame' => '铁架',
        'screw' => '螺丝',
        _ => id,
      },
      'unitName': '个',
      'issueMethod': 'ORDER',
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    final request = Map<String, dynamic>.from(body! as Map);
    commands.add((path, request));
    if (path.endsWith('/preview')) {
      await pendingPreview?.future;
      return {
        'previewToken': 'review',
        'operationCount': (request['operations'] as List).length,
        'affectedParents': [
          {'goodsId': 'frame', 'goodsName': '铁架', 'otherUsageCount': 3},
        ],
        'otherUsageCount': 3,
        'warnings': previewWarnings,
      };
    }
    await pendingCommit?.future;
    if (commitFailure case final failure?) throw failure;
    return {};
  }
}

class _Repository extends Fake implements GoodsBomRepository {
  _Repository(this.api);
  final _Api api;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    api.canonicalCalls.add(goodsId);
    if (api.pendingCanonical[goodsId] case final pending?) {
      return pending.future;
    }
    return [
      for (final row in api.tree[goodsId] ?? const <Map<String, dynamic>>[])
        GoodsBomItem.fromJson(row),
    ];
  }

  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) async {
    api.learningCalls++;
    return api.pendingLearning?.future ?? const GoodsBomLearningSummary();
  }

  @override
  Future<GoodsBomItem> setAudited(
    String goodsId,
    String itemId,
    bool audited,
  ) async {
    if (api.pendingAudit case final pending?) return pending.future;
    return GoodsBomItem.fromJson(
      api.tree[goodsId]!.firstWhere((row) => row['id'] == itemId),
    );
  }
}

class _Fixture {
  _Fixture(this.api, this.container, this.goodsId);
  final _Api api;
  final ProviderContainer container;
  final ValueNotifier<String> goodsId;
}

Future<_Fixture> _pump(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  double textScale = 1,
  Brightness brightness = Brightness.light,
  void Function(_Api)? configure,
  ValueChanged<bool>? onInteractionChanged,
  ValueChanged<bool>? onEditModeChanged,
  VoidCallback? onDataChanged,
  Future<List<GoodsListItem>> Function()? chooseComponents,
  Future<GoodsListItem?> Function()? replaceComponent,
  Future<List<GoodsListItem>> Function(String)? suggestComponents,
  bool canEditGoods = false,
  List<ColorListItem> colors = const [
    ColorListItem(id: 'color-red', name: '红色'),
  ],
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = _Api();
  configure?.call(api);
  final container = ProviderContainer(
    overrides: [
      localServerReachableProvider.overrideWith(
        (ref) => LocalServerReachabilityNotifier(null, web: true),
      ),
      if (suggestComponents != null)
        bomComponentSuggestionsProvider.overrideWithValue(
          (ref, query) => suggestComponents(query),
        ),
      apiClientProvider.overrideWithValue(api),
      colorDictProvider.overrideWith((ref) async => colors),
      goodsBomRepositoryProvider.overrideWithValue(_Repository(api)),
      if (chooseComponents != null)
        bomComponentPickerProvider.overrideWithValue(
          (_, _) => chooseComponents(),
        ),
      if (replaceComponent != null)
        bomComponentSinglePickerProvider.overrideWithValue(
          (_, _) => replaceComponent(),
        ),
      currentPermissionsProvider.overrideWith(
        (ref) => {...ref.watch(_permissions), if (canEditGoods) Perm.goodsEdit},
      ),
      isSuperAdminProvider.overrideWithValue(false),
      sensitiveReadBoundaryProvider.overrideWith(
        (ref) => SensitiveReadBoundary(
          identity: null,
          api: api,
          permissions: ref.watch(currentPermissionsProvider),
          superAdmin: false,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final goodsId = ValueNotifier('source');
  addTearDown(goodsId.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: brightness == Brightness.dark
            ? buildDarkTheme()
            : buildLightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: RepaintBoundary(
            key: const Key('bom-test-render'),
            child: child!,
          ),
        ),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: ValueListenableBuilder<String>(
                  valueListenable: goodsId,
                  builder: (_, id, _) => GoodsBomTab(
                    goodsId: id,
                    canCreate: true,
                    canEdit: true,
                    canDelete: true,
                    onInteractionChanged: onInteractionChanged,
                    onEditModeChanged: onEditModeChanged,
                    onDataChanged: onDataChanged,
                  ),
                ),
              ),
              const Align(
                alignment: Alignment.topCenter,
                child: AppNotificationHost(),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Fixture(api, container, goodsId);
}

Future<void> _edit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
  await tester.pumpAndSettle();
}

Future<void> _menu(WidgetTester tester, String name) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await _showTreeColumns(tester);
  await tester.tap(
    find.text(name).first,
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

Future<void> _showTreeColumns(WidgetTester tester) async {
  // Quantity editors can be on the far right of this wide table. Return to
  // its hierarchy column before exercising the actual pointer/menu action.
  // First let the preceding native edit's scheduled caret reveal finish, so
  // it cannot override the subsequent deliberate horizontal navigation.
  await tester.pumpAndSettle();
  for (final state in tester.stateList<ScrollableState>(
    find.byType(Scrollable),
  )) {
    if (state.position.axis == Axis.horizontal && state.position.pixels != 0) {
      state.position.jumpTo(0);
    }
  }
  await tester.pumpAndSettle();
  final viewport = tester.getRect(find.byType(MaterialApp));
  final targets = find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> &&
        (key.value.startsWith('goods-bom-tree-cell-') ||
            key.value.startsWith('goods-bom-tree-toggle-'));
  });
  for (final target in targets.evaluate()) {
    final point = tester.getCenter(
      find.byElementPredicate((element) => identical(element, target)),
    );
    if (point.dy > viewport.top && point.dy < viewport.bottom) {
      expect(
        viewport.contains(point),
        isTrue,
        reason:
            'Tree pointer target ${target.widget.key} must be inside the visible viewport',
      );
    }
  }
}

Future<void> _stageFrameDeletion(WidgetTester tester) async {
  await _edit(tester);
  await _menu(tester, '铁架');
  await tester.tap(find.text('删除').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('goods-bom-batch-delete-confirm')));
  await tester.pumpAndSettle();
  expect(find.text('铁架'), findsNothing);
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('UTEN_CAPTURE_BOM_TABLE')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('bom-test-render')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(
      'build/task-visual-checks/screenshot-fixes-20261025-$name.png',
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets(
    'independent new row queries do not block choosing another component',
    (tester) async {
      final fixture = await _pump(
        tester,
        suggestComponents: (_) async => const [],
      );
      await _edit(tester);
      final first = find.byKey(const ValueKey('goods-bom-name-new:0'));
      final second = find.byKey(const ValueKey('goods-bom-name-new:1'));
      await tester.enterText(
        find.descendant(of: first, matching: find.byType(TextField)),
        '螺母',
      );
      await tester.enterText(
        find.descendant(of: second, matching: find.byType(TextField)),
        '垫片',
      );
      tester
          .widget<UtenReferencePickerField<GoodsListItem>>(second)
          .onSelected(
            const GoodsListItem(id: 'washer', name: '垫片', unitName: '个'),
          );
      await tester.pumpAndSettle();
      expect(find.text('垫片'), findsOneWidget);
      expect(
        tester
            .widget<UtenReferencePickerField<GoodsListItem>>(first)
            .controller
            .text,
        '螺母',
      );
      tester
          .widget<UtenReferencePickerField<GoodsListItem>>(first)
          .onSelected(
            const GoodsListItem(id: 'nut', name: '螺母', unitName: '个'),
          );
      await tester.pumpAndSettle();
      await _edit(tester);
      final operations = (fixture.api.commands.single.$2['operations'] as List)
          .cast<Map<String, dynamic>>();
      expect(
        operations.map(
          (operation) =>
              (operation['body'] as Map<String, dynamic>)['componentGoodsId'],
        ),
        ['washer', 'nut'],
      );
    },
  );

  testWidgets(
    'a pending old master read cannot block a replacement product edit session',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      final fixture = await _pump(
        tester,
        canEditGoods: true,
        configure: (api) {
          api.masterWritable = true;
          api.includeMasterBatch = false;
          api.pendingSnapshots['frame'] = pending;
        },
      );
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(fixture.api.snapshotCalls, contains('frame'));
      fixture.goodsId.value = 'target';
      await tester.pumpAndSettle();
      await _edit(tester);
      expect(pending.isCompleted, isFalse);
      expect(fixture.api.snapshotCalls, contains('nut'));
      final model = await activateBomEditor(
        tester,
        'goods-bom-master-model-target/row-nut',
      );
      expect(model, findsOneWidget);
      pending.complete({
        'items': <Object>[],
        'fingerprint': 'late',
        'goods': {
          'id': 'frame',
          'version': 1,
          'model': '旧会话回执',
          'componentGoodsWritable': true,
        },
      });
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(model).controller!.text, '旧型号');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'equal edit snapshots retain rows and viewport while inactive cells mount no editors',
    (tester) async {
      final learning = Completer<GoodsBomLearningSummary>();
      final fixture = await _pump(
        tester,
        canEditGoods: true,
        configure: (api) {
          api.masterWritable = true;
          api.pendingLearning = learning;
          api.tree['source'] = [
            for (var index = 0; index < 100; index++)
              {
                ..._row('edge-$index', 'part-$index', '组件$index'),
                'componentModel': '旧型号',
                'componentSourceType': '采购',
                'componentStockQty': index + 12,
              },
          ];
        },
      );
      final tableFinder = find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView,
      );
      final tableState = tester.state(tableFinder);
      final readRows = tester
          .widget<MasterDataTableView<dynamic>>(tableFinder)
          .items;
      final viewport = tester.getRect(tableFinder);
      final firstSlot = find.byKey(
        const ValueKey('row-drag-slot:source/edge-0'),
      );
      final readSlotElement = tester.element(firstSlot);
      expect(find.byType(UtenRowMountPlaceholder), findsNothing);
      final pendingSnapshot = Completer<Map<String, dynamic>>();
      fixture.api.pendingSnapshots['source'] = pendingSnapshot;
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getRect(tableFinder), viewport);
        expect(tester.state(tableFinder), same(tableState));
        expect(tester.element(firstSlot), same(readSlotElement));
        expect(find.byType(UtenRowMountPlaceholder), findsNothing);
        expect(
          tester.widget<MasterDataTableView<dynamic>>(tableFinder).items,
          same(readRows),
        );
      }
      pendingSnapshot.complete({
        'items': fixture.api.tree['source'],
        'fingerprint': 'stable',
        'componentGoods': [
          for (final row in fixture.api.tree['source']!)
            {
              'id': row['componentGoodsId'],
              'version': 4,
              'model': '旧型号',
              'sourceType': '采购',
              'componentGoodsWritable': true,
            },
        ],
      });
      // A same-data mode change must not recreate deferred row mounts and
      // briefly replace already visible rows with budget placeholders.
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.element(firstSlot), same(readSlotElement));
        expect(find.byType(UtenRowMountPlaceholder), findsNothing);
      }
      await tester.pumpAndSettle();
      final editableTable = tester.widget<MasterDataTableView<dynamic>>(
        tableFinder,
      );
      expect(editableTable.items, same(readRows));
      expect(tester.state(tableFinder), same(tableState));
      expect(tester.getRect(tableFinder), viewport);
      expect(find.byType(UtenInlineEditCell), findsWidgets);
      expect(find.byType(UtenDropdownField), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.key is ValueKey<String> &&
              ((widget.key! as ValueKey<String>).value.startsWith(
                    'goods-bom-master-',
                  ) ||
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'goods-bom-inline-',
                  )),
        ),
        findsNothing,
      );
      final model = find.byKey(
        const ValueKey('goods-bom-master-model-source/edge-0'),
      );
      await tester.tap(
        find.byKey(const ValueKey('goods-bom-activate-model-source/edge-0')),
      );
      await tester.pump();
      final native = find.descendant(
        of: model,
        matching: find.byType(EditableText),
      );
      final editorState = tester.state<EditableTextState>(native);
      await tester.enterText(model, '型号输入');
      const composed = TextEditingValue(
        text: '型号输入',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 2, end: 4),
      );
      tester.testTextInput.updateEditingValue(composed);
      await tester.pump();
      final controller = tester.widget<TextField>(model).controller!;
      final appendRows = editableTable.appendRows;
      final columns = editableTable.columns;
      for (final selection in <Set<String>>[
        {'source|edge-0'},
        {},
      ]) {
        tester
            .widget<MasterDataTableView<dynamic>>(tableFinder)
            .onSelectedIdsChanged!(selection);
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.state<EditableTextState>(native), same(editorState));
          expect(
            tester.widget<EditableText>(native).focusNode.hasFocus,
            isTrue,
          );
          expect(controller.value, composed);
          final table = tester.widget<MasterDataTableView<dynamic>>(
            tableFinder,
          );
          expect(table.items, same(readRows));
          expect(table.appendRows, same(appendRows));
          expect(table.columns, same(columns));
        }
      }
      learning.complete(
        const GoodsBomLearningSummary(
          materialEvidence: [
            GoodsBomMaterialEvidence(
              source: 'DAILY_REPORT',
              status: 'PENDING',
              componentGoodsId: 'late',
              componentName: '延迟选料',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('bom-selected-materials-notice')),
        findsNothing,
      );
      expect(tester.getRect(tableFinder), viewport);
      expect(tester.state<EditableTextState>(native), same(editorState));
      expect(controller.value, composed);
      final bom = tester.state<GoodsBomTabState>(find.byType(GoodsBomTab));
      await bom.refresh();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 80));
      expect(fixture.api.canonicalCalls, ['source']);
      expect(fixture.api.snapshotCalls, ['source']);
      expect(tester.state<EditableTextState>(native), same(editorState));
      expect(controller.value, composed);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      await tester.pumpAndSettle();
      final operation =
          (fixture.api.commands.single.$2['operations'] as List).single as Map;
      expect(operation['type'], 'UPDATE_GOODS');
      expect(operation['goodsChanges'], {'model': '型号输入'});
      expect(operation['goodsId'], 'part-0');
      await tester.tap(find.byKey(const Key('goods-bom-discard-and-exit')));
      await tester.pumpAndSettle();
      expect(
        fixture.api.commands.where((command) => command.$1.endsWith('/commit')),
        isEmpty,
      );
      expect(
        find.byKey(const Key('bom-selected-materials-notice')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a replaced component starts fresh lazy editors instead of inheriting activation',
    (tester) async {
      final fixture = await _pump(
        tester,
        replaceComponent: () async =>
            const GoodsListItem(id: 'nut', name: '螺母', unitName: '个'),
      );
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      await tester.pumpAndSettle();
      final activation = find.byKey(
        const ValueKey('goods-bom-activate-name-source/row-frame'),
      );
      final oldState = tester.state(
        find.ancestor(
          of: activation,
          matching: find.byType(UtenInlineEditCell),
        ),
      );
      await tester.tap(activation);
      await tester.pumpAndSettle();
      final editor = find.byKey(
        const ValueKey('goods-bom-name-row:source|row-frame'),
      );
      expect(editor, findsOneWidget);
      final picker = tester.widget<UtenPickerIconButton>(
        find.byKey(const ValueKey('goods-bom-replace-source/row-frame')),
      );
      await picker.onPressed!();
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      expect(activation, findsOneWidget);
      final replacementState = tester.state(
        find.ancestor(
          of: activation,
          matching: find.byType(UtenInlineEditCell),
        ),
      );
      expect(replacementState, isNot(same(oldState)));
      expect(find.text('螺母'), findsOneWidget);
      await tester.tap(activation);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenReferencePickerField<GoodsListItem>>(editor)
            .controller
            .text,
        '螺母',
      );
      expect(fixture.api.tree['source']!.first['componentGoodsId'], 'frame');
      expect(fixture.api.commands, isEmpty);
    },
  );

  testWidgets(
    'collapsed lazy color previews retain the newly selected code and save only that change',
    (tester) async {
      final fixture = await _pump(
        tester,
        colors: const [ColorListItem(id: 'color-code', code: 'YL')],
        configure: (api) {
          api.tree['source']!.first['hasChildren'] = true;
          api.tree['frame'] = [_row('row-washer', 'washer', '垫片')];
        },
      );
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      await tester.pumpAndSettle();
      final parent = find.byKey(
        const ValueKey('goods-bom-tree-toggle-row-frame'),
      );
      await tester.tap(parent);
      await tester.pumpAndSettle();
      final activation = find.byKey(
        const ValueKey('goods-bom-activate-color-source/row-frame/row-washer'),
      );
      tester.widget<InkWell>(activation).onTap!();
      await tester.pumpAndSettle();
      tester
          .widget<UtenDropdownField>(find.byType(UtenDropdownField))
          .onChanged('color-code');
      await tester.pumpAndSettle();
      await tester.tap(parent);
      await tester.pumpAndSettle();
      await tester.tap(parent);
      await tester.pumpAndSettle();
      expect(find.byType(UtenDropdownField), findsNothing);
      expect(find.text('YL'), findsOneWidget);
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      await tester.pumpAndSettle();
      final operation =
          (fixture.api.commands.single.$2['operations'] as List).single as Map;
      expect(operation['type'], 'UPDATE');
      expect(operation['goodsId'], 'frame');
      expect(operation['body'], {
        'componentGoodsId': 'washer',
        'colorId': 'color-code',
      });
      await tester.tap(find.byKey(const Key('goods-bom-discard-and-exit')));
      await tester.pumpAndSettle();
      expect(fixture.api.tree['frame']!.single['colorId'], isNull);
    },
  );

  testWidgets(
    'batched master snapshots publish together and selection scrolling resume never refetch',
    (tester) async {
      final fixture = await _pump(
        tester,
        canEditGoods: true,
        configure: (api) {
          api.masterWritable = true;
          api.tree['source'] = [
            for (var index = 0; index < 160; index++)
              {
                ..._row('edge-$index', 'part-$index', '组件$index'),
                'componentModel': '旧型号',
                'componentSourceType': '采购',
                'componentStockQty': index + 12,
              },
          ];
        },
      );
      await _edit(tester);
      expect(fixture.api.snapshotCalls, ['source']);
      final tableFinder = find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView,
      );
      final initial = tester.widget<MasterDataTableView<dynamic>>(tableFinder);
      final modelFinder = await activateBomEditor(
        tester,
        'goods-bom-master-model-source/edge-0',
      );
      final editor = tester.widget<TextField>(modelFinder).controller;
      for (final selected in <Set<String>>[
        {'source|edge-0'},
        {},
      ]) {
        tester
            .widget<MasterDataTableView<dynamic>>(tableFinder)
            .onSelectedIdsChanged!(selected);
        await tester.pumpAndSettle();
        final rebuilt = tester.widget<MasterDataTableView<dynamic>>(
          tableFinder,
        );
        expect(identical(rebuilt.items, initial.items), isTrue);
        expect(identical(rebuilt.columns, initial.columns), isTrue);
        expect(tester.widget<TextField>(modelFinder).controller, same(editor));
      }
      final learningCalls = fixture.api.learningCalls;
      final bom = tester.state<GoodsBomTabState>(find.byType(GoodsBomTab));
      await bom.refresh();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      final scroll = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .firstWhere(
            (state) =>
                state.position.axis == Axis.vertical &&
                state.position.maxScrollExtent > 500,
          );
      final scrollFinder = find.byElementPredicate(
        (element) =>
            element is StatefulElement && identical(element.state, scroll),
      );
      await tester.drag(scrollFinder, const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(0));
      expect(fixture.api.snapshotCalls, ['source']);
      expect(fixture.api.canonicalCalls, ['source']);
      expect(fixture.api.learningCalls, learningCalls);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shared relation shown in two expanded paths moves only once', (
    tester,
  ) async {
    final fixture = await _pump(
      tester,
      configure: (api) {
        api.tree['source'] = [
          {..._row('frame-path', 'frame', '组件甲'), 'hasChildren': true},
          {..._row('nested-path', 'nested', '组件乙'), 'hasChildren': true},
        ];
        api.tree['frame'] = [
          {..._row('shared-a', 'shared', '共用子件'), 'hasChildren': true},
        ];
        api.tree['nested'] = [
          {..._row('shared-b', 'shared', '共用子件'), 'hasChildren': true},
        ];
        api.tree['shared'] = [_row('bolt-edge', 'bolt', '共用螺栓')];
      },
    );
    await _edit(tester);
    for (final id in ['frame-path', 'nested-path', 'shared-a', 'shared-b']) {
      await tester.tap(find.byKey(ValueKey('goods-bom-tree-toggle-$id')));
      await tester.pumpAndSettle();
    }
    var table = tester.widget<MasterDataTableView<dynamic>>(
      find.byWidgetPredicate((widget) => widget is MasterDataTableView).first,
    );
    table.onSelectedIdsChanged!({'shared|bolt-edge'});
    await tester.pumpAndSettle();
    table = tester.widget<MasterDataTableView<dynamic>>(
      find.byWidgetPredicate((widget) => widget is MasterDataTableView).first,
    );
    // Feature-private row identity is accessed only through the public table callbacks.
    // ignore: avoid_dynamic_calls
    final aliases = table.items
        .where((row) => (table as dynamic).idOf(row) == 'shared|bolt-edge')
        .toList();
    expect(aliases, hasLength(2));
    // ignore: avoid_dynamic_calls
    final payload =
        (table.rowDrag as dynamic).dragRowsOf(aliases.first) as List<dynamic>;
    expect(payload, hasLength(1));
    // ignore: avoid_dynamic_calls
    final dropped =
        (table.rowDrag as dynamic).onDrop(
              payload,
              table.items.first,
              UtenTableRowDropMode.into,
            )
            as Future<void>;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await dropped;
    await _edit(tester);
    final operation =
        (fixture.api.commands.single.$2['operations'] as List).single
            as Map<String, dynamic>;
    expect(operation['type'], 'MOVE');
    expect(operation['moves'], hasLength(1));
    expect(
      (operation['moves'] as List).single,
      containsPair('itemId', 'bolt-edge'),
    );
  });

  testWidgets(
    'uncertain commit locks mutation fields and retries the same reviewed receipt',
    (tester) async {
      final fixture = await _pump(
        tester,
        canEditGoods: true,
        configure: (api) => api.masterWritable = true,
      );
      await _edit(tester);
      await tester.enterText(
        await activateBomEditor(
          tester,
          'goods-bom-inline-qty-source/row-frame',
        ),
        '5',
      );
      await tester.enterText(
        await activateBomEditor(
          tester,
          'goods-bom-master-model-source/row-frame',
        ),
        '新型号',
      );
      fixture.api.commitFailure = ApiException('NETWORK_TIMEOUT', '请求超时');
      await _edit(tester);
      await tester.tap(find.byKey(const Key('goods-bom-save-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续保留草稿'));
      await tester.pumpAndSettle();
      final qty = tester.widget<TextField>(
        await activateBomEditor(
          tester,
          'goods-bom-inline-qty-source/row-frame',
        ),
      );
      final model = tester.widget<TextField>(
        await activateBomEditor(
          tester,
          'goods-bom-master-model-source/row-frame',
        ),
      );
      expect(qty.enabled, isFalse);
      expect(model.enabled, isFalse);
      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
      final table = tester.widget<MasterDataTableView<dynamic>>(
        find.byWidgetPredicate((widget) => widget is MasterDataTableView).first,
      );
      expect(table.rowDrag, isNotNull);
      for (final row in table.items) {
        // Feature-private row types remain behind the public drag contract.
        // ignore: avoid_dynamic_calls
        expect((table.rowDrag as dynamic).canDragRow(row), isFalse);
        // ignore: avoid_dynamic_calls
        expect(
          (table.rowDrag as dynamic).canDrop(row, table.items.sublist(0, 1)),
          isFalse,
        );
        // ignore: avoid_dynamic_calls
        expect(
          (table.rowDrag as dynamic).canDropInto(
            row,
            table.items.sublist(0, 1),
          ),
          isFalse,
        );
      }
      qty.onChanged!('999');
      model.onChanged!('不应接受');
      final reviewed = fixture.api.commands.last.$2;
      fixture.api.commitFailure = null;
      await _edit(tester);
      expect(
        fixture.api.commands.where(
          (command) => command.$1.endsWith('/preview'),
        ),
        hasLength(1),
      );
      await tester.tap(find.byKey(const Key('goods-bom-save-confirm')));
      await tester.pumpAndSettle();
      final retries = fixture.api.commands
          .where((command) => command.$1.endsWith('/commit'))
          .toList();
      expect(retries, hasLength(2));
      expect(
        retries.last.$2,
        reviewed,
        reason: 'receipt recovery replays the same idempotent reviewed command',
      );
      expect(
        tester
            .state<GoodsBomTabState>(find.byType(GoodsBomTab))
            .hasEditingSession,
        isFalse,
      );
    },
  );

  testWidgets('component master cells share the reviewed atomic BOM save', (
    tester,
  ) async {
    await loadAuditScreenshotFonts(tester);
    final fixture = await _pump(
      tester,
      canEditGoods: true,
      configure: (api) => api.masterWritable = true,
    );
    await _edit(tester);
    await _capture(tester, 'bom-master-edit-1440');
    final model = await activateBomEditor(
      tester,
      'goods-bom-master-model-source/row-frame',
    );
    expect(model, findsOneWidget);
    await tester.enterText(model, '新型号');
    await tester.enterText(
      await activateBomEditor(tester, 'goods-bom-master-spec-source/row-frame'),
      '新规格',
    );
    await tester.enterText(
      await activateBomEditor(tester, 'goods-bom-inline-qty-source/row-frame'),
      '5',
    );
    expect(fixture.api.commands, isEmpty);
    await _edit(tester);
    final operations = (fixture.api.commands.single.$2['operations'] as List)
        .cast<Map<String, dynamic>>();
    final master = operations.singleWhere(
      (operation) => operation['type'] == 'UPDATE_GOODS',
    );
    expect(master['goodsId'], 'frame');
    expect(master['goodsVersion'], 4);
    expect(master['goodsChanges'], {'model': '新型号', 'spec': '新规格'});
    expect(
      operations.singleWhere(
        (operation) => operation['type'] == 'UPDATE',
      )['goodsId'],
      'source',
    );
    await tester.tap(find.byKey(const Key('goods-bom-discard-and-exit')));
    await tester.pumpAndSettle();
    expect(
      fixture.api.commands.where((command) => command.$1.endsWith('/commit')),
      isEmpty,
    );
    expect(fixture.api.tree['source']!.first['qty'], 2);
  });

  testWidgets('master cells remain read only without object write capability', (
    tester,
  ) async {
    await _pump(tester, canEditGoods: true);
    await _edit(tester);
    expect(
      await activateBomEditor(
        tester,
        'goods-bom-master-model-source/row-frame',
      ),
      findsNothing,
    );
    expect(
      await activateBomEditor(tester, 'goods-bom-inline-qty-source/row-frame'),
      findsOneWidget,
    );
  });

  testWidgets('inline values survive replacing a component before save', (
    tester,
  ) async {
    final fixture = await _pump(
      tester,
      replaceComponent: () async =>
          const GoodsListItem(id: 'washer', name: '垫片', unitName: '个'),
    );
    await _edit(tester);
    await tester.enterText(
      await activateBomEditor(tester, 'goods-bom-inline-qty-source/row-frame'),
      '7',
    );
    await tester.enterText(
      await activateBomEditor(
        tester,
        'goods-bom-inline-summary-source/row-frame',
      ),
      '新备注',
    );
    final picker = tester.widget<UtenPickerIconButton>(
      await activateBomEditor(tester, 'goods-bom-replace-source/row-frame'),
    );
    await picker.onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('垫片'), findsOneWidget);
    await _edit(tester);
    final operations = (fixture.api.commands.single.$2['operations'] as List)
        .cast<Map<String, dynamic>>();
    expect((operations.last['body'] as Map)['qty'], 7);
    expect((operations.last['body'] as Map)['summary'], '新备注');
    expect((operations.last['body'] as Map)['componentGoodsId'], 'washer');
  });

  testWidgets('inline values flush before cross-parent drag', (tester) async {
    final fixture = await _pump(tester);
    await _edit(tester);
    await tester.enterText(
      await activateBomEditor(tester, 'goods-bom-inline-qty-source/row-frame'),
      '7',
    );
    final table = tester.widget<MasterDataTableView<dynamic>>(
      find.byWidgetPredicate((widget) => widget is MasterDataTableView).first,
    );
    // Keep the feature-private row list's runtime type at this integration seam.
    // Pointer mechanics are covered by goods_bom_row_drag_move_test.dart.
    // ignore: avoid_dynamic_calls
    final dropped =
        (table.rowDrag as dynamic).onDrop(
              table.items.sublist(0, 1),
              table.items.last,
              UtenTableRowDropMode.into,
            )
            as Future<void>;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await dropped;
    await _edit(tester);
    final operations = (fixture.api.commands.single.$2['operations'] as List)
        .cast<Map<String, dynamic>>();
    expect(operations.map((operation) => operation['type']), [
      'UPDATE',
      'MOVE',
    ]);
    expect((operations.first['body'] as Map)['qty'], 7);
    expect(
      ((operations.last['moves'] as List).single
          as Map<String, dynamic>)['targetParentGoodsId'],
      'screw',
    );
  });

  testWidgets(
    'dialog editing starts from flushed values and refreshes inline editors',
    (tester) async {
      final fixture = await _pump(tester);
      await _edit(tester);
      await tester.enterText(
        await activateBomEditor(
          tester,
          'goods-bom-inline-qty-source/row-frame',
        ),
        '7',
      );
      await _menu(tester, '铁架');
      await tester.tap(find.text('编辑').last);
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('goods-bom-edit-qty'));
      expect(
        find.descendant(of: field, matching: find.text('7')),
        findsOneWidget,
      );
      await tester.enterText(field, '8');
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();
      final inline = tester.widget<TextField>(
        await activateBomEditor(
          tester,
          'goods-bom-inline-qty-source/row-frame',
        ),
      );
      expect(inline.controller!.text, '8');
      await _edit(tester);
      final operations = (fixture.api.commands.single.$2['operations'] as List)
          .cast<Map<String, dynamic>>();
      expect((operations.last['body'] as Map)['qty'], 8);
    },
  );

  testWidgets(
    'typed append lookup ranks exact matches and stages selected identity',
    (tester) async {
      final queries = <String>[];
      final fixture = await _pump(
        tester,
        suggestComponents: (query) async {
          queries.add(query);
          return const [
            GoodsListItem(id: 'nut-other', name: '螺母配套', unitName: '个'),
            GoodsListItem(id: 'nut', name: '螺母', unitName: '个'),
          ];
        },
      );
      await _edit(tester);
      final name = find.descendant(
        of: find.byKey(const ValueKey('goods-bom-name-new:0')),
        matching: find.byType(TextField),
      );
      await tester.enterText(name, '螺母');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(queries, ['螺母']);
      final options = find.byType(ListTile);
      expect(
        tester.widget<ListTile>(options.first).title,
        isA<Text>().having((text) => text.data, 'closest name', '螺母'),
      );
      await tester.tap(find.widgetWithText(ListTile, '螺母'));
      await tester.pumpAndSettle();
      expect(fixture.api.commands, isEmpty);
      await _edit(tester);
      final operation =
          (fixture.api.commands.single.$2['operations'] as List).single as Map;
      expect(operation['goodsId'], 'source');
      expect((operation['body'] as Map)['componentGoodsId'], 'nut');
    },
  );

  testWidgets(
    'editing a nested quantity survives collapsing its parent before save',
    (tester) async {
      final fixture = await _pump(
        tester,
        configure: (api) {
          api.tree['source']!.first['hasChildren'] = true;
          api.tree['frame'] = [_row('row-washer', 'washer', '垫片')];
        },
      );
      await _edit(tester);
      await tester.tap(
        find.byKey(const ValueKey('goods-bom-tree-toggle-row-frame')),
      );
      await tester.pumpAndSettle();
      final qty = await activateBomEditor(
        tester,
        'goods-bom-inline-qty-source/row-frame/row-washer',
      );
      await tester.enterText(qty, '7.25');
      await _showTreeColumns(tester);
      await tester.tap(
        find.byKey(const ValueKey('goods-bom-tree-toggle-row-frame')),
      );
      await tester.pumpAndSettle();
      expect(qty.hitTestable(), findsNothing);
      final collapsed = tester.widget<MasterDataTableView<dynamic>>(
        find.byWidgetPredicate((widget) => widget is MasterDataTableView),
      );
      expect(
        collapsed.items.map((row) {
          // Keep the private row function's runtime type at this integration seam.
          // ignore: avoid_dynamic_calls
          return (collapsed as dynamic).idOf(row);
        }),
        isNot(contains('frame|row-washer')),
      );
      await _edit(tester);
      final operation =
          (fixture.api.commands.single.$2['operations'] as List).single as Map;
      expect(operation['goodsId'], 'frame');
      expect(operation['itemId'], 'row-washer');
      expect((operation['body'] as Map)['qty'], 7.25);
      expect((operation['body'] as Map).containsKey('price'), isFalse);
    },
  );

  testWidgets('unselected typed new component keeps editing session open', (
    tester,
  ) async {
    final fixture = await _pump(
      tester,
      suggestComponents: (_) async => const [],
    );
    await _edit(tester);
    final name = find.descendant(
      of: find.byKey(const ValueKey('goods-bom-name-new:0')),
      matching: find.byType(TextField),
    );
    await tester.enterText(name, '尚未选定');
    await _edit(tester);
    expect(fixture.api.commands, isEmpty);
    expect(
      tester
          .state<GoodsBomTabState>(find.byType(GoodsBomTab))
          .hasEditingSession,
      isTrue,
    );
  });

  testWidgets(
    'table append rows multi-select components into one reviewed draft',
    (tester) async {
      await loadAuditScreenshotFonts(tester);
      final fixture = await _pump(
        tester,
        chooseComponents: () async => const [
          GoodsListItem(id: 'nut', name: '螺母', unitName: '个'),
          GoodsListItem(id: 'washer', name: '垫片', unitName: '个'),
        ],
      );
      expect(
        find.byKey(const ValueKey('goods-bom-choose-new-0')),
        findsNothing,
      );
      await _edit(tester);
      final table = tester.widget<MasterDataTableView<dynamic>>(
        find.byWidgetPredicate((widget) => widget is MasterDataTableView).first,
      );
      expect(table.appendRows, hasLength(3));
      expect(find.byTooltip('替换组件'), findsNothing);
      expect(
        find.byKey(const ValueKey('goods-bom-activate-name-source/row-frame')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('goods-bom-activate-name-source/row-screw')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('goods-bom-add-child-header')), findsNothing);
      expect(find.byTooltip('添加下级组件'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('goods-bom-choose-new-0')));
      await tester.pumpAndSettle();
      expect(find.text('螺母'), findsOneWidget);
      expect(find.text('垫片'), findsOneWidget);
      expect(fixture.api.tree['source'], hasLength(2));
      expect(fixture.api.commands, isEmpty);
      expect(
        tester
            .widget<MasterDataTableView<dynamic>>(
              find
                  .byWidgetPredicate((widget) => widget is MasterDataTableView)
                  .first,
            )
            .appendRows,
        hasLength(3),
      );
      await _capture(tester, 'bom-table-entry-1440');
      await _edit(tester);
      final operations = (fixture.api.commands.single.$2['operations'] as List)
          .cast<Map<String, dynamic>>();
      expect(operations.map((op) => op['type']), ['CREATE', 'CREATE']);
      expect(operations.map((op) => op['goodsId']), everyElement('source'));
      expect(
        operations.map((op) => (op['body'] as Map)['qty']),
        everyElement(1),
      );
      expect(
        operations.every((op) => !(op['body'] as Map).containsKey('price')),
        isTrue,
      );
      await tester.tap(find.byKey(const Key('goods-bom-save-confirm')));
      await tester.pumpAndSettle();
      expect(fixture.api.commands.last.$1, endsWith('/commit'));
    },
  );

  testWidgets('cancelling table multi-picker adds no rows or edit commands', (
    tester,
  ) async {
    final fixture = await _pump(tester, chooseComponents: () async => []);
    await _edit(tester);
    await tester.tap(find.byKey(const ValueKey('goods-bom-choose-new-0')));
    await tester.pumpAndSettle();
    await _edit(tester);
    expect(fixture.api.commands, isEmpty);
    expect(find.text('编辑模式'), findsOneWidget);
  });

  testWidgets(
    'existing component picker replaces only the draft relation and discard restores it',
    (tester) async {
      final fixture = await _pump(
        tester,
        replaceComponent: () async => const GoodsListItem(
          id: 'washer',
          name: '垫片',
          unitName: '个',
          material: 'PA',
        ),
      );
      await _edit(tester);
      await tester.tap(
        await activateBomEditor(tester, 'goods-bom-replace-source/row-frame'),
      );
      await tester.pumpAndSettle();
      expect(find.text('垫片'), findsOneWidget);
      expect(find.text('铁架'), findsNothing);
      expect(fixture.api.commands, isEmpty);
      expect(fixture.api.tree['source']!.first['componentGoodsId'], 'frame');
      await _edit(tester);
      final operation =
          (fixture.api.commands.single.$2['operations'] as List).single as Map;
      expect(operation['type'], 'UPDATE');
      expect(operation['goodsId'], 'source');
      expect(operation['itemId'], 'row-frame');
      final body = operation['body'] as Map;
      expect(body['componentGoodsId'], 'washer');
      expect(body['qty'], 2);
      expect(body['consumptionBasis'], 'PER_PACKAGE');
      expect(body['basisOutputQty'], 10);
      expect(body.containsKey('price'), isFalse);
      await tester.tap(find.byKey(const Key('goods-bom-discard-and-exit')));
      await tester.pumpAndSettle();
      expect(find.text('铁架'), findsOneWidget);
      expect(
        fixture.api.commands.where((call) => call.$1.endsWith('/commit')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'leaf action creates a blank child then stages it under the correct component',
    (tester) async {
      final fixture = await _pump(
        tester,
        chooseComponents: () async => const [
          GoodsListItem(id: 'washer', name: '垫片', unitName: '个'),
        ],
      );
      await _edit(tester);
      await tester.tap(find.byTooltip('添加下级组件').first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('goods-bom-name-child:frame')),
        findsOneWidget,
      );
      await _capture(tester, 'bom-leaf-new-child-1440');
      final childInput = find.descendant(
        of: find.byKey(const ValueKey('goods-bom-name-child:frame')),
        matching: find.byType(TextField),
      );
      await tester.enterText(childInput, '垫');
      await tester.tap(
        find.byKey(const ValueKey('goods-bom-tree-toggle-row-frame')),
      );
      await tester.pumpAndSettle();
      expect(childInput, findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('goods-bom-tree-toggle-row-frame')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(childInput).controller!.text, '垫');
      expect(fixture.api.commands, isEmpty);
      final cell = tester.widget<Widget>(
        find.byKey(const ValueKey('goods-bom-tree-cell-row-frame')),
      );
      expect(cell, isNotNull);
      await tester.tap(
        find.byKey(const ValueKey('goods-bom-choose-child:frame')),
      );
      await tester.pumpAndSettle();
      expect(find.text('垫片'), findsOneWidget);
      await _edit(tester);
      final operation =
          (fixture.api.commands.single.$2['operations'] as List).single as Map;
      expect(operation['goodsId'], 'frame');
      expect((operation['body'] as Map)['componentGoodsId'], 'washer');
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'periodic table picks require reviewed grams before staging the complete selection',
    (tester) async {
      final fixture = await _pump(
        tester,
        chooseComponents: () async => const [
          GoodsListItem(
            id: 'resin',
            name: '塑料',
            unitName: '千克',
            issueMethod: GoodsIssueMethod.periodic,
            periodicCostBasis: GoodsPeriodicCostBasis.own,
          ),
        ],
      );
      await _edit(tester);
      await tester.tap(find.byKey(const ValueKey('goods-bom-choose-new-0')));
      // The originating picker remains busy while this quantity dialog awaits
      // user input; its intentional spinner must not be awaited to settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('goods-bom-edit-qty')), findsOneWidget);
      expect(fixture.api.commands, isEmpty);
      await tester.enterText(
        find.byKey(const Key('goods-bom-edit-qty')),
        '2.5',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('塑料'), findsOneWidget);
      expect(fixture.api.commands, isEmpty);
      await _edit(tester);
      final operation =
          (fixture.api.commands.single.$2['operations'] as List).single as Map;
      expect((operation['body'] as Map)['unitWeightGrams'], 2.5);
      expect((operation['body'] as Map).containsKey('price'), isFalse);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'table picker controls remain reachable at 390 width and 2x text',
    (tester) async {
      await loadAuditScreenshotFonts(tester);
      await _pump(
        tester,
        size: const Size(390, 844),
        textScale: 2,
        chooseComponents: () async => [],
      );
      await _edit(tester);
      final picker = find.byKey(const ValueKey('goods-bom-choose-new-0'));
      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();
      expect(picker.hitTestable(), findsOneWidget);
      final exit = find.byKey(const Key('goods-bom-edit-mode'));
      await tester.ensureVisible(exit);
      await tester.pumpAndSettle();
      final exitRect = tester.getRect(exit);
      expect(exitRect.left, greaterThanOrEqualTo(0));
      expect(exitRect.right, lessThanOrEqualTo(390));
      expect(exitRect.bottom, lessThanOrEqualTo(844));
      expect(exit.hitTestable(), findsOneWidget);
      await tester.tap(exit);
      await tester.pumpAndSettle();
      expect(
        tester
            .state<GoodsBomTabState>(find.byType(GoodsBomTab))
            .hasEditingSession,
        isFalse,
      );
      await tester.ensureVisible(exit);
      await _edit(tester);
      if (const bool.fromEnvironment('UTEN_CAPTURE_BOM_TABLE')) {
        // ensureVisible targets the picker at the end of the name column.
        // Restore the ordinary leftmost table view for the screenshot.
        for (final scroll in tester.stateList<ScrollableState>(
          find.byType(Scrollable),
        )) {
          if (axisDirectionToAxis(scroll.axisDirection) == Axis.horizontal &&
              scroll.position.hasPixels) {
            scroll.position.jumpTo(0);
          }
        }
        await tester.pumpAndSettle();
      }
      await _capture(tester, 'bom-table-entry-390-2x');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'discard and exit restores canonical assembly without saving and releases navigation',
    (tester) async {
      final modes = <bool>[];
      final interactions = <bool>[];
      var canonicalChanges = 0;
      final fixture = await _pump(
        tester,
        onEditModeChanged: modes.add,
        onInteractionChanged: interactions.add,
        onDataChanged: () => canonicalChanges++,
      );
      await _stageFrameDeletion(tester);
      await tester.tap(find.text('螺丝'));
      await tester.pumpAndSettle();
      final state = tester.state<GoodsBomTabState>(find.byType(GoodsBomTab));
      final finishing = state.finishEditing();
      await tester.pumpAndSettle();
      expect(find.text('不保存并退出'), findsOneWidget);
      expect(find.text('继续编辑'), findsOneWidget);
      expect(find.byKey(const Key('goods-bom-save-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('goods-bom-discard-and-exit')));
      await tester.pumpAndSettle();

      expect(await finishing, isTrue);
      expect(state.hasEditingSession, isFalse);
      expect(modes, [true, false]);
      expect(interactions, [true, false]);
      expect(canonicalChanges, 0);
      expect(fixture.api.commands.single.$1, endsWith('/preview'));
      expect(fixture.api.tree['source'], hasLength(2));
      expect(find.text('铁架'), findsOneWidget);
      expect(find.text('螺丝'), findsOneWidget);
      expect(find.text('编辑模式'), findsOneWidget);
      for (final checkbox in tester.widgetList<Checkbox>(
        find.byType(Checkbox),
      )) {
        expect(checkbox.value, isFalse);
      }
    },
  );

  testWidgets(
    'discard hides abandoned draft while waiting for canonical reload',
    (tester) async {
      final fixture = await _pump(tester);
      await _stageFrameDeletion(tester);
      final canonical = fixture.api.pendingCanonical['source'] =
          Completer<List<GoodsBomItem>>();
      final state = tester.state<GoodsBomTabState>(find.byType(GoodsBomTab));
      final finishing = state.finishEditing();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goods-bom-discard-and-exit')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(state.hasEditingSession, isFalse);
      expect(find.text('螺丝'), findsNothing);
      expect(find.text('铁架'), findsNothing);
      expect(fixture.api.commands.single.$1, endsWith('/preview'));
      canonical.complete([
        for (final row in fixture.api.tree['source']!)
          GoodsBomItem.fromJson(row),
      ]);
      await tester.pumpAndSettle();
      expect(await finishing, isTrue);
      expect(find.text('铁架'), findsOneWidget);
      expect(find.text('螺丝'), findsOneWidget);
    },
  );

  testWidgets(
    'failed canonical reload after discard never leaves abandoned draft visible',
    (tester) async {
      final fixture = await _pump(tester);
      await _stageFrameDeletion(tester);
      final canonical = fixture.api.pendingCanonical['source'] =
          Completer<List<GoodsBomItem>>();
      final state = tester.state<GoodsBomTabState>(find.byType(GoodsBomTab));
      final finishing = state.finishEditing();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goods-bom-discard-and-exit')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      canonical.completeError(ApiException('NETWORK', '正式组装清单读取失败'));
      await tester.pumpAndSettle();

      expect(await finishing, isTrue);
      expect(state.hasEditingSession, isFalse);
      await expectTableReadFailureDetails(tester, '正式组装清单读取失败');
      expect(find.text('螺丝'), findsNothing);
      expect(find.text('铁架'), findsNothing);
      expect(fixture.api.commands.single.$1, endsWith('/preview'));
    },
  );

  testWidgets(
    'stale discard consent cannot close a replacement product edit session',
    (tester) async {
      final fixture = await _pump(tester);
      await _stageFrameDeletion(tester);
      final toggle = tester
          .widget<UtenButton>(find.byKey(const Key('goods-bom-edit-mode')))
          .onPressed!;
      final state = tester.state<GoodsBomTabState>(find.byType(GoodsBomTab));
      final finishing = state.finishEditing();
      await tester.pumpAndSettle();
      fixture.goodsId.value = 'target';
      await tester.pumpAndSettle();
      toggle();
      await tester.pumpAndSettle();
      expect(state.hasEditingSession, isTrue);
      expect(fixture.api.snapshotCalls.last, 'target');
      await tester.tap(find.byKey(const Key('goods-bom-discard-and-exit')));
      await tester.pumpAndSettle();

      expect(await finishing, isFalse);
      expect(state.hasEditingSession, isTrue);
      expect(find.text('螺母'), findsOneWidget);
      expect(find.text('退出编辑模式'), findsOneWidget);
      expect(fixture.api.commands.single.$1, endsWith('/preview'));
    },
  );

  testWidgets(
    'three save consent actions remain reachable on narrow screens with 2x text',
    (tester) async {
      await loadAuditScreenshotFonts(tester);
      await _pump(tester, textScale: 2);
      await _stageFrameDeletion(tester);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpAndSettle();
      final state = tester.state<GoodsBomTabState>(find.byType(GoodsBomTab));
      final finishing = state.finishEditing();
      await tester.pumpAndSettle();
      for (final action in [
        find.text('继续编辑'),
        find.byKey(const Key('goods-bom-discard-and-exit')),
        find.byKey(const Key('goods-bom-save-confirm')),
      ]) {
        expect(action, findsOneWidget);
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        final rect = tester.getRect(action);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(390));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(844));
        expect(action.hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await _capture(tester, 'bom-discard-consent-390-2x');
      await tester.tap(find.byKey(const Key('goods-bom-discard-and-exit')));
      await tester.pumpAndSettle();
      expect(await finishing, isTrue);
    },
  );

  testWidgets(
    'uncertain commit offers refresh without promising unsaved exit and reads actual canonical data',
    (tester) async {
      var canonicalChanges = 0;
      final fixture = await _pump(
        tester,
        onDataChanged: () => canonicalChanges++,
      );
      await _stageFrameDeletion(tester);
      fixture.api.commitFailure = ApiException('NETWORK_TIMEOUT', '请求超时');
      await _edit(tester);
      await tester.tap(find.byKey(const Key('goods-bom-save-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('放弃草稿并刷新'), findsOneWidget);
      await tester.tap(find.text('继续保留草稿'));
      await tester.pumpAndSettle();
      fixture.api.tree['source'] = [_row('row-actual', 'actual', '服务端正式组件')];
      final state = tester.state<GoodsBomTabState>(find.byType(GoodsBomTab));
      final finishing = state.finishEditing();
      await tester.pumpAndSettle();

      expect(find.text('不保存并退出'), findsNothing);
      expect(find.textContaining('保存结果暂时无法确认'), findsOneWidget);
      expect(find.text('放弃草稿并刷新'), findsOneWidget);
      await tester.tap(find.byKey(const Key('goods-bom-discard-and-exit')));
      await tester.pumpAndSettle();
      expect(await finishing, isTrue);
      expect(state.hasEditingSession, isFalse);
      expect(find.text('服务端正式组件'), findsOneWidget);
      expect(find.text('螺丝'), findsNothing);
      expect(
        fixture.api.commands.where((row) => row.$1.endsWith('/commit')),
        hasLength(1),
      );
      expect(canonicalChanges, 0);
    },
  );

  testWidgets(
    'history interlock spans pending entry, draft, consent and canonical commit',
    (tester) async {
      final interactions = <bool>[];
      final modes = <bool>[];
      var canonicalChanges = 0;
      final fixture = await _pump(
        tester,
        onInteractionChanged: interactions.add,
        onEditModeChanged: modes.add,
        onDataChanged: () => canonicalChanges++,
      );
      final snapshot = fixture.api.pendingSnapshots['source'] =
          Completer<Map<String, dynamic>>();
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      expect(interactions, [true]);
      expect(modes, isEmpty);
      await tester.pump();
      await tester.pump();
      snapshot.complete({
        'items': fixture.api.tree['source'],
        'fingerprint': 'ready',
      });
      await tester.pumpAndSettle();
      expect(modes, [true]);
      expect(interactions, [true]);
      await _menu(tester, '铁架');
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goods-bom-batch-delete-confirm')));
      await tester.pumpAndSettle();
      expect(canonicalChanges, 0);
      await _edit(tester);
      expect(find.byKey(const Key('goods-bom-save-confirm')), findsOneWidget);
      expect(interactions, [true]);
      fixture.api.pendingCommit = Completer<void>();
      await tester.tap(find.byKey(const Key('goods-bom-save-confirm')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(canonicalChanges, 0);
      expect(interactions, [true]);
      fixture.api.pendingCommit!.complete();
      await tester.pumpAndSettle();
      expect(canonicalChanges, 1);
      expect(modes, [true, false]);
      expect(interactions, [true, false]);
    },
  );

  testWidgets(
    'failed or revoked entry releases history interlock without canonical mutation',
    (tester) async {
      final interactions = <bool>[];
      var canonicalChanges = 0;
      final fixture = await _pump(
        tester,
        onInteractionChanged: interactions.add,
        onDataChanged: () => canonicalChanges++,
      );
      final failed = fixture.api.pendingSnapshots['source'] =
          Completer<Map<String, dynamic>>();
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      await tester.pump();
      await tester.pump();
      failed.completeError(ApiException('INTERNAL', '快照读取失败'));
      await tester.pumpAndSettle();
      expect(interactions, [true, false]);
      final revoked = fixture.api.pendingSnapshots['source'] =
          Completer<Map<String, dynamic>>();
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      await tester.pump();
      await tester.pump();
      fixture.container.read(_permissions.notifier).replace({Perm.goodsView});
      await tester.pumpAndSettle();
      expect(interactions, [true, false, true, false]);
      revoked.complete({
        'items': fixture.api.tree['source'],
        'fingerprint': 'late',
      });
      await tester.pumpAndSettle();
      expect(interactions, [true, false, true, false]);
      expect(canonicalChanges, 0);
      expect(find.text('退出编辑模式'), findsNothing);
    },
  );

  testWidgets(
    'audit writes and learning dialogs hold their own history interlock',
    (tester) async {
      final interactions = <bool>[];
      final fixture = await _pump(
        tester,
        onInteractionChanged: interactions.add,
      );
      fixture.api.pendingAudit = Completer<GoodsBomItem>();
      await tester.tap(find.byKey(const Key('goods-bom-audit-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('已核对，点击取消').first);
      await tester.pump();
      expect(interactions, [true]);
      fixture.api.pendingAudit!.complete(
        GoodsBomItem.fromJson(fixture.api.tree['source']!.first),
      );
      await tester.pumpAndSettle();
      expect(interactions, [true, false]);
      await tester.tap(find.byKey(const Key('goods-bom-learning')));
      await tester.pumpAndSettle();
      expect(interactions, [true, false, true]);
      Navigator.of(tester.element(find.byType(GoodsBomTab))).pop();
      await tester.pumpAndSettle();
      expect(interactions, [true, false, true, false]);
    },
  );

  testWidgets(
    'history release after widget replacement may safely rebuild the host',
    (tester) async {
      late _Fixture fixture;
      var replaceAfterRelease = false;
      final interactions = <bool>[];
      fixture = await _pump(
        tester,
        onInteractionChanged: (interacting) {
          interactions.add(interacting);
          if (!interacting && replaceAfterRelease) {
            replaceAfterRelease = false;
            fixture.goodsId.value = 'replacement';
          }
        },
      );
      await _edit(tester);
      expect(interactions, [true]);
      replaceAfterRelease = true;
      fixture.goodsId.value = 'target';
      await tester.pumpAndSettle();
      expect(interactions, [true, false]);
      expect(fixture.goodsId.value, 'replacement');
      expect(tester.takeException(), isNull);
      expect(fixture.api.commands, isEmpty);
    },
  );

  testWidgets(
    'slow edit entry paints feedback first and keeps the selected table interactive',
    (tester) async {
      final fixture = await _pump(tester);
      final pending = Completer<Map<String, dynamic>>();
      fixture.api.pendingSnapshots['source'] = pending;
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      final tableFinder = find.byWidgetPredicate(
        (widget) => widget is MasterDataTableView,
      );
      final table = tester.state(tableFinder.first);
      final rows = tester
          .widget<MasterDataTableView<Object?>>(tableFinder.first)
          .items;
      var feedbackPainted = false;
      tester.binding.addPostFrameCallback((_) => feedbackPainted = true);
      fixture.api.onSnapshotRead = () {
        expect(feedbackPainted, isTrue);
        expect(
          find.byKey(const Key('goods-bom-read-progress')),
          findsOneWidget,
        );
      };

      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      expect(fixture.api.snapshotCalls, isEmpty);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(fixture.api.snapshotCalls, ['source']);
      expect(find.text('铁架'), findsOneWidget);
      expect(find.text('退出编辑模式'), findsNothing);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
      expect(
        identical(
          tester.widget<MasterDataTableView<Object?>>(tableFinder.first).items,
          rows,
        ),
        isTrue,
      );
      // Waiting for a backend snapshot does not block read-only interaction.
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).at(1)).value,
        isTrue,
      );
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).at(2)).value,
        isTrue,
      );
      pending.complete({
        'items': fixture.api.tree['source'],
        'fingerprint': 'ready',
      });
      await tester.pumpAndSettle();
      expect(identical(tester.state(tableFinder.first), table), isTrue);
      expect(find.text('退出编辑模式'), findsOneWidget);
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).at(1)).value,
        isTrue,
      );
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).at(2)).value,
        isTrue,
      );
    },
  );

  testWidgets('a large tree preserves scrolling while snapshots are prepared', (
    tester,
  ) async {
    final fixture = await _pump(
      tester,
      configure: (api) {
        api.tree['source'] = [
          for (var i = 0; i < 512; i++) _row('edge-$i', 'item-$i', '大清单组件$i'),
        ];
      },
    );
    final pending = Completer<Map<String, dynamic>>();
    fixture.api.pendingSnapshots['source'] = pending;
    final scroll = tester
        .stateList<ScrollableState>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        )
        .firstWhere((state) => state.position.maxScrollExtent > 500);
    final vertical = find.byElementPredicate(
      (element) =>
          element is StatefulElement && identical(element.state, scroll),
    );
    await tester.drag(vertical, const Offset(0, -1200));
    await tester.pumpAndSettle();
    final before = scroll.position.pixels;
    expect(before, greaterThan(0));
    await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
    await tester.pump();
    await tester.pump();
    expect(scroll.position.pixels, closeTo(before, 0.1));
    await tester.drag(vertical, const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 250));
    expect(scroll.position.pixels, greaterThan(before));
    final beforeAdoption = scroll.position.pixels;
    pending.complete({
      'items': fixture.api.tree['source'],
      'fingerprint': 'large',
    });
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThanOrEqualTo(beforeAdoption));
    expect(find.text('退出编辑模式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a failed edit snapshot stays read only and preserves the table',
    (tester) async {
      final fixture = await _pump(tester);
      final pending = Completer<Map<String, dynamic>>();
      fixture.api.pendingSnapshots['source'] = pending;
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      await tester.pump();
      await tester.pump();
      pending.completeError(ApiException('INTERNAL', '服务器暂时不可用'));
      await tester.pumpAndSettle();
      expect(find.text('服务器暂时不可用'), findsOneWidget);
      expect(find.text('铁架'), findsOneWidget);
      expect(find.text('退出编辑模式'), findsNothing);
      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).at(1)).value,
        isTrue,
      );
    },
  );

  testWidgets(
    'permission revocation cancels pending entry before any late snapshot',
    (tester) async {
      final fixture = await _pump(tester);
      final pending = Completer<Map<String, dynamic>>();
      fixture.api.pendingSnapshots['source'] = pending;
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      await tester.pump();
      await tester.pump();
      fixture.container.read(_permissions.notifier).replace({Perm.goodsView});
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goods-bom-read-progress')), findsNothing);
      pending.complete({
        'items': [_row('late', 'late', '过时快照')],
        'fingerprint': 'late',
      });
      await tester.pumpAndSettle();
      expect(find.text('过时快照'), findsNothing);
      expect(find.text('铁架'), findsOneWidget);
      expect(find.text('退出编辑模式'), findsNothing);
      expect(fixture.api.commands, isEmpty);
    },
  );

  testWidgets('expanded siblings load concurrently with a four-request bound', (
    tester,
  ) async {
    final fixture = await _pump(
      tester,
      configure: (api) {
        api.tree['source'] = [
          for (var i = 0; i < 6; i++)
            {..._row('row-part-$i', 'part-$i', '组件$i'), 'hasChildren': true},
        ];
        for (var i = 0; i < 6; i++) {
          api.tree['part-$i'] = [_row('leaf-$i', 'leaf-$i', '子件$i')];
        }
      },
    );
    for (var i = 0; i < 6; i++) {
      await tester.tap(
        find.byKey(ValueKey('goods-bom-tree-toggle-row-part-$i')),
      );
      await tester.pumpAndSettle();
      fixture.api.pendingSnapshots['part-$i'] =
          Completer<Map<String, dynamic>>();
    }
    await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(fixture.api.snapshotCalls.toSet(), {
      'source',
      'part-0',
      'part-1',
      'part-2',
      'part-3',
    });
    expect(find.text('子件0'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      fixture.api.pendingSnapshots['part-$i']!.complete({
        'items': fixture.api.tree['part-$i'],
        'fingerprint': 'part-$i',
      });
    }
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(fixture.api.snapshotCalls, hasLength(7));
    for (var i = 4; i < 6; i++) {
      fixture.api.pendingSnapshots['part-$i']!.complete({
        'items': fixture.api.tree['part-$i'],
        'fingerprint': 'part-$i',
      });
    }
    await tester.pumpAndSettle();
    expect(find.text('退出编辑模式'), findsOneWidget);
    expect(find.text('子件0'), findsOneWidget);
  });

  testWidgets(
    'one failed expanded snapshot cancels entry while siblings still wait',
    (tester) async {
      final fixture = await _pump(
        tester,
        configure: (api) {
          for (final row in api.tree['source']!) {
            row['hasChildren'] = true;
          }
          api.tree['frame'] = [_row('frame-child', 'washer', '垫片')];
          api.tree['screw'] = [_row('screw-child', 'nut', '螺母')];
        },
      );
      for (final id in ['row-frame', 'row-screw']) {
        await tester.tap(find.byKey(ValueKey('goods-bom-tree-toggle-$id')));
        await tester.pumpAndSettle();
      }
      final failed = fixture.api.pendingSnapshots['frame'] =
          Completer<Map<String, dynamic>>();
      final delayed = fixture.api.pendingSnapshots['screw'] =
          Completer<Map<String, dynamic>>();
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(fixture.api.snapshotCalls.toSet(), {'source', 'frame', 'screw'});
      failed.completeError(ApiException('INTERNAL', '子组件快照暂时不可用'));
      await tester.pumpAndSettle();
      expect(find.text('子组件快照暂时不可用'), findsOneWidget);
      expect(find.byKey(const Key('goods-bom-read-progress')), findsNothing);
      expect(find.text('退出编辑模式'), findsNothing);
      expect(find.text('垫片'), findsOneWidget);
      delayed.complete({
        'items': <Map<String, dynamic>>[],
        'fingerprint': 'late',
      });
      await tester.pumpAndSettle();
      expect(find.text('螺母'), findsOneWidget);
      expect(find.text('退出编辑模式'), findsNothing);
    },
  );

  testWidgets(
    'save feedback covers slow preview and commit but yields to consent',
    (tester) async {
      final fixture = await _pump(tester);
      await _edit(tester);
      await _menu(tester, '铁架');
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goods-bom-batch-delete-confirm')));
      await tester.pumpAndSettle();
      fixture.api.pendingPreview = Completer<void>();
      final exit = tester
          .widget<UtenButton>(find.byKey(const Key('goods-bom-edit-mode')))
          .onPressed!;
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      expect(fixture.api.commands, isEmpty);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.text('正在检查修改范围'), findsOneWidget);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      exit();
      await tester.pump();
      expect(fixture.api.commands, hasLength(1));
      fixture.api.pendingPreview!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.byKey(const Key('goods-bom-save-confirm')), findsOneWidget);
      exit();
      await tester.pump();
      expect(fixture.api.commands, hasLength(1));
      fixture.api.pendingCommit = Completer<void>();
      await tester.tap(find.byKey(const Key('goods-bom-save-confirm')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.text('正在保存组装信息'), findsOneWidget);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(fixture.api.commands, hasLength(2));
      fixture.api.pendingCommit!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.text('编辑模式'), findsOneWidget);
    },
  );

  testWidgets(
    'revoking permission while preview waits never opens consent or commits',
    (tester) async {
      final fixture = await _pump(tester);
      await _edit(tester);
      await _menu(tester, '铁架');
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goods-bom-batch-delete-confirm')));
      await tester.pumpAndSettle();
      fixture.api.pendingPreview = Completer<void>();
      await tester.tap(find.byKey(const Key('goods-bom-edit-mode')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(fixture.api.commands, hasLength(1));
      fixture.container.read(_permissions.notifier).replace({Perm.goodsView});
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlay), findsNothing);
      fixture.api.pendingPreview!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goods-bom-save-confirm')), findsNothing);
      expect(fixture.api.commands, hasLength(1));
      expect(find.text('退出编辑模式'), findsNothing);
    },
  );

  testWidgets(
    'default is read only and create/delete cannot grant entry without edit permission',
    (tester) async {
      final fixture = await _pump(tester);
      expect(find.text('编辑模式'), findsOneWidget);
      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
      expect(find.byKey(const Key('goods-bom-delete-selected')), findsNothing);
      await _menu(tester, '铁架');
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).at(1)).value,
        isTrue,
      );
      expect(find.text('添加子组件'), findsNothing);
      expect(find.text('粘贴'), findsNothing);
      fixture.container.read(_permissions.notifier).replace({
        Perm.goodsView,
        Perm.goodsBomCreate,
        Perm.goodsBomDelete,
      });
      await tester.pumpAndSettle();
      expect(find.text('编辑模式'), findsNothing);
      expect(fixture.api.commands, isEmpty);
    },
  );

  testWidgets(
    'delete is only staged and all shared changes wait for reviewed confirmation',
    (tester) async {
      final fixture = await _pump(tester);
      fixture.api.previewWarnings = ['单个重量与货品资料单重相差超过 20%，请核对'];
      await _edit(tester);
      expect(find.text('退出编辑模式'), findsOneWidget);
      await _menu(tester, '铁架');
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('goods-bom-batch-delete-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('铁架'), findsNothing);
      expect(fixture.api.commands, isEmpty);
      expect(fixture.api.tree['source'], hasLength(2));
      await _edit(tester);
      expect(find.textContaining('其他 3 处'), findsOneWidget);
      expect(find.text('单个重量与货品资料单重相差超过 20%，请核对'), findsOneWidget);
      expect(fixture.api.commands.single.$1, endsWith('/preview'));
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('退出编辑模式'), findsOneWidget);
      expect(fixture.api.commands, hasLength(1));
      await _edit(tester);
      await tester.tap(find.byKey(const Key('goods-bom-save-confirm')));
      await tester.pumpAndSettle();
      expect(fixture.api.commands.last.$1, endsWith('/commit'));
      expect(fixture.api.commands.last.$2['confirmSharedChanges'], isTrue);
      expect(find.text('编辑模式'), findsOneWidget);
    },
  );

  testWidgets(
    'edit permission alone does not expose create, paste, import or delete actions',
    (tester) async {
      final fixture = await _pump(tester);
      fixture.container.read(_permissions.notifier).replace({
        Perm.goodsView,
        Perm.goodsBomEdit,
      });
      await tester.pumpAndSettle();
      await _edit(tester);
      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
      expect(find.byKey(const Key('goods-bom-import')), findsNothing);
      expect(find.byKey(const Key('goods-bom-delete-selected')), findsNothing);
      await _menu(tester, '铁架');
      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('添加子组件'), findsNothing);
      expect(find.text('删除'), findsNothing);
      expect(find.text('粘贴'), findsNothing);
    },
  );

  testWidgets(
    'permission changes release old audit waits and discard late responses',
    (tester) async {
      final fixture = await _pump(tester);
      final pending = fixture.api.pendingAudit = Completer<GoodsBomItem>();
      await tester.tap(find.byKey(const Key('goods-bom-audit-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('已核对，点击取消').first);
      await tester.pump();
      fixture.container.read(_permissions.notifier).replace({
        Perm.goodsView,
        Perm.goodsBomEdit,
      });
      await tester.pumpAndSettle();
      expect(find.text('铁架'), findsOneWidget);
      expect(find.text('退出审计'), findsNothing);
      pending.complete(
        const GoodsBomItem(
          id: 'row-frame',
          componentGoodsId: 'frame',
          componentName: '过时数据',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('过时数据'), findsNothing);
    },
  );

  testWidgets(
    'right click preserves a multi-selection and copies design values to another product child',
    (tester) async {
      final fixture = await _pump(tester);
      await _edit(tester);
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pumpAndSettle();
      await _menu(tester, '铁架');
      await tester.tap(find.text('复制').last);
      await tester.pumpAndSettle();
      expect(
        fixture.container.read(goodsClipboardProvider).bomItems,
        hasLength(2),
      );
      fixture.goodsId.value = 'target';
      await tester.pumpAndSettle();
      await _edit(tester);
      await _menu(tester, '螺母');
      await tester.tap(find.text('粘贴').last);
      await tester.pumpAndSettle();
      expect(find.text('铁架'), findsOneWidget);
      expect(find.text('螺丝'), findsOneWidget);
      expect(fixture.api.commands, isEmpty);
      await _edit(tester);
      final operations = fixture.api.commands.single.$2['operations'] as List;
      expect(operations, hasLength(2));
      for (final operation in operations) {
        final op = Map<String, dynamic>.from(operation as Map);
        expect(op['goodsId'], 'nut');
        final body = op['body'] as Map;
        expect(body['qty'], 2);
        expect(body['controlStage'], 'FINISH');
        expect(body['consumptionBasis'], 'PER_PACKAGE');
        expect(body.containsKey('actualQty'), isFalse);
        expect(body.containsKey('systemLearned'), isFalse);
        expect(body.containsKey('auditedAt'), isFalse);
      }
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'changing permissions invalidates an open dialog and clears clipboard without saving',
    (tester) async {
      final fixture = await _pump(tester);
      await _edit(tester);
      await _menu(tester, '铁架');
      await tester.tap(find.text('复制').last);
      await tester.pumpAndSettle();
      expect(
        fixture.container.read(goodsClipboardProvider).bomItems,
        isNotEmpty,
      );
      await _menu(tester, '铁架');
      await tester.tap(find.text('编辑').last);
      await tester.pumpAndSettle();
      final oldSave = tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '保存').last)
          .onPressed!;
      fixture.container.read(_permissions.notifier).replace({Perm.goodsView});
      await tester.pumpAndSettle();
      expect(find.text('编辑组件'), findsNothing);
      expect(find.text('保存'), findsNothing);
      oldSave();
      await tester.pumpAndSettle();
      expect(fixture.api.commands, isEmpty);
      expect(fixture.container.read(goodsClipboardProvider).bomItems, isNull);
      expect(find.text('退出编辑模式'), findsNothing);
    },
  );

  testWidgets(
    'copying an assembly and its descendant preserves the hierarchy once',
    (tester) async {
      final fixture = await _pump(tester);
      fixture.api.tree['source']!.first['hasChildren'] = true;
      fixture.api.tree['frame'] = [_row('row-washer', 'washer', '垫片')];
      await _edit(tester);
      await tester.tap(
        find.byKey(const ValueKey('goods-bom-tree-toggle-row-frame')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('铁架'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('垫片'));
      await tester.pumpAndSettle();
      await _menu(tester, '铁架');
      await tester.tap(find.text('复制').last);
      await tester.pumpAndSettle();
      expect(
        fixture.container
            .read(goodsClipboardProvider)
            .bomItems!
            .map((row) => row.componentGoodsId),
        ['frame'],
      );
    },
  );

  testWidgets('paste with no selection appends to the product top level', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    await _edit(tester);
    await _menu(tester, '铁架');
    await tester.tap(find.text('复制').last);
    await tester.pumpAndSettle();
    fixture.goodsId.value = 'target';
    await tester.pumpAndSettle();
    await _edit(tester);
    await tester.tapAt(
      const Offset(600, 400),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('粘贴').last);
    await tester.pumpAndSettle();
    expect(find.text('铁架'), findsOneWidget);
    await _edit(tester);
    final operations = fixture.api.commands.single.$2['operations'] as List;
    expect((operations.single as Map)['goodsId'], 'target');
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
  });

  testWidgets('fullscreen retains edit mode and permissions', (tester) async {
    await loadAuditScreenshotFonts(tester);
    await _pump(tester);
    await _edit(tester);
    await tester.tap(
      find.byKey(const ValueKey('master-table-fullscreen-toggle')),
    );
    await tester.pumpAndSettle();
    expect(find.text('退出全屏'), findsOneWidget);
    expect(find.text('退出编辑模式'), findsOneWidget);
    await _menu(tester, '铁架');
    expect(find.text('添加子组件'), findsOneWidget);
    await tester.tapAt(const Offset(1100, 700));
    await tester.pumpAndSettle();
    await _capture(tester, 'bom-edit-fullscreen-1440');
  });

  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    for (final brightness in Brightness.values) {
      testWidgets('mode controls fit at $size in $brightness with 2x text', (
        tester,
      ) async {
        await loadAuditScreenshotFonts(tester);
        await _pump(tester, size: size, brightness: brightness, textScale: 2);
        await _capture(
          tester,
          'bom-readonly-${size.width.toInt()}-${brightness.name}-2x',
        );
        await _edit(tester);
        expect(find.text('退出编辑模式'), findsOneWidget);
        expect(
          find.byKey(const Key('goods-bom-add-component')),
          findsOneWidget,
        );
        for (final key in [
          'goods-bom-add-component',
          'goods-bom-delete-selected',
          'goods-bom-edit-mode',
          'goods-bom-audit-mode',
        ]) {
          await tester.ensureVisible(find.byKey(Key(key)));
          await tester.pumpAndSettle();
          final rect = tester.getRect(find.byKey(Key(key)));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
        }
        await _capture(
          tester,
          'bom-edit-${size.width.toInt()}-${brightness.name}-2x',
        );
      });
    }
  }
}
