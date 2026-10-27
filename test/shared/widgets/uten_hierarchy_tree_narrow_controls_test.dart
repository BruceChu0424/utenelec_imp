import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_tree_branch_guide.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/widgets/uten_department_tree_view.dart';

Widget _app(Widget tree, {required double width, required bool dark}) =>
    MaterialApp(
      theme: (dark ? buildDarkTheme() : buildLightTheme()).copyWith(
        platform: TargetPlatform.windows,
        visualDensity: VisualDensity.compact,
      ),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)),
        child: Scaffold(
          body: SizedBox(width: width, height: 560, child: tree),
        ),
      ),
    );

PaymentStyleNode _category(int depth) => PaymentStyleNode(
  id: 'category-$depth',
  code: 'category-$depth',
  name: '分类$depth',
  children: depth == 5 ? const [] : [_category(depth + 1)],
);

DepartmentNode _department(int depth) => DepartmentNode(
  id: 'department-$depth',
  code: 'department-$depth',
  name: '部门$depth',
  level: '一级部门',
  children: depth == 5 ? const [] : [_department(depth + 1)],
);

void main() {
  for (final dark in [false, true]) {
    for (final width in [160.0, 200.0]) {
      testWidgets('category single stays compact at $width dark=$dark', (
        tester,
      ) async {
        await tester.pumpWidget(
          _app(
            UtenCategoryTreeView<PaymentStyleNode>(
              nodes: [_category(0)],
              mode: UtenCategoryTreeMode.single,
              selectedIds: const {'category-5'},
              showSearch: false,
              initiallyExpandDepth: 999,
              flatLevelColors: true,
              onToggleSelect: (_) {},
            ),
            width: width,
            dark: dark,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getTopLeft(find.text('分类1')).dx,
          greaterThan(tester.getTopLeft(find.text('分类0')).dx),
        );
        expect(
          tester.getRect(find.byIcon(Icons.check_circle_rounded)).right,
          lessThanOrEqualTo(width),
        );
        for (var depth = 0; depth <= 5; depth++) {
          final row = find
              .ancestor(
                of: find.text('分类$depth'),
                matching: find.byType(InkWell),
              )
              .first;
          expect(tester.getSize(row).height, 36);
        }
        await tester.tap(find.byTooltip('收起分类0'));
        await tester.pumpAndSettle();
        expect(find.text('分类1'), findsNothing);
      });

      testWidgets(
        'department badge, count and multi controls fit $width dark=$dark',
        (tester) async {
          final root = _department(0);
          Widget tree({required bool expanded}) => UtenDepartmentTreeView(
            nodes: [root],
            mode: UtenDepartmentTreeMode.multi,
            selectedIds: const {'department-5'},
            showSearch: false,
            initiallyExpandDepth: expanded ? 999 : 0,
            // Existing 160px department pickers use the compact presentation,
            // which omits level badges. Management rows retain them at 200px.
            flatLevelColors: width == 160,
            trailingBuilder: (_) => const Text('2人'),
            onToggleSelect: (_) {},
          );
          // The original zero-indentation footprint must already fit before a
          // narrow-tree regression is attributed to the new guide gutter.
          await tester.pumpWidget(
            _app(tree(expanded: false), width: width, dark: dark),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final baselineHeight = tester
              .getSize(find.byKey(const ValueKey('hierarchy-row:department-0')))
              .height;
          await tester.pumpWidget(
            _app(tree(expanded: true), width: width, dark: dark),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('部门5'), findsOneWidget);
          final guides = tester.widgetList<UtenTreeBranchGuide>(
            find.byType(UtenTreeBranchGuide),
          );
          expect(guides.map((guide) => guide.indent).toSet(), hasLength(1));
          expect(
            guides.map((guide) => guide.maxVisualDepth).toSet(),
            hasLength(1),
          );
          for (var depth = 0; depth <= 5; depth++) {
            final row = find.byKey(ValueKey('hierarchy-row:department-$depth'));
            final checkbox = find.descendant(
              of: row,
              matching: find.byType(Checkbox),
            );
            final label = find.text('部门$depth');
            expect(tester.getRect(checkbox).right, lessThanOrEqualTo(width));
            expect(tester.getCenter(checkbox).dy, tester.getCenter(label).dy);
            expect(tester.getSize(row).height, baselineHeight);
          }
          if (width == 200) {
            expect(
              tester.getTopLeft(find.text('部门1')).dx,
              greaterThan(tester.getTopLeft(find.text('部门0')).dx),
            );
          }
        },
      );
    }
  }
}
