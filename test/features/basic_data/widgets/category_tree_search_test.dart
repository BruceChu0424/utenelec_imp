import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/category_tree_search.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

ProductCategoryNode _node(
  String id,
  String code,
  String name, [
  List<ProductCategoryNode> children = const [],
]) => ProductCategoryNode(
  id: id,
  code: code,
  name: name,
  level: 0,
  children: children,
);

void main() {
  final tree = [
    _node('root', 'FG', '成品', [
      _node('series', 'LED-A', '照明系列', [_node('leaf', 'A-01', '筒灯')]),
    ]),
    _node('other', 'RAW', '原材料'),
  ];

  test('分类搜索同时匹配名称和编号且忽略大小写', () {
    expect(categoryHits(tree, '  led-a '), {'root', 'series', 'leaf'});
    expect(categoryHits(tree, '筒灯'), {'root', 'series', 'leaf'});
    expect(shallowestHit(tree, 'fg', categoryHits(tree, 'fg')), 'root');
  });

  test('具体内容命中时补齐祖先并优先选中内容所属分类', () {
    final result = resolveHierarchySearch(
      roots: tree,
      query: 'UT-1001',
      contentCategoryIds: const ['leaf'],
    );

    expect(result.visibleIds, {'root', 'series', 'leaf'});
    expect(result.contentCategoryIds, {'leaf'});
    expect(result.selectedId, 'leaf');
    expect(result.hasContentMatches, isTrue);
  });

  test('树外或空分类 id 不会造成无效选中并会被计数', () {
    final result = resolveHierarchySearch(
      roots: tree,
      query: '筒灯',
      contentCategoryIds: const ['missing', null, ''],
    );

    expect(result.selectedId, 'leaf');
    expect(result.contentCategoryIds, isEmpty);
    expect(result.ignoredContentCategoryCount, 3);
  });

  test('搜索态可判断命中内容是否位于所点分类子树', () {
    expect(hierarchyBranchContainsAny(tree, 'root', {'leaf'}), isTrue);
    expect(hierarchyBranchContainsAny(tree, 'series', {'leaf'}), isTrue);
    expect(hierarchyBranchContainsAny(tree, 'other', {'leaf'}), isFalse);
    expect(hierarchyBranchContainsAny(tree, 'missing', {'leaf'}), isFalse);
  });

  test('分页分类定位会收集全部页并去重空分类 id', () async {
    final requestedPages = <int>[];

    final result = await collectPagedHierarchyCategoryIds<String>(
      loadPage: (page) async {
        requestedPages.add(page);
        return PagedResult(
          items: switch (page) {
            1 => const ['leaf', ''],
            2 => const ['other', 'leaf'],
            _ => const ['series'],
          },
          page: page,
          size: 2,
          total: 5,
          totalPages: 3,
        );
      },
      categoryIdOf: (id) => id,
      isCurrent: () => true,
    );

    expect(requestedPages, [1, 2, 3]);
    expect(result, {'leaf', 'other', 'series'});
  });

  test('分页分类定位可复用当前页且不重复请求', () async {
    final requestedPages = <int>[];
    const seed = PagedResult<String>(
      items: ['page-2'],
      page: 2,
      size: 1,
      total: 3,
      totalPages: 3,
    );

    final result = await collectPagedHierarchyCategoryIds<String>(
      seedPage: seed,
      loadPage: (page) async {
        requestedPages.add(page);
        return PagedResult(
          items: ['page-$page'],
          page: page,
          size: 1,
          total: 3,
          totalPages: 3,
        );
      },
      categoryIdOf: (id) => id,
      isCurrent: () => true,
    );

    expect(requestedPages, [1, 3]);
    expect(result, {'page-2', 'page-1', 'page-3'});
  });

  test('request generation 失效后停止后续分页且不返回半成品', () async {
    final requestedPages = <int>[];
    var current = true;

    final result = await collectPagedHierarchyCategoryIds<String>(
      loadPage: (page) async {
        requestedPages.add(page);
        current = false;
        return PagedResult(
          items: const ['leaf'],
          page: page,
          size: 1,
          total: 2,
          totalPages: 2,
        );
      },
      categoryIdOf: (id) => id,
      isCurrent: () => current,
    );

    expect(requestedPages, [1]);
    expect(result, isNull);
  });
}
