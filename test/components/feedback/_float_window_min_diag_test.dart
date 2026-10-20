// 最小隔离诊断：直接泵 UtenFloatingWindow，量窗口内各层盒子高度。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';

void main() {
  testWidgets('shell sizes', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: UtenFloatingWindow(
                  title: 'T',
                  body: const SizedBox(
                    width: 560,
                    height: 236,
                    child: ColoredBox(color: Colors.red),
                  ),
                  onClose: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final win = tester.element(find.byType(UtenFloatingWindow));
    void walk(Element e, int depth) {
      final w = e.widget;
      final ro = e.findRenderObject();
      final interesting =
          w is DecoratedBox ||
          w is Material ||
          w is Column ||
          w is Stack ||
          w is SizedBox ||
          w is PhysicalModel ||
          w is PhysicalShape;
      if (ro is RenderBox && interesting) {
        final tl = ro.localToGlobal(Offset.zero);
        // ignore: avoid_print
        print(
          '${'  ' * depth}${w.runtimeType}: '
          '(${tl.dx.toStringAsFixed(0)},${tl.dy.toStringAsFixed(0)}) '
          '${ro.size.width.toStringAsFixed(0)}x${ro.size.height.toStringAsFixed(0)}',
        );
      }
      e.visitChildren((c) => walk(c, depth + 1));
    }

    walk(win, 0);
  });
}
