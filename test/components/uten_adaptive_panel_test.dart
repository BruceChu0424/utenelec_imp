import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_adaptive_panel.dart';

void main() {
  testWidgets('compact screens use a safe bottom sheet and return the result', (
    tester,
  ) async {
    _setTestSize(tester, const Size(390, 844));

    await tester.pumpWidget(const MaterialApp(home: _PanelHarness()));
    await tester.tap(find.byKey(const Key('open-panel')));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('关闭测试面板'), findsOneWidget);
    final contentSize = tester.getSize(find.byKey(const Key('panel-content')));
    expect(contentSize.width, 390);
    expect(contentSize.height, closeTo(844 * 0.85, 0.1));

    await tester.tap(find.byKey(const Key('complete-panel')));
    await tester.pumpAndSettle();

    expect(find.text('result:selected'), findsOneWidget);
  });

  testWidgets('wide screens use a right drawer with the configured width', (
    tester,
  ) async {
    _setTestSize(tester, const Size(1200, 900));

    await tester.pumpWidget(
      const MaterialApp(home: _PanelHarness(drawerWidth: 720)),
    );
    await tester.tap(find.byKey(const Key('open-panel')));
    await tester.pumpAndSettle();

    final content = find.byKey(const Key('panel-content'));
    expect(tester.getSize(content).width, 720);
    expect(tester.getTopLeft(content).dx, 480);

    await tester.tap(find.byKey(const Key('complete-panel')));
    await tester.pumpAndSettle();

    expect(find.text('result:selected'), findsOneWidget);
  });

  testWidgets('barrier dismissal returns null without committing panel state', (
    tester,
  ) async {
    _setTestSize(tester, const Size(390, 844));

    await tester.pumpWidget(const MaterialApp(home: _PanelHarness()));
    await tester.tap(find.byKey(const Key('open-panel')));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('result:cancelled'), findsOneWidget);
  });
}

void _setTestSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

class _PanelHarness extends StatefulWidget {
  const _PanelHarness({this.drawerWidth = 420});

  final double drawerWidth;

  @override
  State<_PanelHarness> createState() => _PanelHarnessState();
}

class _PanelHarnessState extends State<_PanelHarness> {
  String _result = 'pending';

  Future<void> _open() async {
    final result = await showUtenAdaptivePanel<String>(
      context: context,
      drawerWidth: widget.drawerWidth,
      barrierLabel: '关闭测试面板',
      builder: (panelContext) => ColoredBox(
        key: const Key('panel-content'),
        color: Theme.of(panelContext).colorScheme.surface,
        child: Center(
          child: FilledButton(
            key: const Key('complete-panel'),
            onPressed: () => Navigator.of(panelContext).pop('selected'),
            child: const Text('完成'),
          ),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _result = result ?? 'cancelled');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          FilledButton(
            key: const Key('open-panel'),
            onPressed: _open,
            child: const Text('打开'),
          ),
          Text('result:$_result'),
        ],
      ),
    );
  }
}
