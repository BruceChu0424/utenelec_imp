import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/system_master_category_guard.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_node_actions.dart';

void main() {
  group('system uncategorized category guard', () {
    test('uses only the server-derived UUID authority flag', () {
      expect(isSystemUncategorizedCategory(systemManaged: true), isTrue);
      expect(isSystemUncategorizedCategory(systemManaged: false), isFalse);
    });

    test('blocks mutation without taking away normal edit permission', () {
      expect(
        canMutateMasterCategory(hasEditPermission: true, systemManaged: true),
        isFalse,
      );
      expect(
        canMutateMasterCategory(hasEditPermission: true, systemManaged: false),
        isTrue,
      );
      expect(
        canMutateMasterCategory(hasEditPermission: false, systemManaged: false),
        isFalse,
      );
    });
  });

  testWidgets('protection notice explains the missing edit/delete actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SystemMasterCategoryProtectionNotice()),
      ),
    );

    expect(
      find.text(systemUncategorizedCategoryProtectionMessage),
      findsOneWidget,
    );
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, systemUncategorizedCategoryProtectionMessage);
  });

  testWidgets('inline and menu actions share callbacks and enabled state', (
    tester,
  ) async {
    var additions = 0;
    var deletions = 0;
    var keeperChanges = 0;
    final operations = UtenHierarchyNodeOperations(
      add: UtenHierarchyNodeOperation(
        label: '新增子项',
        tooltip: '新增指定节点的子项',
        icon: Icons.add_outlined,
        buttonKey: const Key('shared-node-add'),
        onInvoke: () => additions++,
      ),
      edit: UtenHierarchyNodeOperation(
        label: '编辑',
        icon: Icons.edit_outlined,
        buttonKey: const Key('shared-node-edit'),
        enabled: false,
        onInvoke: () {},
      ),
      delete: UtenHierarchyNodeOperation(
        label: '删除',
        icon: Icons.delete_outline,
        destructive: true,
        buttonKey: const Key('shared-node-delete'),
        onInvoke: () => deletions++,
      ),
      extra: [
        UtenHierarchyNodeOperation(
          label: '设置负责人',
          icon: Icons.manage_accounts_outlined,
          showInline: false,
          onInvoke: () => keeperChanges++,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UtenHierarchyNodeActions(operations: operations)),
      ),
    );
    await tester.tap(find.byKey(const Key('shared-node-add')));
    final entries = operations.menuEntries.whereType<UtenMenuItem>().toList();
    expect(entries.map((entry) => entry.label), ['新增子项', '编辑', '设置负责人', '删除']);
    expect(entries[1].enabled, isFalse);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('shared-node-edit')))
          .onPressed,
      isNull,
    );
    expect(find.byTooltip('设置负责人'), findsNothing);
    await entries.first.onTap();
    await entries[2].onTap();
    await tester.tap(find.byKey(const Key('shared-node-delete')));
    await entries.last.onTap();
    expect(entries.last.destructive, isTrue);
    expect(additions, 2);
    expect(deletions, 2);
    expect(keeperChanges, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a protected replacement blocks deletion through both entry points',
    (tester) async {
      var deleted = false;
      final operations = UtenHierarchyNodeOperations(
        delete: UtenHierarchyNodeOperation(
          label: '删除',
          icon: Icons.delete_outline,
          onInvoke: () => deleted = true,
        ),
        deleteReplacement: const SystemMasterCategoryProtectionNotice(
          compact: true,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenHierarchyNodeActions(operations: operations),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('system-master-category-lock-icon')),
        findsOneWidget,
      );
      expect(find.byType(IconButton), findsNothing);
      expect(operations.menuEntries, isEmpty);
      expect(deleted, isFalse);
      expect(const UtenHierarchyNodeOperations().menuEntries, isEmpty);
    },
  );
}
