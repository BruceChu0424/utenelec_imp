import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_adaptive_panel.dart';
import 'package:uten_imp/components/layout/uten_panel_opening_scope.dart';

void main() {
  testWidgets('a floating panel starts fully outside the viewport', (
    tester,
  ) async {
    _setTestSize(tester, const Size(1200, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showUtenAdaptivePanel<void>(
                context: context,
                panelMargin: const EdgeInsetsDirectional.fromSTEB(
                  0,
                  16,
                  16,
                  16,
                ),
                builder: (_) => const Text('浮动内容'),
              ),
              child: const Text('打开浮动面板'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开浮动面板'));
    await tester.pump();
    final panel = find.byKey(const Key('uten-adaptive-panel'));
    expect(tester.getTopLeft(panel).dx, 1200);
    await tester.pumpAndSettle();
    expect(tester.getTopRight(panel).dx, 1184);
    expect(tester.getTopLeft(panel).dy, 16);
    expect(find.text('浮动内容'), findsOneWidget);
  });

  testWidgets(
    'panel shell animates before heavy content is mounted, including exit',
    (tester) async {
      _setTestSize(tester, const Size(1200, 900));
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showUtenAdaptivePanel<void>(
                  context: context,
                  builder: (_) => UtenPanelDeferredView(
                    builder: (context) {
                      builds++;
                      return TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭重内容'),
                      );
                    },
                  ),
                ),
                child: const Text('打开重面板'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开重面板'));
      await tester.pump();
      expect(builds, 0);
      expect(find.text('加载中…'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 150));
      final panel = find.byKey(const Key('uten-adaptive-panel'));
      final entering = tester.getTopLeft(panel).dx;
      expect(entering, greaterThan(300));
      expect(entering, lessThan(1200));
      expect(builds, 0);
      await tester.pumpAndSettle();
      expect(builds, 1);
      expect(tester.getTopLeft(panel).dx, 300);
      await tester.tap(find.text('关闭重内容'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getTopLeft(panel).dx, greaterThan(300));
      expect(builds, 1);
      await tester.pumpAndSettle();
      expect(find.text('关闭重内容'), findsNothing);
    },
  );

  testWidgets(
    'reduced motion opens immediately without a deferred content frame',
    (tester) async {
      _setTestSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: const _PanelHarness(),
        ),
      );
      await tester.tap(find.byKey(const Key('open-panel')));
      await tester.pump();
      expect(find.byKey(const Key('panel-content')), findsOneWidget);
      expect(find.text('加载中…'), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const Key('uten-adaptive-panel'))).dx,
        300,
      );
    },
  );

  testWidgets('RTL panels enter and leave from the leading screen edge', (
    tester,
  ) async {
    _setTestSize(tester, const Size(1200, 900));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const _PanelHarness(),
      ),
    );
    await tester.tap(find.byKey(const Key('open-panel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final panel = find.byKey(const Key('uten-adaptive-panel'));
    expect(tester.getTopLeft(panel).dx, lessThan(0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(panel).dx, 0);
    await tester.tap(find.byKey(const Key('complete-panel')));
    await tester.pumpAndSettle();
    expect(find.text('result:selected'), findsOneWidget);
  });

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

  // 2026-10-17 宽度口径：比例优先——min(屏宽, max(drawerWidth, 屏宽 × 档位))。
  // 1200 屏 browse 档（默认）= 1200 × 0.75 = 900 > 720 下限。
  testWidgets('wide screens use a right drawer sized by width fraction', (
    tester,
  ) async {
    _setTestSize(tester, const Size(1200, 900));

    await tester.pumpWidget(
      const MaterialApp(home: _PanelHarness(drawerWidth: 720)),
    );
    await tester.tap(find.byKey(const Key('open-panel')));
    await tester.pumpAndSettle();

    final content = find.byKey(const Key('panel-content'));
    expect(tester.getSize(content).width, 900);
    expect(tester.getTopLeft(content).dx, 300);

    await tester.tap(find.byKey(const Key('complete-panel')));
    await tester.pumpAndSettle();

    expect(find.text('result:selected'), findsOneWidget);
  });

  /// form / none 档不放大到 browse：表单与菜单类面板保持自己的宽度语义。
  testWidgets('form and none fractions keep the panel narrow', (tester) async {
    _setTestSize(tester, const Size(1200, 900));

    await tester.pumpWidget(
      const MaterialApp(
        home: _PanelHarness(widthFraction: UtenPanelWidth.form),
      ),
    );
    await tester.tap(find.byKey(const Key('open-panel')));
    await tester.pumpAndSettle();
    // form 档 = 1200 × 0.35 = 420（等于默认下限，不取更大者以外的东西）。
    expect(tester.getSize(find.byKey(const Key('panel-content'))).width, 420);
    await tester.tap(find.byKey(const Key('complete-panel')));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      const MaterialApp(
        home: _PanelHarness(widthFraction: UtenPanelWidth.none),
      ),
    );
    await tester.tap(find.byKey(const Key('open-panel')));
    await tester.pumpAndSettle();
    // none 档 = drawerWidth 原值（默认 420），菜单类不放大。
    expect(tester.getSize(find.byKey(const Key('panel-content'))).width, 420);
  });

  /// 下限在比例之上时生效：小屏（800 × 0.75 = 600 < 720）取 drawerWidth 下限。
  testWidgets('drawerWidth floors the panel on smaller wide screens', (
    tester,
  ) async {
    _setTestSize(tester, const Size(800, 900));

    await tester.pumpWidget(
      const MaterialApp(home: _PanelHarness(drawerWidth: 720)),
    );
    await tester.tap(find.byKey(const Key('open-panel')));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byKey(const Key('panel-content'))).width, 720);
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
  const _PanelHarness({this.drawerWidth = 420, this.widthFraction});

  final double drawerWidth;
  final double? widthFraction;

  @override
  State<_PanelHarness> createState() => _PanelHarnessState();
}

class _PanelHarnessState extends State<_PanelHarness> {
  String _result = 'pending';

  Future<void> _open() async {
    final result = await showUtenAdaptivePanel<String>(
      context: context,
      drawerWidth: widget.drawerWidth,
      widthFraction: widget.widthFraction ?? UtenPanelWidth.browse,
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
