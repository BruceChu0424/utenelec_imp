import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/uten_tree_node.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_tree_view.dart';

class _Node implements UtenTreeNode<_Node> {
  _Node(this.value, this.rank, [this.children = const []]);
  final String value;
  final String rank;
  static int modelReads = 0;
  @override
  String get id {
    modelReads++;
    return value;
  }

  @override
  String get name => value;
  @override
  String get code {
    modelReads++;
    return rank;
  }

  @override
  final List<_Node> children;
  @override
  bool get hasChildren => children.isNotEmpty;
}

void main() {
  testWidgets(
    'selection reuses ordered rows while filters and replacement forests invalidate them',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var nodes = [
        _Node('root', 'root', [
          for (var i = 1999; i >= 0; i--)
            _Node('node-$i', '$i'.padLeft(4, '0')),
        ]),
      ];
      Widget app({Set<String> selected = const {}, Set<String>? visible}) =>
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 320,
                child: UtenHierarchyTreeView<_Node>(
                  initiallyExpandDepth: 1,
                  nodes: nodes,
                  mode: UtenTreeSelectMode.single,
                  selectedIds: selected,
                  visibleFilterIds: visible,
                  sortByCode: true,
                  searchHint: '搜索',
                  emptyNoun: '分类',
                  showSearch: false,
                ),
              ),
            ),
          );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('node-0'), findsOneWidget);
      expect(find.text('node-1999'), findsNothing);
      _Node.modelReads = 0;
      await tester.pumpWidget(app(selected: {'node-0'}));
      await tester.pumpAndSettle();
      debugPrint(
        'hierarchy-selection nodes=2001 modelReads=${_Node.modelReads}',
      );
      expect(
        _Node.modelReads,
        lessThan(1000),
        reason:
            'changing selection must not sort or index the entire 2000-node branch again',
      );
      final visible = {'root', 'node-1999'};
      await tester.pumpWidget(app(visible: visible));
      await tester.pumpAndSettle();
      expect(find.text('node-1999'), findsOneWidget);
      expect(find.text('node-0'), findsNothing);
      visible
        ..remove('node-1999')
        ..add('node-0');
      await tester.pumpWidget(app(visible: visible));
      await tester.pumpAndSettle();
      expect(find.text('node-0'), findsOneWidget);
      expect(find.text('node-1999'), findsNothing);
      nodes = [
        _Node('root', 'root', [
          _Node('new-first', '0'),
          _Node('new-second', '1'),
        ]),
      ];
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('new-first'), findsOneWidget);
      expect(find.text('node-0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a stable pass-through callback rechecks changed host state', (
    tester,
  ) async {
    final nodes = [
      _Node('wrapper', '0', [_Node('leaf', '1')]),
    ];
    var hideRoot = false;
    bool pass(_Node node) => hideRoot && node.id == 'wrapper';
    Widget app() => MaterialApp(
      home: Scaffold(
        body: UtenHierarchyTreeView<_Node>(
          nodes: nodes,
          passThrough: pass,
          searchHint: '搜索',
          emptyNoun: '分类',
          showSearch: false,
        ),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('wrapper'), findsOneWidget);
    hideRoot = true;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('wrapper'), findsNothing);
    expect(find.text('leaf'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
