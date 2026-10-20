import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/hierarchy/category_tree_search.dart';
import 'package:uten_imp/shared/models/uten_tree_node.dart';

void main() {
  test(
    'broad content search indexes ancestors once for all 2000 matching categories',
    () {
      var reads = 0;
      void read() => reads++;
      final children = [for (var i = 0; i < 2000; i++) _Node('child-$i', read)];
      final result = resolveHierarchySearch(
        roots: [_Node('root', read, children)],
        query: '具体货品',
        contentCategoryIds: [for (var i = 0; i < 2000; i++) 'child-$i'],
      );
      expect(result.visibleIds, hasLength(2001));
      expect(result.selectedId, 'child-0');
      expect(
        reads,
        lessThan(40000),
        reason:
            'matching 2000 categories must not rescan the forest 2000 times',
      );
    },
  );
}

class _Node implements UtenTreeNode<_Node> {
  _Node(this.value, this.read, [this.children = const []]);
  final String value;
  final void Function() read;
  @override
  String get id {
    read();
    return value;
  }

  @override
  String get name => value;
  @override
  String get code => value;
  @override
  final List<_Node> children;
  @override
  bool get hasChildren => children.isNotEmpty;
}
