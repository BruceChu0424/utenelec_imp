import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/widgets/permission_catalog_browser.dart';

void main() {
  final groups = [
    const PermissionCatalogGroup(
      category: '销售管理',
      permissions: [
        AdminPermission(
          id: 'sales-view',
          code: 'sales:view',
          name: '查看销售单据',
          category: '销售管理',
        ),
        AdminPermission(
          id: 'sales-edit',
          code: 'sales:edit',
          name: '编辑销售单据',
          category: '销售管理',
        ),
      ],
    ),
    const PermissionCatalogGroup(
      category: '财务管理',
      permissions: [
        AdminPermission(
          id: 'report-export',
          code: 'report:export',
          name: '导出报表',
          category: '财务管理',
        ),
      ],
    ),
  ];

  Widget buildSubject({ValueChanged<List<AdminPermission>>? onEnableGroup}) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: PermissionCatalogBrowser(
              groups: groups,
              isEnabled: (permission) => permission.code == 'sales:view',
              onEnableGroup: onEnableGroup,
              onDisableGroup: (_) {},
              itemBuilder: (context, permission) => Text(permission.name),
            ),
          ),
        ),
      ),
    );
  }

  Finder searchField() => find.descendant(
    of: find.byKey(const ValueKey('permission-catalog-search')),
    matching: find.byType(TextField),
  );

  testWidgets('starts collapsed and expands a selected group', (tester) async {
    await tester.pumpWidget(buildSubject());

    expect(find.text('销售管理'), findsOneWidget);
    expect(find.text('查看销售单据'), findsNothing);

    await tester.tap(find.text('销售管理'));
    await tester.pumpAndSettle();

    expect(find.text('查看销售单据'), findsOneWidget);
    expect(find.text('编辑销售单据'), findsOneWidget);
  });

  testWidgets('searches by code and category, then clears no-result state', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());

    await tester.enterText(searchField(), 'report:export');
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('导出报表'), findsOneWidget);
    expect(find.text('查看销售单据'), findsNothing);

    await tester.enterText(searchField(), '销售管理');
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('查看销售单据'), findsOneWidget);
    expect(find.text('编辑销售单据'), findsOneWidget);

    await tester.enterText(searchField(), '不存在的权限');
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('没有匹配的权限'), findsOneWidget);
    await tester.tap(find.text('查看全部权限'));
    await tester.pumpAndSettle();

    expect(find.text('销售管理'), findsOneWidget);
    expect(find.text('财务管理'), findsOneWidget);
  });

  testWidgets('filters by enabled state without losing the complete catalog', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());

    await tester.tap(find.byKey(const ValueKey('permission-filter-enabled')));
    await tester.pumpAndSettle();

    expect(find.text('查看销售单据'), findsOneWidget);
    expect(find.text('编辑销售单据'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('permission-filter-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('销售管理'));
    await tester.pumpAndSettle();

    expect(find.text('编辑销售单据'), findsOneWidget);
  });

  testWidgets('group batch action always receives the complete group', (
    tester,
  ) async {
    List<AdminPermission>? selected;
    await tester.pumpWidget(
      buildSubject(onEnableGroup: (permissions) => selected = permissions),
    );

    await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本组全部授权'));
    await tester.pumpAndSettle();

    expect(selected?.map((permission) => permission.code).toSet(), {
      'sales:view',
      'sales:edit',
    });
  });

  testWidgets('does not overflow at compact, medium, and expanded widths', (
    tester,
  ) async {
    for (final width in [375.0, 768.0, 1200.0]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      await tester.pumpWidget(buildSubject());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'width=$width');
    }
    await tester.binding.setSurfaceSize(null);
  });
}
