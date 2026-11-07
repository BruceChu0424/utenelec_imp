import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';

void main() {
  testWidgets('post-frame modal yield schedules its awaited frame', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    var shown = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      UtenBusyOverlay.yieldWhile(() async => shown = true);
    });
    await tester.pumpAndSettle();
    expect(shown, isTrue);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('left spinner is centered beside wrapped loading copy', (
    tester,
  ) async {
    for (final width in [360.0, 1024.0]) {
      await tester.binding.setSurfaceSize(Size(width, 800));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: const Scaffold(
            body: Center(
              child: UtenBusyOverlayCard(
                title: '正在提交生产日报',
                description: '正在保存报工和用料记录，请勿重复提交或离开本页。',
              ),
            ),
          ),
        ),
      );
      final spinner = tester.getRect(find.byType(CircularProgressIndicator));
      final title = tester.getRect(find.text('正在提交生产日报'));
      final hint = tester.getRect(find.textContaining('完成后自动继续'));
      expect(spinner.right, lessThan(title.left));
      expect(spinner.center.dy, closeTo((title.top + hint.bottom) / 2, 1));
      expect(tester.takeException(), isNull);
    }
    await tester.binding.setSurfaceSize(null);
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
