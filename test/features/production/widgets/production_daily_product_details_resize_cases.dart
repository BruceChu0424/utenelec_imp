part of 'production_daily_product_details_card_test.dart';

const _resizeDemandA = '11111111-1111-4111-8111-111111111111';
const _resizeDemandB = '22222222-2222-4222-8222-222222222222';
const _resizeDemandC = '33333333-3333-4333-8333-333333333333';

void _resizeTargets(_DetailsData data, {String name = '同名接收产品'}) {
  data.product.directTransferCandidates = [
    for (final entry in [
      (_resizeDemandA, 'SEG-REC-A', 'REC-A', '接收白色'),
      (_resizeDemandB, 'SEG-REC-B', 'REC-B', '接收蓝色'),
      (_resizeDemandC, 'SEG-REC-C', 'REC-C', '接收灰色'),
    ])
      ProductionDirectTransferCandidate(
        demandId: entry.$1,
        executionSegmentId: 'receiver-${entry.$3}',
        executionSegmentCode: entry.$2,
        receivingGoodsName: name,
        receivingGoodsCode: entry.$3,
        receivingColorName: entry.$4,
        goodsCode: 'SOURCE-CODE',
        colorName: '来源红色',
        unitName: '个',
        remainingQty: 1000,
      ),
  ];
  data.product.directTransferRoomBase = {
    _resizeDemandA: 1000,
    _resizeDemandB: 1000,
    _resizeDemandC: 1000,
  };
  data.allocations[0].allocationDemandId = _resizeDemandA;
  data.allocations[1].allocationDemandId = _resizeDemandB;
}

Finder _resizeTable(DailyRowGroup group) => find.descendant(
  of: find.byKey(
    ValueKey(
      'daily-product-${group == DailyRowGroup.allocations ? 'allocation' : 'material'}-table-product',
    ),
  ),
  matching: find.byWidgetPredicate(
    (widget) => widget is UtenEditableGrid<dynamic>,
  ),
);

double _resizeWidth(WidgetTester tester, DailyRowGroup group, int column) {
  final dynamic gridState = tester.state(_resizeTable(group));
  // Public shared resize contract, independent from the rendering backend.
  // ignore: avoid_dynamic_calls
  return gridState.columnDragWidth(column) as double;
}

Finder _resizeHandle(DailyRowGroup group, String label) => find.descendant(
  of: _resizeTable(group),
  matching: find.byWidgetPredicate(
    (widget) => widget is UtenColumnResizeHandle && widget.label == label,
  ),
);

Future<void> _dragResizeHandle(
  WidgetTester tester,
  DailyRowGroup group,
  String label,
  double dx,
) async {
  final handle = _resizeHandle(group, label);
  await tester.ensureVisible(handle);
  await tester.pumpAndSettle();
  final pointer = await tester.startGesture(
    tester.getCenter(handle),
    kind: PointerDeviceKind.mouse,
  );
  await pointer.moveBy(Offset(dx, 0));
  await tester.pump();
  await pointer.up();
  await tester.pumpAndSettle();
}

Future<void> _resetResizeHandle(
  WidgetTester tester,
  DailyRowGroup group,
  String label,
) async {
  final handle = _resizeHandle(group, label);
  await tester.ensureVisible(handle);
  await tester.pumpAndSettle();
  await tester.tap(handle);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tap(handle);
  await tester.pumpAndSettle();
}

Future<_Events> _pumpResizeRtl(WidgetTester tester, _DetailsData data) async {
  tester.view.physicalSize = const Size(1800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final events = _Events();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _CardHost(data: data, events: events),
            ),
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
  return events;
}

void _registerProductDetailsResizeTests() {
  testWidgets(
    'receiver names exceed the former 600px limit and paint their full single-line value by default',
    (tester) async {
      final data = _DetailsData();
      final name = List.filled(8, 'V5超长接收产品完整名称与安装组件').join();
      _resizeTargets(data, name: name);
      await loadAuditScreenshotFonts(tester);
      await _pump(
        tester,
        data,
        size: const Size(3200, 1000),
        materialsOpen: false,
        capture: GlobalKey(),
      );
      expect(
        _resizeWidth(tester, DailyRowGroup.allocations, 1),
        greaterThan(600),
      );
      final table = tester.widget<UtenEditableGrid<dynamic>>(
        _resizeTable(DailyRowGroup.allocations),
      );
      expect(
        find.descendant(
          of: _resizeTable(DailyRowGroup.allocations),
          matching: find.byType(UtenColumnResizeHandle),
        ),
        findsNWidgets(table.columns.length),
      );
      final field = find.byKey(
        ValueKey(
          'daily-allocation-destination-${identityHashCode(data.allocations.first)}',
        ),
      );
      final selected = find.descendant(of: field, matching: find.text(name));
      expect(selected, findsOneWidget);
      expect(tester.widget<Text>(selected).maxLines, 1);
      final paragraph = find.descendant(
        of: selected,
        matching: find.byType(RichText),
      );
      expect(paragraph, findsOneWidget);
      expect(
        tester.renderObject<RenderParagraph>(paragraph).didExceedMaxLines,
        isFalse,
      );
      expect(data.allocations.first.allocationQty.text, '1000');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'receiver table separates five fields and name-only same-name choices retain UUID and work-order context',
    (tester) async {
      final data = _DetailsData();
      _resizeTargets(data);
      final (events, _) = await _pump(tester, data, materialsOpen: false);
      final table = tester.widget<UtenEditableGrid<dynamic>>(
        _resizeTable(DailyRowGroup.allocations),
      );
      expect(table.columns, hasLength(5));
      expect(table.controller.rows, hasLength(3));
      for (final text in ['REC-A', 'REC-B', '接收白色', '接收蓝色']) {
        expect(find.text(text), findsOneWidget);
      }
      expect(find.text('来源红色'), findsNothing);
      expect(find.text('SOURCE-CODE'), findsNothing);
      final row = data.allocations.first;
      final fieldKey = ValueKey(
        'daily-allocation-destination-${identityHashCode(row)}',
      );
      final field = tester.widget<UtenDropdownField>(find.byKey(fieldKey));
      expect(field.selectedLabel, '同名接收产品');
      expect(field.menuMatchContentWidth, isTrue);
      final first = field.items.firstWhere(
        (item) => item.value == _resizeDemandA,
      );
      final second = field.items.firstWhere(
        (item) => item.value == _resizeDemandB,
      );
      expect(first.label, '同名接收产品');
      expect(second.label, '同名接收产品');
      expect(first.tooltip, allOf(contains('SEG-REC-A'), contains('REC-A')));
      expect(second.tooltip, allOf(contains('SEG-REC-B'), contains('REC-B')));
      // B is initially another allocation's chosen receiver, so its menu item
      // correctly cannot be selected. The owning fixture releases it first.
      data.allocations[1].allocationDemandId = null;
      data.product.allocationRevision.value++;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenDropdownField>(find.byKey(fieldKey))
            .items
            .firstWhere((item) => item.value == _resizeDemandB)
            .enabled,
        isTrue,
      );
      await tester.tap(find.byKey(fieldKey));
      await tester.pumpAndSettle();
      final option = find.byKey(
        ValueKey<(String, Key?, String?)>((
          'uten-dropdown-option',
          fieldKey,
          _resizeDemandB,
        )),
      );
      expect(option, findsOneWidget);
      expect(
        find.descendant(of: option, matching: find.text('同名接收产品')),
        findsOneWidget,
      );
      expect(
        tester.widget<Tooltip>(option).message,
        allOf(contains('SEG-REC-B'), contains('REC-B')),
      );
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(events.destinations, [_resizeDemandB]);
      expect(row.allocationDemandId, _resizeDemandB);
      expect(
        tester.widget<UtenDropdownField>(find.byKey(fieldKey)).value,
        _resizeDemandB,
      );
      expect(find.text('REC-B'), findsOneWidget);
      expect(find.text('接收蓝色'), findsOneWidget);
      expect(find.text('REC-A'), findsNothing);
      expect(find.text('接收白色'), findsNothing);
      expect(row.allocationQty.text, '1000');
      expect(events.quantityChanges, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'both card headers resize through pointer gestures independently and stop at usable minimums',
    (tester) async {
      final data = _DetailsData();
      _resizeTargets(data);
      await _pump(tester, data, size: const Size(1800, 1000));
      final allocation = _resizeWidth(tester, DailyRowGroup.allocations, 1);
      final material = _resizeWidth(tester, DailyRowGroup.materials, 0);
      await _dragResizeHandle(tester, DailyRowGroup.allocations, '接收名称', 100);
      expect(
        _resizeWidth(tester, DailyRowGroup.allocations, 1),
        greaterThan(allocation + 40),
      );
      expect(_resizeWidth(tester, DailyRowGroup.materials, 0), material);
      final adjusted = _resizeWidth(tester, DailyRowGroup.allocations, 1);
      await _dragResizeHandle(tester, DailyRowGroup.materials, '子件名称', 100);
      expect(
        _resizeWidth(tester, DailyRowGroup.materials, 0),
        greaterThan(material + 40),
      );
      expect(_resizeWidth(tester, DailyRowGroup.allocations, 1), adjusted);
      await _dragResizeHandle(tester, DailyRowGroup.allocations, '接收名称', -3000);
      expect(_resizeWidth(tester, DailyRowGroup.allocations, 1), 148);
      await _dragResizeHandle(tester, DailyRowGroup.materials, '子件名称', -3000);
      expect(_resizeWidth(tester, DailyRowGroup.materials, 0), 72);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'double-click restores current automatic content width for just the selected card column',
    (tester) async {
      final data = _DetailsData();
      _resizeTargets(data);
      await _pump(tester, data, size: const Size(1800, 1000));
      final natural = _resizeWidth(tester, DailyRowGroup.allocations, 1);
      await _dragResizeHandle(tester, DailyRowGroup.allocations, '接收名称', 100);
      expect(
        _resizeWidth(tester, DailyRowGroup.allocations, 1),
        greaterThan(natural + 40),
      );
      await _dragResizeHandle(tester, DailyRowGroup.materials, '编号', 100);
      final material = _resizeWidth(tester, DailyRowGroup.materials, 1);
      await _resetResizeHandle(tester, DailyRowGroup.allocations, '接收名称');
      expect(_resizeWidth(tester, DailyRowGroup.allocations, 1), natural);
      expect(_resizeWidth(tester, DailyRowGroup.materials, 1), material);
      expect(data.materials.first.materialUsed.text, '3000');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one mouse drag accumulates several pointer updates before the next frame',
    (tester) async {
      final data = _DetailsData();
      _resizeTargets(data);
      final (events, _) = await _pump(
        tester,
        data,
        size: const Size(1800, 1000),
        materialsOpen: false,
      );
      final handle = _resizeHandle(DailyRowGroup.allocations, '接收名称');
      await tester.ensureVisible(handle);
      await tester.pumpAndSettle();
      final before = _resizeWidth(tester, DailyRowGroup.allocations, 1);
      final pointer = await tester.startGesture(
        tester.getCenter(handle),
        kind: PointerDeviceKind.mouse,
      );
      await pointer.moveBy(const Offset(20, 0));
      await pointer.moveBy(const Offset(30, 0));
      await pointer.moveBy(const Offset(40, 0));
      await pointer.up();
      await tester.pumpAndSettle();
      expect(
        _resizeWidth(tester, DailyRowGroup.allocations, 1),
        closeTo(before + 90, 0.01),
      );
      expect(events.quantityChanges, 0);
      expect(events.destinations, isEmpty);
      expect(data.allocations.first.allocationQty.text, '1000');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual widths survive independently folded sections and updated receiver content until reset',
    (tester) async {
      final data = _DetailsData();
      _resizeTargets(data);
      await _pump(tester, data, size: const Size(1800, 1000));
      await _dragResizeHandle(tester, DailyRowGroup.allocations, '接收名称', 100);
      await _dragResizeHandle(tester, DailyRowGroup.materials, '编号', 100);
      final allocation = _resizeWidth(tester, DailyRowGroup.allocations, 1);
      final material = _resizeWidth(tester, DailyRowGroup.materials, 1);
      await tester.tap(find.byTooltip('收起产出去向'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收起子件用料'));
      await tester.pumpAndSettle();
      expect(_resizeTable(DailyRowGroup.allocations), findsNothing);
      expect(_resizeTable(DailyRowGroup.materials), findsNothing);
      _resizeTargets(data, name: List.filled(5, '更新后更长的接收产品名称').join());
      data.product.allocationRevision.value++;
      await tester.tap(find.byTooltip('展开产出去向'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('展开子件用料'));
      await tester.pumpAndSettle();
      expect(_resizeWidth(tester, DailyRowGroup.allocations, 1), allocation);
      expect(_resizeWidth(tester, DailyRowGroup.materials, 1), material);
      await _resetResizeHandle(tester, DailyRowGroup.allocations, '接收名称');
      expect(
        _resizeWidth(tester, DailyRowGroup.allocations, 1),
        greaterThan(allocation),
      );
      expect(_resizeWidth(tester, DailyRowGroup.materials, 1), material);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'readonly dark cards retain resize gestures without writing destination or quantity facts',
    (tester) async {
      final data = _DetailsData();
      _resizeTargets(data);
      final quantities = data.allocations
          .map((row) => row.allocationQty.text)
          .toList();
      final materials = data.materials
          .map((row) => row.materialUsed.text)
          .toList();
      final destinations = data.allocations
          .map((row) => row.allocationDemandId)
          .toList();
      final (events, _) = await _pump(
        tester,
        data,
        enabled: false,
        dark: true,
        size: const Size(1800, 1000),
      );
      final before = _resizeWidth(tester, DailyRowGroup.allocations, 1);
      await _dragResizeHandle(tester, DailyRowGroup.allocations, '接收名称', 100);
      await _dragResizeHandle(tester, DailyRowGroup.materials, '本次实际用料', 60);
      expect(
        _resizeWidth(tester, DailyRowGroup.allocations, 1),
        greaterThan(before),
      );
      expect(data.allocations.map((row) => row.allocationQty.text), quantities);
      expect(data.materials.map((row) => row.materialUsed.text), materials);
      expect(
        data.allocations.map((row) => row.allocationDemandId),
        destinations,
      );
      expect(events.destinations, isEmpty);
      expect(events.quantityChanges, 0);
      expect(events.materialChanges, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mouse column resizing preserves an actively typed material controller and its keyboard focus',
    (tester) async {
      final data = _DetailsData();
      _resizeTargets(data);
      final (events, _) = await _pump(
        tester,
        data,
        size: const Size(1800, 1000),
      );
      final controller = data.materials.first.materialUsed;
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && identical(widget.controller, controller),
      );
      await tester.enterText(field, '2999.1250');
      await tester.pump();
      final editable = tester.widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      final focus = editable.focusNode;
      expect(focus.hasFocus, isTrue);
      final writes = events.materialChanges;
      final width = _resizeWidth(tester, DailyRowGroup.materials, 4);
      await _dragResizeHandle(tester, DailyRowGroup.materials, '本次实际用料', 100);
      expect(
        _resizeWidth(tester, DailyRowGroup.materials, 4),
        greaterThan(width),
      );
      expect(tester.widget<TextField>(field).controller, same(controller));
      expect(controller.text, '2999.1250');
      expect(controller.selection, const TextSelection.collapsed(offset: 9));
      expect(focus.hasFocus, isTrue);
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(events.materialChanges, writes);
      expect(events.quantityChanges, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow aligned cards scroll horizontally and keep resize controls reachable without layout errors',
    (tester) async {
      final data = _DetailsData();
      _resizeTargets(data, name: List.filled(5, '长接收产品名称').join());
      await _pump(
        tester,
        data,
        size: const Size(390, 844),
        leadingInset: 44,
        materialsOpen: false,
        textScale: 1.3,
      );
      final table = _resizeTable(DailyRowGroup.allocations);
      final horizontal = find
          .descendant(
            of: find.byKey(
              const ValueKey('daily-product-allocation-table-product'),
            ),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  (widget.axisDirection == AxisDirection.right ||
                      widget.axisDirection == AxisDirection.left),
            ),
          )
          .first;
      final position = tester.state<ScrollableState>(horizontal).position;
      expect(position.maxScrollExtent, greaterThan(200));
      final before = position.pixels;
      final visibleHeader = find.descendant(
        of: table,
        matching: find.text('去向工单'),
      );
      await tester.dragFrom(
        tester.getCenter(visibleHeader),
        const Offset(-120, 0),
      );
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(before));
      final width = _resizeWidth(tester, DailyRowGroup.allocations, 1);
      await _dragResizeHandle(tester, DailyRowGroup.allocations, '接收名称', -60);
      expect(
        _resizeWidth(tester, DailyRowGroup.allocations, 1),
        lessThan(width),
      );
      expect(data.allocations.first.allocationQty.text, '1000');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'RTL column-edge pointer and keyboard directions resize the logical column without business edits',
    (tester) async {
      final data = _DetailsData();
      _resizeTargets(data);
      final events = await _pumpResizeRtl(tester, data);
      final handle = _resizeHandle(DailyRowGroup.allocations, '接收名称');
      final label = find.descendant(
        of: _resizeTable(DailyRowGroup.allocations),
        matching: find.text('接收名称'),
      );
      expect(tester.getCenter(handle).dx, lessThan(tester.getCenter(label).dx));
      final before = _resizeWidth(tester, DailyRowGroup.allocations, 1);
      await _dragResizeHandle(tester, DailyRowGroup.allocations, '接收名称', -100);
      expect(
        _resizeWidth(tester, DailyRowGroup.allocations, 1),
        greaterThan(before + 40),
      );
      final mouse = find.descendant(
        of: handle,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is MouseRegion &&
              widget.cursor == SystemMouseCursors.resizeColumn,
        ),
      );
      final focus = Focus.of(tester.element(mouse));
      focus.requestFocus();
      await tester.pump();
      final width = _resizeWidth(tester, DailyRowGroup.allocations, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(
        _resizeWidth(tester, DailyRowGroup.allocations, 1),
        closeTo(width + 20, 0.01),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        _resizeWidth(tester, DailyRowGroup.allocations, 1),
        closeTo(width, 0.01),
      );
      expect(events.destinations, isEmpty);
      expect(events.quantityChanges, 0);
      expect(data.allocations.first.allocationQty.text, '1000');
      expect(tester.takeException(), isNull);
    },
  );
}
