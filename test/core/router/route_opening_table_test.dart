import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_panel_opening_scope.dart';
import 'package:uten_imp/core/router/route_transition_tracker.dart';
import 'package:uten_imp/core/theme/uten_anim.dart';
import 'package:uten_imp/core/theme/uten_page_transitions.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row extends EditableGridRow {}

class _Detail extends StatefulWidget {
  const _Detail({required this.onRead});

  final VoidCallback onRead;

  @override
  State<_Detail> createState() => _DetailState();
}

class _DetailState extends State<_Detail> {
  final _grid = UtenEditableGridController<_Row>(initial: [_Row()]);
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    // The page's read/ownership setup mounts immediately, independently of
    // whether its expensive table cells are allowed to build this frame.
    widget.onRead();
    Future<void>.value().then((_) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _grid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text(_loaded ? 'read complete' : 'read pending'),
        TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('return to detail'),
                ),
              ),
            ),
          ),
          child: const Text('visit child'),
        ),
        if (_loaded) ...[
          Expanded(
            child: MasterDataTableView<int>(
              items: const [1],
              showColumnChooser: false,
              showFullscreenToggle: false,
              rowKeyOf: (row) => '$row',
              columns: [
                MasterColumnDef<int>(
                  key: 'name',
                  label: 'Name',
                  width: 300,
                  value: (_) => 'original',
                  cellBuilder: (_, _) => TextFormField(
                    key: const Key('route-master-input'),
                    initialValue: 'original',
                  ),
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: UtenEditableGrid<_Row>(
                controller: _grid,
                showAddRow: false,
                showColumnSettings: false,
                columns: [
                  EditableGridColumn<_Row>(
                    key: 'name',
                    label: 'Name',
                    width: 300,
                    cellBuilder: (_, _) => TextFormField(
                      key: const Key('route-editable-input'),
                      initialValue: 'original',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

Future<void> _pumpApp(
  WidgetTester tester,
  VoidCallback onRead, {
  bool reduceMotion = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: TargetPlatform.windows,
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.windows: TrackedPageTransitionsBuilder(
              UtenFadePageTransitionsBuilder(),
            ),
          },
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(builder: (_) => _Detail(onRead: onRead)),
            ),
            child: const Text('open detail'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(RouteTransitionTracker.instance.reset);

  testWidgets(
    'reads run during entry; tables mount after motion and retain edits',
    (tester) async {
      var reads = 0;
      await _pumpApp(tester, () => reads++);
      await tester.tap(find.text('open detail'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(reads, 1);
      expect(find.text('read complete'), findsOneWidget);
      expect(
        find.byKey(const Key('route-master-input')),
        findsNothing,
        reason:
            'opening scopes: ${tester.widgetList<UtenOpeningScope>(find.byType(UtenOpeningScope)).map((scope) => scope.ready).toList()}; '
            'route status: ${ModalRoute.of(tester.element(find.text('read complete')))?.animation?.status}',
      );
      expect(find.byKey(const Key('route-editable-input')), findsNothing);

      await tester.pump(UtenAnim.fast);
      await tester.pumpAndSettle();
      final master = find.byKey(const Key('route-master-input'));
      final editable = find.byKey(const Key('route-editable-input'));
      expect(master, findsOneWidget);
      expect(editable, findsOneWidget);
      await tester.enterText(master, 'master draft');
      await tester.enterText(editable, 'editable draft');
      final masterElement = tester.element(master);
      final editableElement = tester.element(editable);

      await tester.tap(find.text('visit child'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('return to detail'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.element(master), same(masterElement));
      expect(tester.element(editable), same(editableElement));
      expect(find.text('master draft'), findsOneWidget);
      expect(find.text('editable draft'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion releases ready tables without an opening wait', (
    tester,
  ) async {
    var reads = 0;
    await _pumpApp(tester, () => reads++, reduceMotion: true);
    await tester.tap(find.text('open detail'));
    await tester.pump();
    await tester.pump();
    expect(reads, 1);
    expect(find.byKey(const Key('route-master-input')), findsOneWidget);
    expect(find.byKey(const Key('route-editable-input')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a ready nested scope waits for the outer opening scope', (
    tester,
  ) async {
    final ready = ValueNotifier(false);
    addTearDown(ready.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: ready,
          builder: (_, value, _) => UtenOpeningScope(
            ready: value,
            child: UtenPanelOpeningScope(
              ready: true,
              child: UtenPanelDeferredView(
                builder: (_) => const Text('nested heavy content'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('nested heavy content'), findsNothing);
    ready.value = true;
    await tester.pump();
    expect(find.text('nested heavy content'), findsOneWidget);
  });
}
