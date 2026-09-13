import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';

void main() {
  testWidgets('portal overlay mounts full-screen when visible', (tester) async {
    var show = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Stack(
              children: [
                TextButton(
                  onPressed: () => setState(() => show = true),
                  child: const Text('show'),
                ),
                if (show)
                  const Positioned.fill(
                    child: UtenBusyOverlay(
                      title: '正在探针',
                      semanticsKey: Key('probe-card'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('probe-card')), findsOneWidget);
    expect(find.text('正在探针'), findsOneWidget);
    // 全屏蒙版在场（MaterialApp 路由自身也带一个 ModalBarrier，只验≥2）
    expect(find.byType(ModalBarrier), findsAtLeastNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
