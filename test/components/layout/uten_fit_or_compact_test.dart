import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_app_bar_action_scope.dart';
import 'package:uten_imp/components/layout/uten_fit_or_compact.dart';

void main() {
  testWidgets(
    'hidden native actions and tooltips rebuild across narrow large-text windows',
    (tester) async {
      tester.view.physicalSize = const Size(1800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late StateSetter update;
      var revision = 0;
      var scale = 1.0;
      var forced = false;
      final calls = <String>[];
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            final current = revision;
            return MaterialApp(
              theme: ThemeData(platform: TargetPlatform.windows),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 1200,
                    height: 96,
                    child: UtenFitOrCompact(
                      forceCompact: forced,
                      expanded: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          UtenAppBarActionPresentation(
                            child: current.isEven
                                ? IconButton(
                                    key: const Key('native-action'),
                                    tooltip: '原生图标$current',
                                    icon: const Icon(Icons.save),
                                    onPressed: () => calls.add('icon-$current'),
                                  )
                                : TextButton(
                                    key: const Key('native-action'),
                                    onPressed: () => calls.add('text-$current'),
                                    child: Text('替换后的原生操作 $current'),
                                  ),
                          ),
                          UtenAppBarActionPresentation(
                            child: Tooltip(
                              message: '原生文本提示$current',
                              child: TextButton(
                                onPressed: () => calls.add('detail-$current'),
                                child: Text(
                                  '需要完整保留的原生操作标签与当前完整业务状态及后续办理责任提示 $current',
                                ),
                              ),
                            ),
                          ),
                          if (current > 0)
                            UtenAppBarActionPresentation(
                              child: IconButton(
                                tooltip: '新增动作$current',
                                icon: const Icon(Icons.add),
                                onPressed: () => calls.add('add-$current'),
                              ),
                            ),
                        ],
                      ),
                      compact: TextButton(
                        key: const Key('compact-action'),
                        onPressed: () => calls.add('compact-$current'),
                        child: const Text('更多操作'),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('native-action'))),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('原生图标0'), findsOneWidget);

      // First hide the expanded Row while its tooltip is alive, then replace
      // its native button/render subtree and insert another hidden action.
      tester.view.physicalSize = const Size(320, 320);
      update(() => scale = 2);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final window in [const Size(320, 320), const Size(640, 240)]) {
        tester.view.physicalSize = window;
        update(() => revision++);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find
              .byKey(const Key('native-action'), skipOffstage: false)
              .hitTestable(),
          findsNothing,
        );
        await tester.tap(find.byKey(const Key('compact-action')).hitTestable());
        await tester.pumpAndSettle();
        expect(calls.last, 'compact-$revision');
      }
      await mouse.moveTo(const Offset(1700, 800));
      tester.view.physicalSize = const Size(1800, 900);
      update(() => scale = 1);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('native-action')).hitTestable());
      expect(calls.last, 'icon-2');

      update(() => forced = true);
      await tester.pumpAndSettle();
      update(() => revision = 3);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('compact-action')).hitTestable());
      expect(calls.last, 'compact-3');
      update(() => forced = false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('native-action')).hitTestable());
      expect(calls.last, 'text-3');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'both branches have bounded layout and shared height but only one is interactive',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final expandedFocus = FocusNode();
        final compactFocus = FocusNode();
        addTearDown(expandedFocus.dispose);
        addTearDown(compactFocus.dispose);
        final layouts = <String, BoxConstraints>{};
        final painted = <String>[];
        final calls = <String>[];
        late StateSetter update;
        var width = 240.0;
        var forced = true;
        await tester.pumpWidget(
          _app(
            StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return SizedBox(
                  width: width,
                  height: 64,
                  child: UtenFitOrCompact(
                    forceCompact: forced,
                    expanded: _LayoutProbe(
                      onLayout: (value) => layouts['expanded'] = value,
                      onPaint: () => painted.add('expanded'),
                      child: Semantics(
                        container: true,
                        explicitChildNodes: true,
                        label: 'expanded-only',
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: TextButton(
                                key: const Key('expanded-focus'),
                                focusNode: expandedFocus,
                                onPressed: () => calls.add('expanded'),
                                child: const Text('隐藏分支中的原生编辑操作', maxLines: 1),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    compact: _LayoutProbe(
                      onLayout: (value) => layouts['compact'] = value,
                      onPaint: () => painted.add('compact'),
                      child: Semantics(
                        container: true,
                        explicitChildNodes: true,
                        label: 'compact-only',
                        child: TextButton(
                          key: const Key('compact-focus'),
                          focusNode: compactFocus,
                          onPressed: () => calls.add('compact'),
                          child: const Text('操作'),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        for (final constraints in layouts.values) {
          expect(constraints.hasBoundedWidth, isTrue);
          expect(constraints.hasBoundedHeight, isTrue);
          expect(constraints.minHeight, 64);
        }
        expect(layouts.keys, containsAll(['expanded', 'compact']));
        expect(layouts['expanded']!.maxWidth, greaterThan(240));
        expect(painted, isNotEmpty);
        expect(painted.toSet(), {'compact'});
        expect(find.bySemanticsLabel('expanded-only'), findsNothing);
        expect(find.bySemanticsLabel('compact-only'), findsOneWidget);
        expect(expandedFocus.canRequestFocus, isFalse);
        expandedFocus.requestFocus();
        await tester.pump();
        expect(expandedFocus.hasFocus, isFalse);
        compactFocus.requestFocus();
        await tester.pump();
        expect(compactFocus.hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(calls, ['compact']);
        expect(
          find
              .byKey(const Key('expanded-focus'), skipOffstage: false)
              .hitTestable(),
          findsNothing,
        );
        expect(
          tester.getSize(find.byKey(const Key('compact-focus'))).height,
          64,
        );

        painted.clear();
        update(() {
          width = 760;
          forced = false;
        });
        await tester.pumpAndSettle();
        expect(painted.toSet(), {'expanded'});
        expect(find.bySemanticsLabel('expanded-only'), findsOneWidget);
        expect(find.bySemanticsLabel('compact-only'), findsNothing);
        expect(expandedFocus.canRequestFocus, isTrue);
        expect(compactFocus.canRequestFocus, isFalse);
        expect(compactFocus.hasFocus, isFalse);
        expect(
          find
              .byKey(const Key('compact-focus'), skipOffstage: false)
              .hitTestable(),
          findsNothing,
        );
        await tester.tap(find.byKey(const Key('expanded-focus')).hitTestable());
        expect(calls, ['compact', 'expanded']);
        expect(
          tester.getSize(find.byKey(const Key('expanded-focus'))).height,
          64,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'intrinsics and dry layout follow width and forced presentation',
    (tester) async {
      late StateSetter update;
      var width = 120.0;
      var forced = false;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: width,
                  minHeight: 52,
                  maxHeight: 52,
                ),
                child: UtenFitOrCompact(
                  key: const Key('measured-fit'),
                  forceCompact: forced,
                  expanded: const SizedBox(width: 300, height: 40),
                  compact: const SizedBox(width: 80, height: 28),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final render = tester.renderObject<RenderBox>(
        find.byKey(const Key('measured-fit')),
      );
      expect(render.size, const Size(80, 52));
      expect(render.getDryLayout(render.constraints), render.size);
      expect(render.getMaxIntrinsicHeight(120), 28);
      update(() => width = 400);
      await tester.pumpAndSettle();
      expect(render.size, const Size(300, 52));
      expect(render.getDryLayout(render.constraints), render.size);
      expect(render.getMaxIntrinsicHeight(400), 40);
      update(() => forced = true);
      await tester.pumpAndSettle();
      expect(render.size, const Size(80, 52));
      expect(render.getDryLayout(render.constraints), render.size);
      expect(render.getMinIntrinsicWidth(double.infinity), 80);
      expect(render.getMaxIntrinsicWidth(double.infinity), 80);
      expect(render.getMaxIntrinsicHeight(400), 28);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _app(Widget child, {double scale = 1}) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.windows),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe({
    required this.onLayout,
    required this.onPaint,
    required super.child,
  });

  final ValueChanged<BoxConstraints> onLayout;
  final VoidCallback onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _LayoutProbeRenderBox(onLayout, onPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    _LayoutProbeRenderBox renderObject,
  ) {
    renderObject
      ..onLayout = onLayout
      ..onPaint = onPaint;
  }
}

class _LayoutProbeRenderBox extends RenderProxyBox {
  _LayoutProbeRenderBox(this.onLayout, this.onPaint);
  ValueChanged<BoxConstraints> onLayout;
  VoidCallback onPaint;

  @override
  void performLayout() {
    onLayout(constraints);
    super.performLayout();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    onPaint();
    super.paint(context, offset);
  }
}
