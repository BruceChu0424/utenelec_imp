part of 'material_analysis_one_table_test.dart';

bool _isMaterialSummary(WidgetTester tester) {
  final table = _presentationTable(tester);
  return table.items.any(
    (row) =>
        _presentationRowKey(table, row as Object)!.startsWith('AGGREGATE|'),
  );
}

void materialAnalysisViewTransitionCases() {
  testWidgets(
    'view transition reduced motion still paints two loading frames',
    (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _pump(tester);
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('material-view-switch-progress')),
        findsOneWidget,
      );
      expect(_isMaterialSummary(tester), isFalse);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('material-view-switch-opacity')),
            )
            .duration,
        Duration.zero,
      );
      await tester.pump();
      expect(
        find.byKey(const Key('material-view-switch-progress')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(_isMaterialSummary(tester), isTrue);
      expect(
        find.byKey(const Key('material-view-switch-progress')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('view transition cancels a pending projection across accounts', (
    tester,
  ) async {
    final session = _OrderAuthoritySession();
    await _pump(tester, session: session);
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pump();
    session.switchAccount('second-account');
    await tester.pumpAndSettle();
    expect(_isMaterialSummary(tester), isFalse);
    expect(
      find.byKey(const Key('material-view-switch-progress')),
      findsNothing,
    );
    expect(_submits(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'view transition keeps the previous table visible and interactive while preparing',
    (tester) async {
      await _pump(tester);
      final tableFinder = find.byKey(
        const Key('material-analysis-material-table'),
      );
      final originalState = tester.state(tableFinder);
      final originalItems = _presentationTable(tester).items;
      await tester.tap(
        find.byKey(const ValueKey('material-bom-layout-material')),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('material-view-switch-progress')),
        findsOneWidget,
      );
      expect(
        _presentationTable(tester).items,
        same(originalItems),
        reason:
            'the loading feedback paints before the heavy projection changes',
      );
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('material-view-switch-opacity')),
            )
            .opacity,
        1,
      );
      expect(tester.state(tableFinder), same(originalState));
      await tester.pump(const Duration(milliseconds: 60));
      final opacity = tester.widget<AnimatedOpacity>(
        find.byKey(const Key('material-view-switch-opacity')),
      );
      final fade = tester.widget<FadeTransition>(
        find.byWidgetPredicate(
          (widget) =>
              widget is FadeTransition &&
              identical(widget.child, opacity.child),
        ),
      );
      expect(fade.opacity.value, 1);
      expect(
        find.ancestor(
          of: tableFinder,
          matching: find.byWidgetPredicate(
            (widget) => widget is IgnorePointer && widget.ignoring,
          ),
        ),
        findsNothing,
        reason:
            'read-only preparation must not disable scrolling or interaction',
      );
      expect(_presentationTable(tester).items, same(originalItems));
      await tester.pumpAndSettle();
      expect(_isMaterialSummary(tester), isTrue);
      expect(
        find.byKey(const Key('material-view-switch-progress')),
        findsNothing,
      );
      expect(tester.state(tableFinder), same(originalState));
      expect(tableFinder, findsOneWidget);
      expect(_submits(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('view transition honors the last rapid intent and disposal', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('material-bom-layout-product')));
    await tester.pumpAndSettle();
    expect(_isMaterialSummary(tester), isFalse);
    expect(
      find.byKey(const Key('material-view-switch-progress')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('material-bom-layout-material')),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(_submits(), isEmpty);
  });
}
