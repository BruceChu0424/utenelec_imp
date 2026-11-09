import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/ui/table_load_progress_notice.dart';
import 'package:uten_imp/shared/paging/complete_read_progress.dart';

/// 顶部加载进度通知（整卡背景即进度条）的行为契约：
/// - 延迟出现避免闪卡；百分比 = 已验证累计 ÷ 服务端 total，加载中封顶 99%；
/// - 只有完整结果成功返回才 100% + 对勾，停留后自动收起；
/// - 红色关闭只隐藏本轮提示，读取继续，同轮不再唤出，新任务正常重现；
/// - 失败/取消立即退场；未知总量显示不定进度；旧任务迟到不污染新任务。

void main() {
  late TableLoadProgressNoticeController controller;

  Widget host() => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: TableLoadProgressNoticeHost(controller: controller),
      ),
    ),
  );

  setUp(() {
    controller = TableLoadProgressNoticeController();
    addTearDown(controller.detach);
  });

  /// 到卡片稳定可见：start → 首批 → 出现延迟 → 入场动画。
  Future<CompleteReadProgressHandle> appearWithBatch(
    WidgetTester tester, {
    int loaded = 50,
    int total = 500,
  }) async {
    final handle = CompleteReadProgressReporter.start();
    await tester.pump();
    // total <= 0 表示「未知总量」，驱动不定进度分支。
    handle.update(loaded: loaded, total: total > 0 ? total : null);
    await tester.pump();
    await tester.pump(tableLoadNoticeShowDelay);
    await tester.pump(const Duration(milliseconds: 260));
    return handle;
  }

  testWidgets('fast load never flashes the card', (tester) async {
    await tester.pumpWidget(host());
    final handle = CompleteReadProgressReporter.start();
    await tester.pump();
    handle.update(loaded: 30, total: 30);
    await tester.pump();
    handle.finish(succeeded: true);
    await tester.pump();
    await tester.pump(tableLoadNoticeShowDelay * 2);
    expect(find.textContaining('正在加载数据'), findsNothing);
    expect(find.textContaining('数据加载完成'), findsNothing);
  });

  testWidgets('shows real percentage with bold percent including %', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final handle = await appearWithBatch(tester);
    expect(find.textContaining('正在加载数据：10%'), findsOneWidget);
    // 加粗样式（含百分号整体加粗）。
    final text = tester.widget<Text>(find.textContaining('正在加载数据：10%'));
    final spans = (text.textSpan as TextSpan).children!;
    final percent = spans.last as TextSpan;
    expect(percent.text, '10%');
    expect(percent.style?.fontWeight, FontWeight.w700);

    // 后续批次：进度平滑推进，文字同步更新。
    handle.update(loaded: 250, total: 500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('正在加载数据：50%'), findsOneWidget);

    // 加载中即便 loaded == total 也封顶 99%。
    handle.update(loaded: 500, total: 500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('正在加载数据：99%'), findsOneWidget);
  });

  testWidgets('fill width matches the displayed fraction', (tester) async {
    await tester.pumpWidget(host());
    final handle = await appearWithBatch(tester, loaded: 100, total: 400);
    await tester.pump(const Duration(milliseconds: 500));
    final fill = tester.widget<FractionallySizedBox>(
      find.byKey(const ValueKey('load-notice-fill')),
    );
    expect(fill.widthFactor, closeTo(0.25, 0.01));
    handle.update(loaded: 400, total: 400);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final filled = tester.widget<FractionallySizedBox>(
      find.byKey(const ValueKey('load-notice-fill')),
    );
    expect(
      filled.widthFactor,
      closeTo(0.99, 0.01),
      reason: '加载中填充与显示百分比一致（99% 封顶）',
    );
  });

  testWidgets('completion fills 100%, swaps check, then auto dismisses', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final handle = await appearWithBatch(tester);
    expect(find.byKey(const ValueKey('load-notice-loading')), findsOneWidget);
    handle.finish(succeeded: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('数据加载完成：100%'), findsOneWidget);
    expect(find.byKey(const ValueKey('load-notice-done')), findsOneWidget);
    final fill = tester.widget<FractionallySizedBox>(
      find.byKey(const ValueKey('load-notice-fill')),
    );
    expect(fill.widthFactor, 1.0);

    // 完成停留后自动收起，不残留。
    await tester.pump(tableLoadNoticeDoneHold);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('数据加载完成'), findsNothing);
  });

  testWidgets('hover keeps the finished card until the pointer leaves', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final handle = await appearWithBatch(tester);
    handle.finish(succeeded: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final gesture = await tester.startGesture(
      Offset.zero,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('load-notice-fill'))),
    );
    await tester.pump();
    await tester.pump(tableLoadNoticeDoneHold * 3);
    expect(find.textContaining('数据加载完成'), findsOneWidget, reason: '悬停暂停完成态收起');
    await gesture.moveTo(const Offset(5, 500));
    await tester.pump();
    await tester.pump(tableLoadNoticeDoneHold);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('数据加载完成'), findsNothing);
  });

  testWidgets('close hides the notice; loading continues; same round stays '
      'hidden; a new round shows again', (tester) async {
    await tester.pumpWidget(host());
    final handle = await appearWithBatch(tester);
    expect(find.textContaining('正在加载数据：10%'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭加载提示'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.textContaining('正在加载数据'), findsNothing);

    // 后台继续加载：同轮批次与完成都不会让卡片重现。
    handle.update(loaded: 300, total: 500);
    await tester.pump();
    expect(find.textContaining('正在加载数据'), findsNothing);
    handle.finish(succeeded: true);
    await tester.pump();
    await tester.pump(tableLoadNoticeDoneHold * 2);
    expect(find.textContaining('数据加载完成'), findsNothing);

    // 新的独立加载任务：按正常规则重新显示。
    final next = await appearWithBatch(tester, loaded: 30, total: 300);
    expect(find.textContaining('正在加载数据：10%'), findsOneWidget);
    next.finish(succeeded: true);
    await tester.pump();
  });

  testWidgets('failure dismisses the card without completion state', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final handle = await appearWithBatch(tester);
    handle.finish(succeeded: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('正在加载数据'), findsNothing);
    expect(find.textContaining('数据加载完成'), findsNothing);
  });

  testWidgets('unknown total shows indeterminate sweep, then real percent', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final handle = await appearWithBatch(tester, total: 0);
    expect(find.textContaining('正在加载数据…'), findsOneWidget);
    expect(find.byKey(const ValueKey('load-notice-sweep')), findsOneWidget);
    expect(find.byKey(const ValueKey('load-notice-fill')), findsNothing);

    // 取得可靠总量后切换为真实百分比，无扫动。
    handle.update(loaded: 50, total: 200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('正在加载数据：25%'), findsOneWidget);
    expect(find.byKey(const ValueKey('load-notice-sweep')), findsNothing);
    handle.finish(succeeded: true);
    await tester.pump();
  });

  testWidgets('a late old task never touches the new round card', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final oldTask = await appearWithBatch(tester, loaded: 100, total: 1000);
    expect(find.textContaining('正在加载数据：10%'), findsOneWidget);

    // 新一轮加载开始并接管卡片（切页/改筛选）。
    final newTask = CompleteReadProgressReporter.start();
    await tester.pump();
    newTask.update(loaded: 30, total: 300);
    await tester.pump(tableLoadNoticeShowDelay);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('正在加载数据：10%'), findsOneWidget);

    // 旧任务迟到返回：不更新新任务百分比，也不误标完成。
    oldTask.update(loaded: 900, total: 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('正在加载数据：10%'), findsOneWidget);
    oldTask.finish(succeeded: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.textContaining('正在加载数据：10%'),
      findsOneWidget,
      reason: '旧任务完成不得关闭/完成新任务的卡片',
    );
    newTask.finish(succeeded: true);
    await tester.pump();
  });

  testWidgets('empty result ends silently', (tester) async {
    await tester.pumpWidget(host());
    final handle = CompleteReadProgressReporter.start();
    await tester.pump();
    handle.update(loaded: 0, total: 0);
    await tester.pump();
    handle.finish(succeeded: true);
    await tester.pump();
    await tester.pump(tableLoadNoticeShowDelay * 2);
    expect(find.textContaining('正在加载数据'), findsNothing);
    expect(find.textContaining('数据加载完成'), findsNothing);
  });

  testWidgets('reduced motion shows content without entry animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: TableLoadProgressNoticeHost(controller: controller),
          ),
        ),
      ),
    );
    final handle = CompleteReadProgressReporter.start();
    await tester.pump();
    handle.update(loaded: 20, total: 200);
    await tester.pump();
    await tester.pump(tableLoadNoticeShowDelay);
    // 无需推进入场动画：立即完整可见。
    expect(find.textContaining('正在加载数据：10%'), findsOneWidget);
    handle.finish(succeeded: true);
    await tester.pump();
  });
}
