import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
  theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
  home: Scaffold(
    body: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child,
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'category measurement does not register hidden paragraphs with SelectionArea',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          SelectionArea(
            child: UtenSegmentRow<String>(
              selected: const {'a'},
              segments: const [
                ButtonSegment(value: 'a', label: Text('分类一')),
                ButtonSegment(value: 'b', label: Text('分类二的完整名称')),
              ],
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(160, 700));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(900, 700));
      await tester.pumpAndSettle();
      expect(find.text('分类二的完整名称'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open category panel rechecks owner permissions before dispatching',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(160, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var enabled = true;
      var calls = 0;
      late StateSetter ownerState;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) {
              ownerState = setState;
              return UtenSegmentRow<String>(
                selected: const {'a'},
                segments: const [
                  ButtonSegment(value: 'a', label: Text('很长的第一项分类')),
                  ButtonSegment(value: 'b', label: Text('很长的第二项分类')),
                ],
                onSelectionChanged: enabled ? (_) => calls++ : null,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
      await tester.pumpAndSettle();
      ownerState(() => enabled = false);
      await tester.pump();
      await tester.tap(find.text('很长的第二项分类'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide toolbar with overflowing categories opens a complete vertical list',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? chosen = 'pending';
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) => UtenFilterToolbar<String?>(
              autoSelectBadge: false,
              selected: {chosen},
              segments: [
                const UtenFilterSegment(value: null, label: '全部分类'),
                const UtenFilterSegment(
                  value: 'pending',
                  label: '等待财务审核和供应商处理的采购申请',
                  count: 123,
                  countForm: UtenSegmentCountForm.actionable,
                  inProgressCount: 47,
                ),
                for (var i = 0; i < 8; i++)
                  UtenFilterSegment(
                    value: 'c$i',
                    label: '生产车间与委外任务分类 $i',
                    count: 0,
                  ),
              ],
              searchHint: '搜索',
              onSelectionChanged: (value) => setState(() => chosen = value),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
      expect(find.byType(UtenNotificationBadge), findsOneWidget);
      expect(find.byType(UtenInProgressBadge), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SingleChildScrollView &&
              widget.scrollDirection == Axis.horizontal,
        ),
        findsNothing,
      );
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
      await tester.pumpAndSettle();
      final allCategoryOption = find.descendant(
        of: find.byType(ListView),
        matching: find.text('全部分类'),
      );
      expect(allCategoryOption, findsOneWidget);
      expect(find.text('等待财务审核和供应商处理的采购申请').last, findsOneWidget);
      await tester.tap(allCategoryOption);
      await tester.pumpAndSettle();
      expect(
        chosen,
        isNull,
        reason:
            'A nullable segment value is a real selection, distinct from cancel.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [160.0, 320.0]) {
    testWidgets(
      '$width logical width preserves long names and both counts at 200% text',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          _app(
            UtenSegmentRow<String>(
              selected: const {'pending'},
              segments: const [
                ButtonSegment(
                  value: 'pending',
                  label: UtenSegmentBadgeLabel(
                    label: '等待财务审核与供应商处理',
                    count: 120,
                    inProgressCount: 140,
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                ),
                ButtonSegment(value: 'done', label: Text('已完成的历史记录')),
              ],
              onSelectionChanged: (_) {},
            ),
            textScale: 2,
          ),
        );
        await tester.pumpAndSettle();
        final label = tester.widget<Text>(find.text('等待财务审核与供应商处理'));
        expect(label.overflow, isNot(TextOverflow.ellipsis));
        await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
        await tester.pumpAndSettle();
        expect(find.byType(UtenNotificationBadge), findsOneWidget);
        expect(find.byType(UtenInProgressBadge), findsOneWidget);
        expect(tester.takeException(), isNull);
        final panelWidth = tester
            .getSize(find.byWidgetPredicate((widget) => widget is Dialog).last)
            .width;
        expect(panelWidth, lessThanOrEqualTo(width));
      },
    );
  }

  testWidgets(
    'compact tree retains expansion and content state across selection and resizing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(160, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? selected;
      const childName = '名称非常长但必须完整可读的第十层分类';
      PaymentStyleNode node = PaymentStyleNode(
        id: 'leaf',
        code: 'LONG-CODE',
        name: childName,
        children: const [],
      );
      for (var depth = 9; depth >= 0; depth--) {
        node = PaymentStyleNode(
          id: 'n$depth',
          code: '',
          name: '父分类 $depth',
          children: [node],
        );
      }
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, setState) => UtenSplitView(
              selectedLeadingLabel: selected == null ? null : childName,
              selectedLeadingKey: selected,
              leading: UtenCategoryTreeView<PaymentStyleNode>(
                nodes: [node],
                showSearch: false,
                initiallyExpandDepth: 10,
                flatLevelColors: true,
                selectedIds: {?selected},
                onNodeTap: (value) => setState(() => selected = value.id),
              ),
              trailing: const _StatefulContent(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('内容计数 0'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.account_tree_rounded));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(childName),
        240,
        scrollable: find.byType(Scrollable),
      );
      final leaf = tester.widget<Text>(find.text(childName));
      expect(leaf.maxLines, 1);
      expect(leaf.softWrap, isFalse);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              (widget.message?.endsWith(childName) ?? false),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text(childName));
      await tester.pumpAndSettle();
      expect(selected, 'leaf');
      expect(find.text('内容计数 1'), findsOneWidget);
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      await tester.pumpAndSettle();
      expect(find.text('内容计数 1'), findsOneWidget);
      expect(find.text(childName), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _StatefulContent extends StatefulWidget {
  const _StatefulContent();
  @override
  State<_StatefulContent> createState() => _StatefulContentState();
}

class _StatefulContentState extends State<_StatefulContent> {
  var count = 0;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: TextButton(
      onPressed: () => setState(() => count++),
      child: Text('内容计数 $count'),
    ),
  );
}
