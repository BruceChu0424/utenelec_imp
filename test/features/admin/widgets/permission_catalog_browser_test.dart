import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/widgets/permission_catalog_browser.dart';

void main() {
  // 两级目录：模块（销售管理 / 财税管理）→ 子类（销售订货 / 钱流报表）→ 权限项。
  final groups = [
    const PermissionCatalogGroup(
      module: '销售管理',
      category: '销售订货',
      permissions: [
        AdminPermission(
          id: 'sales-view',
          code: 'sales:view',
          name: '查看销售单据',
          category: '销售订货',
          module: '销售管理',
        ),
        AdminPermission(
          id: 'sales-edit',
          code: 'sales:edit',
          name: '编辑销售单据',
          category: '销售订货',
          module: '销售管理',
        ),
      ],
    ),
    const PermissionCatalogGroup(
      module: '财税管理',
      category: '钱流报表',
      permissions: [
        AdminPermission(
          id: 'report-export',
          code: 'report:export',
          name: '导出报表',
          category: '钱流报表',
          module: '财税管理',
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

  testWidgets('starts collapsed; expand module then subcategory to reveal items', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());

    // 仅模块标题可见；子类与权限均折叠。
    expect(find.text('销售管理'), findsOneWidget);
    expect(find.text('销售订货'), findsNothing);
    expect(find.text('查看销售单据'), findsNothing);

    // 展开模块 → 子类标题出现（子类仍折叠）。
    await tester.tap(find.text('销售管理'));
    await tester.pumpAndSettle();
    expect(find.text('销售订货'), findsOneWidget);
    expect(find.text('查看销售单据'), findsNothing);

    // 展开子类 → 权限项出现。
    await tester.tap(find.text('销售订货'));
    await tester.pumpAndSettle();
    expect(find.text('查看销售单据'), findsOneWidget);
    expect(find.text('编辑销售单据'), findsOneWidget);
  });

  testWidgets('search auto-expands matching module and subcategory', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());

    // 按代码搜 → 命中项所在模块+子类自动展开。
    await tester.enterText(searchField(), 'report:export');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('导出报表'), findsOneWidget);
    expect(find.text('查看销售单据'), findsNothing);

    // 按模块名搜 → 整个模块展开。
    await tester.enterText(searchField(), '销售管理');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('查看销售单据'), findsOneWidget);
    expect(find.text('编辑销售单据'), findsOneWidget);

    // 无结果 → 空态，可一键恢复全部。
    await tester.enterText(searchField(), '不存在的权限');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('没有匹配的权限'), findsOneWidget);
    await tester.tap(find.text('查看全部权限'));
    await tester.pumpAndSettle();
    expect(find.text('销售管理'), findsOneWidget);
    expect(find.text('财税管理'), findsOneWidget);
  });

  testWidgets('filters by enabled state without losing the complete catalog', (
    tester,
  ) async {
    await tester.pumpWidget(buildSubject());

    await tester.tap(find.byKey(const ValueKey('permission-filter-enabled')));
    await tester.pumpAndSettle();

    // 仅 sales:view 启用 → 自动展开其模块与子类。
    expect(find.text('查看销售单据'), findsOneWidget);
    expect(find.text('编辑销售单据'), findsNothing);

    // 切回全部 → 视图回到折叠，需逐级展开。
    await tester.tap(find.byKey(const ValueKey('permission-filter-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('销售管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('销售订货'));
    await tester.pumpAndSettle();

    expect(find.text('编辑销售单据'), findsOneWidget);
  });

  testWidgets('module batch action receives all permissions in the module', (
    tester,
  ) async {
    List<AdminPermission>? selected;
    await tester.pumpWidget(
      buildSubject(onEnableGroup: (permissions) => selected = permissions),
    );

    // 模块级批量菜单始终可见（无需展开模块）。
    await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本模块全部授权'));
    await tester.pumpAndSettle();

    expect(selected?.map((permission) => permission.code).toSet(), {
      'sales:view',
      'sales:edit',
    });
  });

  testWidgets(
    'subcategory batch action receives the complete subcategory '
    'even while filtered',
    (tester) async {
      List<AdminPermission>? selected;
      await tester.pumpWidget(
        buildSubject(onEnableGroup: (permissions) => selected = permissions),
      );

      // 仅看「已授权」后，子类仍可能被部分隐藏；整组批量必须作用于完整子类。
      await tester.tap(find.byKey(const ValueKey('permission-filter-enabled')));
      await tester.pumpAndSettle();

      final subcategoryCard = find.byKey(
        const ValueKey('permission-category-销售订货'),
      );
      await tester.tap(
        find.descendant(
          of: subcategoryCard,
          matching: find.byIcon(Icons.more_horiz_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('本组全部授权'));
      await tester.pumpAndSettle();

      // 即便筛选只显示 sales:view，整组批量仍包含 sales:view + sales:edit。
      expect(selected?.map((permission) => permission.code).toSet(), {
        'sales:view',
        'sales:edit',
      });
    },
  );

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
