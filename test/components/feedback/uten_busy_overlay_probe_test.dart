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
    expect(find.text('请勿重复点击或关闭页面，完成后自动继续。'), findsOneWidget);
    // 全屏蒙版在场（MaterialApp 路由自身也带一个 ModalBarrier，只验≥2）
    expect(find.byType(ModalBarrier), findsAtLeastNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact progress hides only generic copy and preserves the blocking task',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: UtenBusyOverlay(
                title: '正在保存',
                description: '将保留审核记录',
                semanticsKey: Key('compact-probe-card'),
                showDoNotLeaveHint: false,
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('正在保存'), findsOneWidget);
        expect(find.text('将保留审核记录'), findsOneWidget);
        expect(find.textContaining('请勿重复'), findsNothing);
        expect(
          tester
              .widget<UtenBusyOverlayCard>(find.byType(UtenBusyOverlayCard))
              .showDoNotLeaveHint,
          isFalse,
        );
        expect(
          tester
              .getSemantics(find.byKey(const Key('compact-probe-card')))
              .getSemanticsData()
              .label,
          '正在保存。将保留审核记录。',
        );
        expect(find.byType(ModalBarrier), findsAtLeastNWidgets(2));
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
