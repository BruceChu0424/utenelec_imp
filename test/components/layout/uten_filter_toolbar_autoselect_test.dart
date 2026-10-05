// UtenFilterToolbar 进页面默认选中（2026-10-04 用户口径）的组件级锁定：
// 红 → 黄 → 都没有不选；选中一旦发生（自动或手动）不再自动改选；
// 小类行锁定（enabled=false）时不选，解锁后照常判序。
// 附带锁定 UtenSegmentRow 的每格自适应宽度（替代等宽 SegmentedButton）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';

Widget _host(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('进页面默认选中（红 → 黄 → 不选）', () {
    testWidgets('第一条红徽章段自动选中', (tester) async {
      String? picked;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => UtenFilterToolbar<String>(
              segments: const [
                UtenFilterSegment(value: 'all', label: '全部'),
                UtenFilterSegment(
                  value: 'todo',
                  label: '待办',
                  count: 3,
                  countForm: UtenSegmentCountForm.actionable,
                ),
                UtenFilterSegment(
                  value: 'doing',
                  label: '进行中',
                  count: 5,
                  countForm: UtenSegmentCountForm.inProgress,
                ),
              ],
              selected: picked == null ? const {} : {picked!},
              onSelectionChanged: (v) => setState(() => picked = v),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(picked, 'todo');
    });

    testWidgets('没有红时选第一条黄徽章段', (tester) async {
      String? picked;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => UtenFilterToolbar<String>(
              segments: const [
                UtenFilterSegment(value: 'all', label: '全部'),
                UtenFilterSegment(
                  value: 'doing',
                  label: '进行中',
                  count: 5,
                  countForm: UtenSegmentCountForm.inProgress,
                ),
              ],
              selected: picked == null ? const {} : {picked!},
              onSelectionChanged: (v) => setState(() => picked = v),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(picked, 'doing');
    });

    testWidgets('红黄都没有（或只有浏览计数）不自动选', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _host(
          UtenFilterToolbar<String>(
            segments: const [
              UtenFilterSegment(value: 'all', label: '全部', count: 7),
              UtenFilterSegment(value: 'done', label: '已完成', count: 2),
            ],
            onSelectionChanged: (_) => calls++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
    });

    testWidgets('计数异步到位时等到位才选；红优先于黄', (tester) async {
      String? picked;
      int? doingCount;
      late StateSetter setStateHost;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              setStateHost = setState;
              return UtenFilterToolbar<String>(
                segments: [
                  const UtenFilterSegment(value: 'todo', label: '待办'),
                  UtenFilterSegment(
                    value: 'doing',
                    label: '进行中',
                    count: doingCount,
                    countForm: UtenSegmentCountForm.inProgress,
                  ),
                ],
                selected: picked == null ? const {} : {picked!},
                onSelectionChanged: (v) => setState(() => picked = v),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 黄数为 null（加载中）不选。
      expect(picked, isNull);

      setStateHost(() => doingCount = 4);
      await tester.pumpAndSettle();
      expect(picked, 'doing');
    });

    testWidgets('选中一旦发生不再自动改选', (tester) async {
      String? picked = 'all';
      int? todoCount;
      late StateSetter setStateHost;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              setStateHost = setState;
              return UtenFilterToolbar<String>(
                segments: [
                  const UtenFilterSegment(value: 'all', label: '全部'),
                  UtenFilterSegment(
                    value: 'todo',
                    label: '待办',
                    count: todoCount,
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                ],
                selected: {picked!},
                onSelectionChanged: (v) => setState(() => picked = v),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 已有选中（手动或更早自动）——后到的红数不再抢选。
      setStateHost(() => todoCount = 9);
      await tester.pumpAndSettle();
      expect(picked, 'all');
    });

    testWidgets('小类行锁定（enabled=false）不自动选，解锁后照常', (tester) async {
      String? picked;
      bool enabled = false;
      late StateSetter setStateHost;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              setStateHost = setState;
              return UtenFilterToolbar<String>(
                enabled: enabled,
                segments: const [
                  UtenFilterSegment(
                    value: 'todo',
                    label: '待办',
                    count: 2,
                    countForm: UtenSegmentCountForm.actionable,
                  ),
                ],
                selected: picked == null ? const {} : {picked!},
                onSelectionChanged: (v) => setState(() => picked = v),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(picked, isNull);

      setStateHost(() => enabled = true);
      await tester.pumpAndSettle();
      expect(picked, 'todo');
    });

    testWidgets('autoSelectBadge=false 时保持默认不选', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _host(
          UtenFilterToolbar<String>(
            autoSelectBadge: false,
            segments: const [
              UtenFilterSegment(
                value: 'todo',
                label: '待办',
                count: 2,
                countForm: UtenSegmentCountForm.actionable,
              ),
            ],
            onSelectionChanged: (_) => calls++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 0);
    });
  });

  group('UtenSegmentRow 每格宽度自适应', () {
    testWidgets('字少的格比字多的格窄，整条按内容收縮', (tester) async {
      await tester.pumpWidget(
        _host(
          UtenSegmentRow<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'a', label: Text('待办')),
              ButtonSegment(
                value: 'b',
                label: UtenSegmentBadgeLabel(
                  label: '委外回厂待检',
                  count: 99,
                  countForm: UtenSegmentCountForm.actionable,
                ),
              ),
            ],
            selected: const {'a'},
            onSelectionChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final row = tester.getRect(find.byType(UtenSegmentRow<String>));
      final shortCell = tester.getRect(find.text('待办'));
      final longCell = tester.getRect(
        find.descendant(
          of: find.byType(UtenSegmentRow<String>),
          matching: find.byWidgetPredicate(
            (w) => w is UtenSegmentBadgeLabel && w.label == '委外回厂待检',
          ),
        ),
      );
      // 短格明显窄于长格（等宽 SegmentedButton 时代两者相同——这正是要修的）。
      expect(shortCell.width, lessThan(longCell.width - 30));
      // 整条不铺满可用宽度：远小于宿主表面（Center 里的 2400 宽测试画布）。
      expect(row.width, lessThan(400));
      // 格子首尾相接、无重叠。
      expect(shortCell.right, lessThanOrEqualTo(longCell.left + 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('工具条分类栏同样按内容收縮，不占满整行', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          Align(
            alignment: Alignment.centerLeft,
            child: UtenFilterToolbar<String>(
              segments: const [
                UtenFilterSegment(value: 'a', label: '全部'),
                UtenFilterSegment(value: 'b', label: '采购收货'),
                UtenFilterSegment(value: 'c', label: '自制产成品'),
              ],
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = tester.getRect(find.byType(UtenSegmentRow<String>));
      // 三段都是短文案：整条宽度远小于可用宽度（旧等宽实现会均分铺满）。
      expect(row.width, lessThan(500));
      expect(tester.takeException(), isNull);
    });
  });
}
