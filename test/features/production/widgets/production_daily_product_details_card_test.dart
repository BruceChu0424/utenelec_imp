import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/production/models/production_direct_transfer_candidate.dart';
import 'package:uten_imp/features/production/repositories/production_material_repository.dart';
import 'package:uten_imp/features/production/widgets/production_daily_grid_columns.dart';
import 'package:uten_imp/features/production/widgets/production_daily_product_details_card.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../../support/audit_screenshot_support.dart';

part 'production_daily_product_details_resize_cases.dart';

const _receiver = 'V5一开单控10A开关功能件与面板总成（带UTEN）及配套安装组件完整接收名称';
const _unitEntries = {'unit': '个'};

class _DetailsData {
  _DetailsData() {
    product = DailyGridRow(localRowId: 'product')
      ..goods = const GoodsOption(
        id: 'goods',
        name: 'V5一开单控功能件',
        code: 'V5G001',
      )
      ..unitId = 'unit'
      ..executionSegmentId = 'source-segment'
      ..executionSegmentCode = 'HP035753'
      ..planId = 'plan'
      ..planItemId = 'plan-item'
      ..directTransferCandidates = const [
        ProductionDirectTransferCandidate(
          demandId: 'A',
          executionSegmentId: 'receiver-a',
          executionSegmentCode: 'HP035754',
          receivingGoodsName: _receiver,
          receivingGoodsCode: 'V5R001',
          receivingColorName: '深灰色',
          remainingQty: 1000,
        ),
        ProductionDirectTransferCandidate(
          demandId: 'B',
          executionSegmentId: 'receiver-b',
          executionSegmentCode: 'HP035756',
          receivingGoodsName: _receiver,
          receivingGoodsCode: 'V5R002',
          receivingColorName: '乳白色',
          remainingQty: 1000,
        ),
        ProductionDirectTransferCandidate(
          demandId: 'C',
          executionSegmentId: 'receiver-c',
          executionSegmentCode: 'HP035757',
          receivingGoodsName: 'V5开关滑杆组件',
          receivingGoodsCode: 'V5R003',
          receivingColorName: '黑色',
          remainingQty: 1000,
        ),
      ]
      ..directTransferRoomBase = {'A': 1000, 'B': 1000, 'C': 1000};
    product.qty.text = '3000';
    for (final id in ['A', 'B', null]) {
      final row = DailyGridRow()
        ..depth = 1
        ..allocationParent = product
        ..allocationDemandId = id;
      row.allocationQty.text = '1000';
      row.allocationAutofilled.value = true;
      allocations.add(row);
    }
    product.allocationRows = allocations;
    for (var i = 0; i < 4; i++) {
      final names = ['V5一开压板', 'V5一开单控10A后座（带UTEN）', 'V5开关打子', 'V5开关滑杆组件'];
      final codes = ['V50010', 'V50014', 'V50026', 'V5ZJ001'];
      final row = DailyGridRow()
        ..depth = 1
        ..materialParent = product
        ..material = ProductionMaterialClearanceRow(
          planId: 'plan',
          demandId: 'material-$i',
          goodsId: 'material-goods-$i',
          goodsCode: codes[i],
          goodsName: names[i],
          colorName: '深灰色',
          unitName: '个',
          requiredQty: 3000,
          issuedQty: 3000,
          returnedQty: 0,
          consumedQty: 0,
          approvedLossQty: 0,
          legalWipQty: 0,
          maxReturnQty: 3000,
          unclearedQty: 3000,
          canClose: false,
          availableToSettleQty: 3000,
        );
      row.materialUsed.text = '3000';
      materials.add(row);
    }
  }
  late final DailyGridRow product;
  final allocations = <DailyGridRow>[];
  final materials = <DailyGridRow>[];
  void dispose() {
    for (final row in [...allocations, ...materials]) {
      row.dispose();
    }
    product.dispose();
  }
}

class _Events {
  int materialChanges = 0, quantityChanges = 0;
  final destinations = <String?>[];
  final focused = <bool>[];
}

class _CardHost extends StatefulWidget {
  const _CardHost({
    super.key,
    required this.data,
    required this.events,
    this.allocationsOpen = true,
    this.materialsOpen = true,
    this.enabled = true,
    this.destinationsEditable = true,
    this.leadingInset = 0,
    this.onAddAllocation,
    this.onRemoveAllocation,
  });
  final _DetailsData data;
  final _Events events;
  final bool allocationsOpen, materialsOpen, enabled;
  final bool destinationsEditable;
  final double leadingInset;
  final VoidCallback? onAddAllocation;
  final ValueChanged<DailyGridRow>? onRemoveAllocation;
  @override
  State<_CardHost> createState() => _CardHostState();
}

class _CardHostState extends State<_CardHost> {
  late bool allocationsOpen = widget.allocationsOpen,
      materialsOpen = widget.materialsOpen;
  late final controller = UtenEditableGridController<DailyGridRow>(
    initial: [widget.data.product],
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = dailyGridColumns(
      context: context,
      onPickGoods: (_) async {},
      onPickSource: (_) async {},
      onClearSource: (_) {},
      colorEntries: const {},
      unitEntries: _unitEntries,
      standaloneDetails: true,
      onMaterialChanged: () => widget.events.materialChanges++,
      onAllocationQtyChanged: (_) => widget.events.quantityChanges++,
      onAllocationQtyFocus: (_, focus) => widget.events.focused.add(focus),
    );
    return UtenEditableGrid<DailyGridRow>(
      controller: controller,
      showAddRow: false,
      showRowDelete: false,
      columns: all
          .where(
            (column) => !const {
              'destination',
              'allocationQty',
              'issuedQty',
              'materialUsed',
            }.contains(column.key),
          )
          .toList(),
      rowDetailsBuilder: (context, row) => ProductionDailyProductDetailsCard(
        product: row,
        allocationRows: widget.data.allocations,
        materialRows: widget.data.materials,
        allocationsExpanded: allocationsOpen,
        materialsExpanded: materialsOpen,
        enabled: widget.enabled,
        destinationsEditable: widget.destinationsEditable,
        leadingInset: widget.leadingInset,
        onAddAllocation: widget.onAddAllocation,
        onRemoveAllocation: widget.onRemoveAllocation,
        unitEntries: _unitEntries,
        onToggleGroup: (group) => setState(() {
          if (group == DailyRowGroup.allocations) {
            allocationsOpen = !allocationsOpen;
          } else {
            materialsOpen = !materialsOpen;
          }
        }),
        onAllocationDestinationChanged: (row, id) {
          widget.events.destinations.add(id);
          row.allocationDemandId = id;
          widget.data.product.allocationRevision.value++;
        },
        allocationQuantityBuilder: all
            .firstWhere((column) => column.key == 'allocationQty')
            .cellBuilder,
        materialUsageBuilder: all
            .firstWhere((column) => column.key == 'materialUsed')
            .cellBuilder,
      ),
    );
  }
}

Future<(_Events, GlobalKey<_CardHostState>)> _pump(
  WidgetTester tester,
  _DetailsData data, {
  Size size = const Size(1200, 1000),
  bool allocationsOpen = true,
  bool materialsOpen = true,
  bool enabled = true,
  bool destinationsEditable = true,
  double leadingInset = 0,
  VoidCallback? onAddAllocation,
  ValueChanged<DailyGridRow>? onRemoveAllocation,
  bool dark = false,
  double textScale = 1,
  GlobalKey? capture,
  GlobalKey? overlayCapture,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final events = _Events();
  final key = GlobalKey<_CardHostState>();
  var theme = dark ? buildDarkTheme() : buildLightTheme();
  if (capture != null || overlayCapture != null) {
    theme = auditScreenshotTheme(theme);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: MaterialApp(
        theme: theme,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) {
          final content = MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          );
          return overlayCapture == null
              ? content
              : RepaintBoundary(key: overlayCapture, child: content);
        },
        home: Scaffold(
          appBar: AppBar(title: const Text('新建生产日报')),
          body: Builder(
            builder: (context) {
              final content = SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _CardHost(
                    key: key,
                    data: data,
                    events: events,
                    allocationsOpen: allocationsOpen,
                    materialsOpen: materialsOpen,
                    enabled: enabled,
                    destinationsEditable: destinationsEditable,
                    leadingInset: leadingInset,
                    onAddAllocation: onAddAllocation,
                    onRemoveAllocation: onRemoveAllocation,
                  ),
                ),
              );
              return capture == null
                  ? content
                  : RepaintBoundary(
                      key: capture,
                      child: ColoredBox(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        child: content,
                      ),
                    );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    data.dispose();
  });
  return (events, key);
}

void main() {
  _registerProductDetailsResizeTests();
  testWidgets(
    'full-name menu and compact folded cards preserve entered quantities',
    (tester) async {
      final data = _DetailsData();
      final captureRequested =
          Platform.environment['UTEN_CAPTURE_PRODUCT_DETAILS'] == '1';
      final capture = captureRequested ? GlobalKey() : null;
      final oldShadows = debugDisableShadows;
      if (captureRequested) {
        debugDisableShadows = false;
        addTearDown(() => debugDisableShadows = oldShadows);
        await loadAuditScreenshotFonts(tester);
      }
      final (events, _) = await _pump(
        tester,
        data,
        size: const Size(1920, 1000),
        leadingInset: 44,
        onAddAllocation: () {},
        onRemoveAllocation: (_) {},
        overlayCapture: capture,
      );
      if (capture != null) {
        await saveAuditScreenshot(
          tester,
          capture,
          'daily-card-columns-expanded',
        );
      }
      final handle = _resizeHandle(DailyRowGroup.allocations, '接收名称');
      final before = _resizeWidth(tester, DailyRowGroup.allocations, 1);
      await tester.drag(handle, Offset(180 - before, 0));
      await tester.pumpAndSettle();
      final fieldKey = ValueKey(
        'daily-allocation-destination-${identityHashCode(data.allocations.first)}',
      );
      await tester.tap(find.byKey(fieldKey));
      await tester.pumpAndSettle();
      final picker = tester.widget<UtenDropdownField>(find.byKey(fieldKey));
      final option = find.byKey(
        ValueKey<(String, Key?, String?)>((
          'uten-dropdown-option',
          picker.key,
          'A',
        )),
      );
      expect(option, findsOneWidget);
      expect(
        tester.getSize(option).width,
        greaterThan(tester.getSize(find.byKey(fieldKey)).width),
      );
      if (capture != null) {
        await saveAuditScreenshot(
          tester,
          capture,
          'daily-card-columns-name-menu',
        );
      }
      await tester.tapAt(const Offset(1850, 940));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收起产出去向'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收起子件用料'));
      await tester.pumpAndSettle();
      if (capture != null) {
        await saveAuditScreenshot(
          tester,
          capture,
          'daily-card-columns-collapsed',
        );
      }
      expect(data.allocations.map((row) => row.allocationQty.text), [
        '1000',
        '1000',
        '1000',
      ]);
      expect(events.destinations, isEmpty);
      expect(events.quantityChanges, 0);
      expect(tester.takeException(), isNull);
      debugDisableShadows = oldShadows;
    },
  );
  testWidgets('collapsed cards use compact heights and a small gap', (
    tester,
  ) async {
    final data = _DetailsData();
    await _pump(tester, data, allocationsOpen: false, materialsOpen: false);
    final allocation = find.byKey(
      const ValueKey('daily-product-allocations-card-product'),
    );
    final material = find.byKey(
      const ValueKey('daily-product-materials-card-product'),
    );
    expect(tester.getSize(allocation).height, lessThanOrEqualTo(44));
    expect(tester.getSize(material).height, lessThanOrEqualTo(44));
    expect(
      tester.getTopLeft(material).dy - tester.getBottomLeft(allocation).dy,
      inInclusiveRange(0, 6),
    );
    expect(find.byTooltip('展开产出去向'), findsOneWidget);
    expect(find.byTooltip('展开子件用料'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final scale in [1.0, 1.8]) {
    testWidgets(
      'compact detail rows keep input height readable at text scale $scale',
      (tester) async {
        final data = _DetailsData();
        final (events, _) = await _pump(
          tester,
          data,
          size: const Size(1920, 1100),
          textScale: scale,
        );
        Finder input(TextEditingController controller) =>
            find.byWidgetPredicate(
              (widget) =>
                  widget is TextField &&
                  identical(widget.controller, controller),
            );
        for (final pair in [
          (
            data.allocations[0].allocationQty,
            data.allocations[1].allocationQty,
            '1000',
          ),
          (
            data.materials[0].materialUsed,
            data.materials[1].materialUsed,
            '3000',
          ),
        ]) {
          final first = input(pair.$1), second = input(pair.$2);
          final rowHeight =
              tester.getCenter(second).dy - tester.getCenter(first).dy;
          expect(rowHeight, lessThanOrEqualTo(scale == 1 ? 44 : 64));
          expect(tester.getSize(first).height, greaterThanOrEqualTo(28));
          expect(tester.getSize(first).height, lessThan(rowHeight));
          expect(pair.$1.text, pair.$3);
        }
        expect(events.quantityChanges, 0);
        expect(events.materialChanges, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'natural name columns keep code and quantities adjacent while the remaining card width stays unused',
    (tester) async {
      final data = _DetailsData();
      await loadAuditScreenshotFonts(tester);
      await _pump(
        tester,
        data,
        size: const Size(1920, 1000),
        capture: GlobalKey(),
      );
      final card = find.byKey(
        const ValueKey('daily-product-materials-card-product'),
      );
      final table = find
          .descendant(of: card, matching: find.byType(Table))
          .first;
      final width = tester.getSize(table).width;
      expect(width, lessThan(1000));
      expect(width, lessThan(tester.getSize(card).width - 400));
      final name = find.text('V5一开单控10A后座（带UTEN）');
      final code = find.text('V50014');
      expect(
        tester.getTopLeft(code).dx - tester.getTopLeft(name).dx,
        lessThan(400),
      );
      expect(tester.widget<Text>(name).maxLines, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'allocation and material statuses plus disclosure buttons stay immediately after their title counts',
    (tester) async {
      final data = _DetailsData();
      await _pump(
        tester,
        data,
        size: const Size(1920, 1000),
        allocationsOpen: false,
        materialsOpen: false,
      );
      for (final values in [
        (
          '3 笔',
          '已分配 3,000 / 3,000 个',
          'daily-product-allocation-toggle-product',
        ),
        ('4 项', '已填写 4 / 4 项', 'daily-product-material-toggle-product'),
      ]) {
        final count = find.text(values.$1), status = find.text(values.$2);
        final button = find.byKey(ValueKey(values.$3));
        expect(
          tester.getTopLeft(status).dx - tester.getTopRight(count).dx,
          inInclusiveRange(0, 32),
        );
        expect(
          tester.getTopLeft(button).dx - tester.getTopRight(status).dx,
          inInclusiveRange(0, 20),
        );
        expect(tester.getTopRight(button).dx, lessThan(700));
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'optional add destination invokes its owner once without creating or changing any quantity fact',
    (tester) async {
      final data = _DetailsData();
      var additions = 0;
      await _pump(tester, data, onAddAllocation: () => additions++);
      final before = data.allocations
          .map((row) => row.allocationQty.text)
          .toList();
      final button = find.byKey(
        const ValueKey('daily-product-add-allocation-product'),
      );
      expect(button, findsOneWidget);
      expect(find.text('余量自动送仓库'), findsOneWidget);
      final card = find.byKey(
        const ValueKey('daily-product-allocations-card-product'),
      );
      expect(
        tester.getTopLeft(button).dx - tester.getTopLeft(card).dx,
        lessThan(30),
      );
      await tester.tap(button);
      await tester.pump();
      expect(additions, 1);
      expect(data.allocations, hasLength(3));
      expect(data.allocations.map((row) => row.allocationQty.text), before);
      expect(tester.takeException(), isNull);
    },
  );
  for (final enabled in [false, true]) {
    testWidgets(
      'add destination is absent when readonly or no callback is supplied: enabled=$enabled',
      (tester) async {
        final data = _DetailsData();
        var additions = 0;
        await _pump(
          tester,
          data,
          enabled: enabled,
          onAddAllocation: enabled ? null : () => additions++,
        );
        expect(find.text('添加去向'), findsNothing);
        expect(additions, 0);
        expect(data.allocations, hasLength(3));
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'manual warehouse remainder is a readonly destination with the allocation explanation',
    (tester) async {
      final data = _DetailsData();
      data.product.allocationManual = true;
      final (events, _) = await _pump(tester, data);
      final warehouse = find.byKey(
        ValueKey(
          'daily-allocation-destination-${identityHashCode(data.allocations.last)}',
        ),
      );
      expect(warehouse, findsNothing);
      expect(find.byType(UtenDropdownField), findsNWidgets(2));
      expect(find.text('送入仓库'), findsOneWidget);
      expect(find.byTooltip(RegExp('未分配余量自动送入仓库，调整上面工单的数量即可')), findsOneWidget);
      expect(events.destinations, isEmpty);
      expect(data.allocations.last.allocationQty.text, '1000');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'manual FQC recovery keeps its existing whole-row destination picker',
    (tester) async {
      final data = _DetailsData();
      data.product.allocationManual = true;
      data.product.fqcRecoveryAuthorizationId = 'fqc-authorized';
      final (events, _) = await _pump(tester, data);
      final warehouse = tester.widget<UtenDropdownField>(
        find.byKey(
          ValueKey(
            'daily-allocation-destination-${identityHashCode(data.allocations.last)}',
          ),
        ),
      );
      expect(warehouse.enabled, isTrue);
      warehouse.onChanged('C');
      await tester.pump();
      expect(events.destinations, ['C']);
      expect(data.allocations.last.allocationQty.text, '1000');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'remove actions occupy one compact adjacent column and delegate only demand rows',
    (tester) async {
      final data = _DetailsData();
      final removed = <DailyGridRow>[];
      await _pump(tester, data, onRemoveAllocation: removed.add);
      final first = data.allocations.first;
      final button = find.byKey(
        ValueKey('daily-remove-allocation-${first.localRowId}'),
      );
      expect(find.byTooltip('移除此去向'), findsNWidgets(2));
      expect(
        find.byKey(
          ValueKey(
            'daily-remove-allocation-${data.allocations.last.localRowId}',
          ),
        ),
        findsNothing,
      );
      expect(tester.getSize(button), const Size(36, 36));
      final quantity = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            identical(widget.controller, first.allocationQty),
      );
      expect(
        tester.getTopLeft(button).dx - tester.getTopRight(quantity).dx,
        inInclusiveRange(0, 20),
      );
      await tester.tap(button);
      await tester.pump();
      expect(removed, [first]);
      expect(data.allocations, hasLength(3));
      expect(
        data.allocations.every((row) => row.allocationQty.text == '1000'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final enabled in [false, true]) {
    testWidgets(
      'remove controls and their column are absent for readonly or omitted owner callback: enabled=$enabled',
      (tester) async {
        final data = _DetailsData();
        final removed = <DailyGridRow>[];
        await _pump(
          tester,
          data,
          enabled: enabled,
          onRemoveAllocation: enabled ? null : removed.add,
        );
        expect(find.byTooltip('移除此去向'), findsNothing);
        final allocation = find.byKey(
          const ValueKey('daily-product-allocation-table-product'),
        );
        final table = tester.widget<Table>(
          find.descendant(of: allocation, matching: find.byType(Table)),
        );
        expect(table.columnWidths, hasLength(5));
        expect(removed, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'compact removal remains keyboard-operable in dark narrow aligned cards without editing quantities',
    (tester) async {
      final data = _DetailsData();
      final removed = <DailyGridRow>[];
      final first = data.allocations.first;
      await _pump(
        tester,
        data,
        size: const Size(390, 844),
        dark: true,
        leadingInset: 44,
        onRemoveAllocation: removed.add,
      );
      final buttonKey = ValueKey('daily-remove-allocation-${first.localRowId}');
      bool focusedButton() =>
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<IconButton>()
              ?.key ==
          buttonKey;
      for (var attempt = 0; attempt < 50 && !focusedButton(); attempt++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focusedButton(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(removed, [first]);
      expect(data.allocations, hasLength(3));
      expect(
        data.allocations.every((row) => row.allocationQty.text == '1000'),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'empty quantity inputs retain readable application hints within natural card columns',
    (tester) async {
      final data = _DetailsData();
      data.allocations.first.allocationQty.clear();
      data.allocations.first.allocationAutofilled.value = false;
      data.materials.first.materialUsed.clear();
      await loadAuditScreenshotFonts(tester);
      await _pump(
        tester,
        data,
        size: const Size(1500, 1000),
        capture: GlobalKey(),
      );
      for (final value in [
        (data.allocations.first.allocationQty, '去向数量'),
        (data.materials.first.materialUsed, '本次实际用料'),
      ]) {
        final finder = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && identical(widget.controller, value.$1),
        );
        final field = tester.widget<TextField>(finder);
        expect(field.decoration?.hintText, value.$2);
        final text = tester.widget<EditableText>(
          find.descendant(of: finder, matching: find.byType(EditableText)),
        );
        final painter = TextPainter(
          text: TextSpan(
            text: value.$2,
            style: text.style.merge(field.decoration?.hintStyle),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        expect(
          painter.width,
          lessThan(
            tester
                .getSize(
                  find.descendant(
                    of: finder,
                    matching: find.byType(EditableText),
                  ),
                )
                .width,
          ),
        );
        painter.dispose();
      }
      expect(tester.takeException(), isNull);
    },
  );
  for (final dark in [false, true]) {
    testWidgets(
      'two vertically stacked cards use distinct subtle theme colors and preserve input theme: dark=$dark',
      (tester) async {
        final data = _DetailsData();
        await _pump(tester, data, dark: dark);
        final allocation = tester.widget<Card>(
          find.byKey(const ValueKey('daily-product-allocations-card-product')),
        );
        final material = tester.widget<Card>(
          find.byKey(const ValueKey('daily-product-materials-card-product')),
        );
        final theme = dark ? buildDarkTheme() : buildLightTheme();
        expect(allocation.color, isNotNull);
        expect(material.color, isNotNull);
        expect(allocation.color, isNot(material.color));
        expect(allocation.color, isNot(theme.colorScheme.surface));
        expect(material.color, isNot(theme.colorScheme.surface));
        expect(allocation.color!.a, 1);
        expect(material.color!.a, 1);
        final field = find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              identical(widget.controller, data.materials.first.materialUsed),
        );
        expect(
          Theme.of(tester.element(field)).inputDecorationTheme.fillColor,
          theme.inputDecorationTheme.fillColor,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'API exact issued and material cap decimals remain authoritative in card labels and errors',
    (tester) async {
      final data = _DetailsData();
      data.materials.first.material = ProductionMaterialClearanceRow.fromJson({
        'planId': 'plan',
        'demandId': 'material-0',
        'goodsId': 'material-goods-0',
        'goodsName': '精确用料',
        'unitName': '个',
        'issuedQty': 10000000000000.0,
        'issuedQtyExact': '9999999999999.9999',
        'availableToSettleQty': 10000000000000.0,
        'availableToSettleQtyExact': '9999999999999.9998',
      });
      data.materials.first.materialUsed.text = '9999999999999.9999';
      await _pump(tester, data);
      expect(find.text('9,999,999,999,999.9999 个'), findsOneWidget);
      expect(find.textContaining('超过可登记 9999999999999.9998 个'), findsOneWidget);
      expect(data.materials.first.materialUsed.text, '9999999999999.9999');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'large legacy balances without exact API source show unknown instead of guessing quantity',
    (tester) async {
      final data = _DetailsData();
      data.materials.first.material = ProductionMaterialClearanceRow.fromJson({
        'planId': 'plan',
        'demandId': 'material-0',
        'goodsId': 'material-goods-0',
        'goodsName': '待核对用料',
        'unitName': '个',
        'issuedQty': 10000000000000.0,
        'availableToSettleQty': 10000000000000.0,
      });
      data.materials.first.materialUsed.text = '1';
      await _pump(tester, data);
      expect(find.text('领料量待核对'), findsOneWidget);
      expect(find.textContaining('可登记用料量待核对'), findsOneWidget);
      expect(find.textContaining('超过可登记 10000000000000'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'detail card outer edge uses exactly the supplied main-column inset',
    (tester) async {
      final data = _DetailsData();
      await _pump(
        tester,
        data,
        leadingInset: 44,
        allocationsOpen: false,
        materialsOpen: false,
      );
      final details = find.byType(ProductionDailyProductDetailsCard);
      final allocation = find.byKey(
        const ValueKey('daily-product-allocations-card-product'),
      );
      final material = find.byKey(
        const ValueKey('daily-product-materials-card-product'),
      );
      expect(
        tester.getTopLeft(allocation).dx - tester.getTopLeft(details).dx,
        44,
      );
      expect(
        tester.getTopLeft(material).dx - tester.getTopLeft(details).dx,
        44,
      );
      expect(
        tester.getTopLeft(material).dy,
        greaterThan(tester.getBottomLeft(allocation).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'filled disclosure button remains keyboard-operable while business inputs are readonly',
    (tester) async {
      final data = _DetailsData();
      final (events, key) = await _pump(
        tester,
        data,
        enabled: false,
        allocationsOpen: false,
        materialsOpen: false,
      );
      const buttonKey = ValueKey('daily-product-allocation-toggle-product');
      final button = tester.widget<UtenButton>(find.byKey(buttonKey));
      expect(button.type, UtenButtonType.primary);
      expect(button.height, 36);
      expect(tester.getSize(find.byKey(buttonKey)).height, 36);
      expect(button.onPressed, isNotNull);
      bool focusedButton() =>
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<UtenButton>()
              ?.key ==
          buttonKey;
      for (var attempt = 0; attempt < 30 && !focusedButton(); attempt++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focusedButton(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(key.currentState!.allocationsOpen, isTrue);
      expect(find.byTooltip('收起产出去向'), findsOneWidget);
      expect(focusedButton(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(key.currentState!.allocationsOpen, isFalse);
      expect(events.destinations, isEmpty);
      expect(events.quantityChanges, 0);
      expect(data.allocations.first.allocationQty.text, '1000');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'disclosure headers with the aligned inset fit a narrow large-text viewport',
    (tester) async {
      final data = _DetailsData();
      await _pump(
        tester,
        data,
        size: const Size(390, 844),
        textScale: 1.3,
        leadingInset: 44,
        allocationsOpen: false,
        materialsOpen: false,
      );
      expect(find.byTooltip('展开产出去向'), findsOneWidget);
      expect(find.byTooltip('展开子件用料'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'dark narrow aligned disclosure buttons keep their background and independent view state',
    (tester) async {
      final data = _DetailsData();
      final (_, key) = await _pump(
        tester,
        data,
        dark: true,
        size: const Size(390, 844),
        textScale: 1.3,
        leadingInset: 44,
        allocationsOpen: false,
        materialsOpen: false,
      );
      const buttonKey = ValueKey('daily-product-allocation-toggle-product');
      final button = tester.widget<UtenButton>(find.byKey(buttonKey));
      expect(button.type, UtenButtonType.primary);
      expect(button.height, 36);
      await tester.tap(find.byTooltip('展开产出去向'));
      await tester.pumpAndSettle();
      expect(key.currentState!.allocationsOpen, isTrue);
      expect(key.currentState!.materialsOpen, isFalse);
      expect(data.allocations.first.allocationQty.text, '1000');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'keyboard disclosure after actual quantity editing preserves the value and delivers blur in dark theme',
    (tester) async {
      final data = _DetailsData();
      final (events, key) = await _pump(
        tester,
        data,
        dark: true,
        leadingInset: 44,
        materialsOpen: false,
      );
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            identical(widget.controller, data.allocations.first.allocationQty),
      );
      await tester.enterText(field, '500.1250');
      await tester.pump();
      const buttonKey = ValueKey('daily-product-allocation-toggle-product');
      bool focusedButton() =>
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<UtenButton>()
              ?.key ==
          buttonKey;
      for (var attempt = 0; attempt < 40 && !focusedButton(); attempt++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focusedButton(), isTrue);
      expect(events.focused, contains(false));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(key.currentState!.allocationsOpen, isFalse);
      expect(data.allocations.first.allocationQty.text, '500.1250');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unfocused material input fully paints a normal four-decimal quantity with the application font',
    (tester) async {
      final data = _DetailsData();
      data.materials.first.material = const ProductionMaterialClearanceRow(
        planId: 'plan',
        demandId: 'material-0',
        goodsId: 'material-goods-0',
        goodsCode: 'V50010',
        goodsName: 'V5一开压板',
        colorName: '深灰色',
        unitName: '个',
        requiredQty: 20000,
        issuedQty: 20000,
        returnedQty: 0,
        consumedQty: 0,
        approvedLossQty: 0,
        legalWipQty: 0,
        maxReturnQty: 20000,
        unclearedQty: 20000,
        canClose: false,
        availableToSettleQty: 20000,
      );
      data.materials.first.materialUsed.text = '10850.1234';
      await loadAuditScreenshotFonts(tester);
      await _pump(
        tester,
        data,
        size: const Size(1500, 1000),
        capture: GlobalKey(),
      );
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            identical(widget.controller, data.materials.first.materialUsed),
      );
      final editable = tester.widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasFocus, isFalse);
      final state = tester.state<ScrollableState>(
        find.descendant(of: field, matching: find.byType(Scrollable)).first,
      );
      expect(
        state.position.maxScrollExtent,
        lessThanOrEqualTo(0.01),
        reason:
            '10850.1234 must fit completely; ordinary four-decimal quantities cannot lose their visible last digits',
      );
      expect(data.materials.first.materialUsed.text, '10850.1234');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'wide detail viewport always stacks independent natural-height cards without inner horizontal overflow',
    (tester) async {
      final data = _DetailsData();
      await _pump(tester, data, size: const Size(1440, 1000));
      final allocation = find.byKey(
        const ValueKey('daily-product-allocations-card-product'),
      );
      final material = find.byKey(
        const ValueKey('daily-product-materials-card-product'),
      );
      expect(
        tester.getSize(find.byType(ProductionDailyProductDetailsCard)).width,
        1408,
      );
      expect(
        tester.getTopLeft(material).dy,
        greaterThan(tester.getBottomLeft(allocation).dy),
      );
      expect(tester.getTopLeft(allocation).dx, tester.getTopLeft(material).dx);
      expect(
        tester.getSize(allocation).height,
        isNot(tester.getSize(material).height),
      );
      for (final card in [allocation, material]) {
        for (final element
            in find
                .descendant(of: card, matching: find.byType(Scrollable))
                .evaluate()) {
          if (element.findAncestorWidgetOfExactType<EditableText>() != null) {
            continue;
          }
          final state = tester.state<ScrollableState>(
            find.byElementPredicate((candidate) => candidate == element),
          );
          expect(state.position.maxScrollExtent, lessThanOrEqualTo(0.01));
        }
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'responsive card stacking preserves an in-progress quantity and its focus',
    (tester) async {
      final data = _DetailsData();
      final (events, _) = await _pump(
        tester,
        data,
        size: const Size(1500, 1000),
      );
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            identical(widget.controller, data.allocations.first.allocationQty),
      );
      await tester.enterText(field, '500.1250');
      await tester.pump();
      expect(events.focused.last, isTrue);
      tester.view.physicalSize = const Size(1000, 1000);
      await tester.pumpAndSettle();
      final allocation = find.byKey(
        const ValueKey('daily-product-allocations-card-product'),
      );
      final material = find.byKey(
        const ValueKey('daily-product-materials-card-product'),
      );
      expect(
        tester.getTopLeft(material).dy,
        greaterThan(tester.getBottomLeft(allocation).dy),
      );
      expect(data.allocations.first.allocationQty.text, '500.1250');
      expect(events.focused.last, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'detail quantity cells retain inline unit decorations from existing business builders',
    (tester) async {
      final data = _DetailsData();
      await _pump(tester, data);
      final allocation = tester.widget<TextField>(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              identical(
                widget.controller,
                data.allocations.first.allocationQty,
              ),
        ),
      );
      final material = tester.widget<TextField>(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              identical(widget.controller, data.materials.first.materialUsed),
        ),
      );
      expect(allocation.decoration?.suffixText, '个');
      expect(material.decoration?.suffixText, '个');
      expect(tester.takeException(), isNull);
    },
  );
  for (final autofilled in [false, true]) {
    testWidgets(
      'hover reveals full receiver and work order inside a single-line field: autofilled=$autofilled',
      (tester) async {
        final data = _DetailsData();
        data.allocations.first.allocationAutofilled.value = autofilled;
        await _pump(
          tester,
          data,
          size: const Size(800, 1000),
          materialsOpen: false,
        );
        final row = data.allocations.first;
        final field = find.byKey(
          ValueKey('daily-allocation-destination-${identityHashCode(row)}'),
        );
        final full = outputAllocationOptions(
          row,
        ).firstWhere((item) => item.value == 'A').label;
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(field));
        await tester.pump(const Duration(milliseconds: 700));
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                (widget.data ?? widget.textSpan?.toPlainText() ?? '').contains(
                  full,
                ),
          ),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'destination permission disables the picker while quantity editing stays enabled',
    (tester) async {
      final data = _DetailsData();
      final row = data.allocations.first;
      final initialRevision = data.product.allocationRevision.value;
      final (events, _) = await _pump(
        tester,
        data,
        destinationsEditable: false,
      );
      final pickerFinder = find.byKey(
        ValueKey('daily-allocation-destination-${identityHashCode(row)}'),
      );
      final picker = tester.widget<UtenDropdownField>(pickerFinder);
      expect(picker.enabled, isFalse);
      await tester.tap(pickerFinder);
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          ValueKey<(String, Key?, String?)>((
            'uten-dropdown-option',
            picker.key,
            'C',
          )),
        ),
        findsNothing,
      );
      picker.onChanged('C');
      expect(events.destinations, isEmpty);
      expect(row.allocationDemandId, 'A');
      expect(data.product.allocationRevision.value, initialRevision);
      final quantity = tester.widget<TextField>(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              identical(widget.controller, row.allocationQty),
        ),
      );
      expect(quantity.readOnly, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'read-only card cannot change destination or focus an editable quantity',
    (tester) async {
      final data = _DetailsData();
      final (events, _) = await _pump(tester, data, enabled: false);
      final picker = tester.widget<UtenDropdownField>(
        find.byKey(
          ValueKey(
            'daily-allocation-destination-${identityHashCode(data.allocations.last)}',
          ),
        ),
      );
      expect(picker.enabled, isFalse);
      picker.onChanged('C');
      expect(events.destinations, isEmpty);
      final quantity = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            identical(widget.controller, data.allocations.last.allocationQty),
      );
      await tester.tap(quantity, warnIfMissed: false);
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(events.quantityChanges, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'shared material mirror reuses the existing input without adding a second editable fact',
    (tester) async {
      final data = _DetailsData();
      data.materials[1].materialOwnsInput = false;
      data.materials[1].materialUsed.text = '0.9999';
      await _pump(tester, data);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              identical(widget.controller, data.materials[1].materialUsed),
        ),
        findsNothing,
      );
      expect(find.byTooltip('本工单的物料已在上面的成品行下登记，这里只作对照'), findsOneWidget);
      expect(data.materials[1].materialUsed.text, '0.9999');
      expect(find.text('0.9999 个'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'zero completed quantity never appears as a fully allocated zero total',
    (tester) async {
      final data = _DetailsData();
      data.product.qty.text = '0';
      for (final row in data.allocations) {
        row.allocationQty.text = '0';
      }
      await _pump(tester, data, allocationsOpen: false, materialsOpen: false);
      expect(find.text('待填写有效完工量'), findsOneWidget);
      expect(find.textContaining('已分配 0 / 0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'details groups collapse independently and preserve manually entered material controller',
    (tester) async {
      final data = _DetailsData();
      final (events, key) = await _pump(
        tester,
        data,
        allocationsOpen: false,
        materialsOpen: false,
      );
      expect(key.currentState!.controller.rows, [data.product]);
      expect(find.byType(UtenDropdownField), findsNothing);
      await tester.tap(find.byTooltip('展开产出去向'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenDropdownField), findsNWidgets(3));
      expect(key.currentState!.materialsOpen, isFalse);
      await tester.tap(find.byTooltip('展开子件用料'));
      await tester.pumpAndSettle();
      final controller = data.materials.first.materialUsed;
      final field = find.byWidgetPredicate(
        (w) => w is TextField && identical(w.controller, controller),
      );
      await tester.enterText(field, '2999.5');
      expect(events.materialChanges, 1);
      await tester.tap(find.byTooltip('收起子件用料'));
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      expect(controller.text, '2999.5');
      await tester.tap(find.byTooltip('展开子件用料'));
      await tester.pumpAndSettle();
      expect(field, findsOneWidget);
      expect(controller.text, '2999.5');
      expect(key.currentState!.controller.rows, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'destination menu shows only names while same-name choices retain work-order context in tooltips',
    (tester) async {
      final data = _DetailsData();
      await _pump(tester, data);
      final field = tester.widget<UtenDropdownField>(
        find.byKey(
          ValueKey(
            'daily-allocation-destination-${identityHashCode(data.allocations.first)}',
          ),
        ),
      );
      expect(field.selectedLabel, _receiver);
      expect(
        field.items.firstWhere((item) => item.value == 'A').tooltip,
        contains('HP035754'),
      );
      expect(
        field.items.firstWhere((item) => item.value == 'B').tooltip,
        contains('HP035756'),
      );
      expect(
        field.items.firstWhere((item) => item.value == 'A').label,
        _receiver,
      );
      expect(
        field.items.firstWhere((item) => item.value == 'B').label,
        _receiver,
      );
      expect(find.text('HP035754'), findsOneWidget);
      final text = tester.widget<Text>(find.text('HP035754'));
      expect(text.maxLines, 1);
      final header = find.text('去向工单');
      expect(header, findsOneWidget);
      expect(find.text('接收名称'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'destination and quantity delegate to original callbacks with stable controller and focus',
    (tester) async {
      final data = _DetailsData();
      final (events, _) = await _pump(tester, data);
      final last = data.allocations.last;
      final picker = find.byKey(
        ValueKey('daily-allocation-destination-${identityHashCode(last)}'),
      );
      final field = tester.widget<UtenDropdownField>(picker);
      final target = field.items.firstWhere((item) => item.value == 'C');
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          ValueKey<(String, Key?, String?)>((
            'uten-dropdown-option',
            field.key,
            target.value,
          )),
        ),
      );
      await tester.pumpAndSettle();
      expect(events.destinations, ['C']);
      final quantity = find.byWidgetPredicate(
        (w) => w is TextField && identical(w.controller, last.allocationQty),
      );
      await tester.enterText(quantity, '500.1234');
      await tester.pump();
      expect(events.quantityChanges, 1);
      expect(find.text('待分配 499.8766 个'), findsOneWidget);
      await tester.tap(find.byTooltip('收起产出去向'));
      await tester.pumpAndSettle();
      expect(last.allocationQty.text, '500.1234');
      expect(data.product.allocationRows, hasLength(3));
      expect(events.focused, contains(false));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'collapsed error headers retain full reasons and expansion reveals complete errors',
    (tester) async {
      final data = _DetailsData();
      data.product.directTransferLoadFailed = true;
      data.product.directTransferBlockedText = '候选工单读取失败，原去向与用料都需要保持，刷新后核对再保存';
      data.allocations.first.allocationIssue.value = '上层工单现在只能接收 100 个，请重新分配';
      data.materials.first.materialUsed.clear();
      await _pump(tester, data, allocationsOpen: false, materialsOpen: false);
      expect(find.text('去向读取失败，请核对'), findsOneWidget);
      expect(find.byTooltip(RegExp('上层工单现在只能接收 100 个')), findsOneWidget);
      await tester.tap(find.byTooltip('展开产出去向'));
      await tester.pumpAndSettle();
      expect(find.textContaining('候选工单读取失败，原去向与用料'), findsWidgets);
      await tester.tap(find.byTooltip('展开子件用料'));
      await tester.pumpAndSettle();
      expect(find.textContaining('V5一开压板：请填写有效的本次实际用料'), findsOneWidget);
      expect(data.materials.first.materialUsed.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'warehouse-only and failed empty candidate states remain visible',
    (tester) async {
      final data = _DetailsData();
      data.allocations.removeRange(0, 2);
      data.product.directTransferCandidates = [];
      data.product.directTransferBlockedText = '本产品不能车间内流转，做好后交仓库送检';
      data.product.qty.text = '1000';
      await _pump(tester, data, materialsOpen: false);
      expect(find.text('已分配 1,000 / 1,000 个'), findsOneWidget);
      expect(find.text('送入仓库'), findsOneWidget);
      expect(find.byType(UtenDropdownField), findsNothing);
      data.product.directTransferBlockedText = null;
      data.product.directTransferLoadFailed = true;
      data.allocations.clear();
      data.product.allocationRevision.value++;
      await tester.pumpAndSettle();
      expect(find.text('产出去向'), findsOneWidget);
      expect(find.text('去向读取失败，请核对'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(1920, 1000), const Size(390, 844)]) {
    for (final dark in [false, true]) {
      testWidgets(
        'full-width product details and single-line rows fit viewport $size dark=$dark',
        (tester) async {
          final data = _DetailsData();
          final captureRequested =
              Platform.environment['UTEN_CAPTURE_PRODUCT_DETAILS'] == '1' &&
              !dark;
          final capture = captureRequested ? GlobalKey() : null;
          if (captureRequested) {
            await loadAuditScreenshotFonts(tester);
          }
          await _pump(
            tester,
            data,
            size: size,
            dark: dark,
            textScale: size.width < 600 ? 1.3 : 1,
            capture: capture,
            leadingInset: captureRequested ? 44 : 0,
            onAddAllocation: captureRequested ? () {} : null,
            onRemoveAllocation: captureRequested ? (_) {} : null,
          );
          final width = tester
              .getSize(find.byType(ProductionDailyProductDetailsCard))
              .width;
          expect(width, lessThanOrEqualTo(size.width));
          final names = tester.widgetList<Text>(
            find.text('V5一开单控10A后座（带UTEN）'),
          );
          expect(names.every((name) => name.maxLines == 1), isTrue);
          expect(find.byType(UtenDropdownField), findsNWidgets(3));
          if (capture != null) {
            await saveAuditScreenshot(
              tester,
              capture,
              size.width > 1000
                  ? 'daily-report-product-details-wide'
                  : 'daily-report-product-details-narrow',
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
