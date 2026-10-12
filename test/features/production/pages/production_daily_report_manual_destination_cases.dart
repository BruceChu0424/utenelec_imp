part of 'production_daily_report_exact_segment_test.dart';

Future<void> _chooseAddedDestination(
  WidgetTester tester,
  DailyGridRow product,
  String demand,
  String qty,
) async {
  final add = find.byKey(
    ValueKey('daily-product-add-allocation-${product.localRowId}'),
  );
  await Scrollable.ensureVisible(tester.element(add), alignment: 0.35);
  await tester.pumpAndSettle();
  await tester.tap(add);
  await tester.pumpAndSettle();
  const Key dropdownKey = ValueKey('daily-add-destination-target');
  await tester.tap(find.byKey(dropdownKey));
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(
      ValueKey<(String, Key?, String?)>((
        'uten-dropdown-option',
        dropdownKey,
        demand,
      )),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('daily-add-destination-quantity')),
    qty,
  );
  await tester.tap(find.byKey(const ValueKey('daily-add-destination-confirm')));
  await tester.pumpAndSettle();
}

void registerDailyReportManualDestinationTests() {
  testWidgets('手动去向：多货品共享接收额度，未勾选行不占本次额度', (tester) async {
    final grid = await _pumpAllocationPage(tester);
    final first = grid.rows.single;
    first.qty.text = '4';
    await tester.pumpAndSettle();
    await _chooseAddedDestination(tester, first, 'A', '3');
    final second = first.clone()..qty.text = '4';
    grid.addRows([second]);
    grid.setSelected([second], true);
    await tester.pumpAndSettle();
    await _chooseAddedDestination(tester, second, 'A', '3');
    expect(first.allocationRows.first.allocationQty.text, '3');
    expect(second.allocationRows.first.allocationQty.text, '3');
    grid.setSelected([second], false);
    await tester.pumpAndSettle();
    first.qty.text = '6';
    await tester.pumpAndSettle();
    final allocation = first.allocationRows.first;
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            identical(widget.controller, allocation.allocationQty),
      ),
      '6',
    );
    await tester.tap(find.byTooltip('收起产出去向').first);
    await tester.pumpAndSettle();
    expect(first.allocationRows.single.allocationQty.text, '6');
    expect(first.allocationRows.single.allocationIssue.value, isNull);
    expect(
      second.allocationRows.first.allocationQty.text,
      '3',
      reason: '未提交的安排保留但不占本次额度',
    );
    grid.setSelected([second], true);
    await tester.pumpAndSettle();
    expect(
      first.allocationRows.any((row) => row.allocationIssue.value != null),
      isTrue,
      reason: '重新勾选后两行总计9不能越过共同接收额度6',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动去向：品质恢复整行一个去向，不能添加分拆且不足接收量不替换', (tester) async {
    final grid = await _pumpAllocationPage(tester);
    final product = grid.rows.single;
    product.fqcRecoveryAuthorizationId = 'recovery-1';
    product.qty.text = '5';
    await tester.pumpAndSettle();
    expect(product.allocationRows, hasLength(1));
    expect(product.allocationRows.single.allocationQty.text, '5');
    expect(
      find.byKey(
        ValueKey('daily-product-add-allocation-${product.localRowId}'),
      ),
      findsNothing,
    );
    product.qty.text = '4';
    await tester.pumpAndSettle();
    final allocation = product.allocationRows.single;
    expect(allocation.allocationQty.text, '4');
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            identical(widget.controller, allocation.allocationQty),
      ),
      findsNothing,
    );
    final dropdown = find.byKey(
      ValueKey('daily-allocation-destination-${identityHashCode(allocation)}'),
    );
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    final fieldKey = tester.widget<UtenDropdownField>(dropdown).key;
    await tester.tap(
      find.byKey(
        ValueKey<(String, Key?, String?)>((
          'uten-dropdown-option',
          fieldKey,
          'B',
        )),
      ),
    );
    await tester.pumpAndSettle();
    expect(product.allocationRows.single.allocationDemandId, 'A');
    expect(product.allocationRows.single.allocationQty.text, '4');
    expect(find.textContaining('品质恢复报工只能整行安排一个去向'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动去向：部分报工只安排选中工单、余量仓库、添加移除与重开均不丢数量', (tester) async {
    Map<String, dynamic>? saved;
    final capture = Platform.environment['UTEN_CAPTURE_DAILY_CARDS'] == '1';
    final captureKey = capture ? GlobalKey() : null;
    if (capture) await loadAuditScreenshotFonts(tester);
    final grid = await _pumpAllocationPage(
      tester,
      onCreate: (body) => saved = body,
      captureKey: captureKey,
      theme: capture ? auditScreenshotTheme(buildLightTheme()) : null,
    );
    var product = grid.rows.single;
    product.qty.text = '4';
    await tester.pumpAndSettle();
    await _chooseAddedDestination(tester, product, 'A', '1');
    expect(product.allocationManual, isTrue);
    expect(
      product.allocationRows.map(
        (row) => (row.allocationDemandId, row.allocationQty.text),
      ),
      [('A', '1'), (null, '3')],
    );
    await _chooseAddedDestination(tester, product, 'B', '2');
    expect(
      product.allocationRows.map(
        (row) => (row.allocationDemandId, row.allocationQty.text),
      ),
      [('A', '1'), ('B', '2'), (null, '1')],
    );
    final state =
        tester.state(find.byType(ProductionDailyReportEditPage))
            as FormDraftMixin;
    final draft =
        jsonDecode(jsonEncode(state.captureFormDraft()))
            as Map<String, dynamic>;
    expect((draft['rows'] as List).cast<Map<String,dynamic>>().single['allocationManual'], isTrue);
    final restoration = state.restoreFormDraft(draft);
    await tester.pumpAndSettle();
    await restoration;
    await tester.pumpAndSettle();
    product = grid.rows.single;
    expect(product.allocationManual, isTrue);
    expect(
      product.allocationRows.map(
        (row) => (row.allocationDemandId, row.allocationQty.text),
      ),
      [('A', '1'), ('B', '2'), (null, '1')],
    );
    final b = product.allocationRows.singleWhere(
      (row) => row.allocationDemandId == 'B',
    );
    await tester.tap(
      find.byKey(ValueKey('daily-remove-allocation-${b.localRowId}')),
    );
    await tester.pumpAndSettle();
    expect(
      product.allocationRows.map(
        (row) => (row.allocationDemandId, row.allocationQty.text),
      ),
      [('A', '1'), (null, '3')],
    );
    await _chooseAddedDestination(tester, product, 'B', '2');
    if (capture) {
        Scrollable.of(
          tester.element(find.byType(UtenEditableGrid<DailyGridRow>)),
          axis: Axis.vertical,
        ).position.jumpTo(0);
      await tester.pumpAndSettle();
      await saveAuditScreenshot(
        tester,
        captureKey!,
        'daily-report-manual-destinations',
      );
    }
    await tester.tap(find.byTooltip('收起产出去向'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
    await tester.pumpAndSettle();
    expect((saved!['items'] as List).cast<Map<String,dynamic>>().single['qty'], 4);
    expect((saved!['items'] as List).cast<Map<String,dynamic>>().single['allocations'], [
      {'directTransferDemandId': 'A', 'qty': 1},
      {'directTransferDemandId': 'B', 'qty': 2},
      {'directTransferDemandId': null, 'qty': 1},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动去向：取消保持系统建议，已选工单禁止重复添加', (tester) async {
    final grid = await _pumpAllocationPage(tester);
    final product = grid.rows.single;
    final before = outputAllocationBody(product);
    await tester.tap(
      find.byKey(
        ValueKey('daily-product-add-allocation-${product.localRowId}'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('daily-add-destination-cancel')),
    );
    await tester.pumpAndSettle();
    expect(product.allocationManual, isFalse);
    expect(outputAllocationBody(product), before);
    await _chooseAddedDestination(tester, product, 'A', '3');
    await tester.tap(
      find.byKey(
        ValueKey('daily-product-add-allocation-${product.localRowId}'),
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<UtenDropdownField>(
      find.byKey(const ValueKey('daily-add-destination-target')),
    );
    expect(
      field.items.singleWhere((item) => item.value == 'A').enabled,
      isFalse,
    );
    expect(
      field.items.singleWhere((item) => item.value == 'B').enabled,
      isTrue,
    );
    await tester.tap(
      find.byKey(const ValueKey('daily-add-destination-cancel')),
    );
    await tester.pumpAndSettle();
    expect(
      product.allocationRows.map(
        (row) => (row.allocationDemandId, row.allocationQty.text),
      ),
      [('A', '3'), (null, '7')],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动去向：选择期间主行数量变化不套用旧选择', (tester) async {
    final grid = await _pumpAllocationPage(tester);
    final product = grid.rows.single;
    final add = find.byKey(
      ValueKey('daily-product-add-allocation-${product.localRowId}'),
    );
    await tester.tap(add);
    await tester.pumpAndSettle();
    const Key dropdownKey = ValueKey('daily-add-destination-target');
    await tester.tap(find.byKey(dropdownKey));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<(String, Key?, String?)>((
          'uten-dropdown-option',
          dropdownKey,
          'A',
        )),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('daily-add-destination-quantity')),
      '3',
    );
    product.qty.text = '5';
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('daily-add-destination-confirm')),
    );
    await tester.pumpAndSettle();
    expect(product.allocationManual, isFalse);
    expect(product.qty.text, '5');
    expect(product.allocationRows.single.allocationQty.text, '5');
    expect(find.textContaining('来源或数量已经变化'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
