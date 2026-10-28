import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_adaptive_hierarchy_pane.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/models/uten_tree_node.dart';
import 'package:uten_imp/shared/widgets/uten_hierarchy_tree_view.dart';

const _treeKey = Key('short-hierarchy');
const _externalSearch = Key('external-search');
const _relatedKey = Key('related-search');
const _directoryKey = Key('open-directory');
const _resultKey = Key('result-list');

void main() {
  for (final longError in [false, true]) {
    testWidgets(
      '179px tree scrolls all controls and selectable nodes; error=$longError',
      (tester) async {
        await _prepare(tester);
        final controller = TextEditingController(text: '原查询');
        final parentScroll = ScrollController();
        addTearDown(controller.dispose);
        addTearDown(parentScroll.dispose);
        var related = false;
        String? selected;
        await tester.pumpWidget(
          _app(
            PrimaryScrollController(
              controller: parentScroll,
              child: StatefulBuilder(
                builder: (context, update) => _tree(
                  header: _queryHeader(
                    controller,
                    related: related,
                    onRelated: (value) => update(() => related = value),
                  ),
                  showSearch: true,
                  loading: true,
                  error: longError ? _longError : null,
                  onSelect: (node) => update(() => selected = node.id),
                  selected: selected,
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(_relatedKey));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(_relatedKey).hitTestable(), findsOneWidget);
        await tester.tap(find.byKey(_relatedKey));
        await tester.pump(const Duration(milliseconds: 400));
        expect(related, isTrue);
        final scrollable = _verticalWithin(find.byKey(_treeKey));
        if (longError) {
          await tester.ensureVisible(find.text(_longError));
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text(_longError), findsOneWidget);
        }
        await tester.scrollUntilVisible(
          find.text('节点0'),
          100,
          scrollable: scrollable,
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('节点0').hitTestable(), findsOneWidget);
        await tester.tap(find.text('节点0'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(selected, 'node-0');
        expect(controller.text, '原查询');
        expect(parentScroll.hasClients, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'normal height pins the header and short-height transitions retain focus and expansion',
    (tester) async {
      await _prepare(tester);
      final semantics = tester.ensureSemantics();
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final nodes = [
        const _Node('parent', '父类', children: [_Node('child', '已展开子类')]),
        for (var index = 0; index < 30; index++)
          _Node('node-$index', '节点$index'),
      ];
      Widget view(double height) => _app(
        _tree(
          header: UtenSearchBar(key: _externalSearch, controller: controller),
          nodes: nodes,
          onSelect: (_) {},
        ),
        height: height,
      );
      await tester.pumpWidget(view(700));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('展开父类'));
      await tester.pumpAndSettle();
      expect(find.text('已展开子类'), findsOneWidget);
      final headerTop = tester.getTopLeft(find.byKey(_externalSearch));
      final firstRowTop = tester.getTopLeft(find.text('节点0'));
      await tester.drag(
        _verticalWithin(find.byKey(_treeKey)),
        const Offset(0, -80),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(_externalSearch)), headerTop);
      expect(tester.getTopLeft(find.text('节点0')).dy, lessThan(firstRowTop.dy));
      await tester.drag(
        _verticalWithin(find.byKey(_treeKey)),
        const Offset(0, 80),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_externalSearch));
      await tester.enterText(find.byKey(_externalSearch), 'M3');
      controller.value = controller.value.copyWith(
        composing: const TextRange(start: 0, end: 2),
      );
      await tester.pump();
      final editable = find.descendant(
        of: find.byKey(_externalSearch),
        matching: find.byType(EditableText),
      );
      final inputElement = tester.element(editable);
      final inputFocus = tester.widget<EditableText>(editable).focusNode;
      expect(inputFocus.hasFocus, isTrue);
      final treeState = tester.state(find.byKey(_treeKey));
      for (final height in [179.0, 700.0]) {
        await tester.pumpWidget(view(height));
        await tester.pumpAndSettle();
        expect(tester.state(find.byKey(_treeKey)), same(treeState));
        expect(tester.element(editable), same(inputElement));
        expect(inputFocus.hasFocus, isTrue);
        expect(controller.text, 'M3');
        expect(controller.value.composing, const TextRange(start: 0, end: 2));
        expect(find.byTooltip('收起父类'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      semantics.dispose();
    },
  );

  testWidgets(
    'short compact pane keeps header, directory and results reachable while offstage trees remain safe',
    (tester) async {
      await _prepare(tester);
      final controller = TextEditingController(text: '原查询');
      addTearDown(controller.dispose);
      var related = false;
      String? selected;
      var resultSelections = 0;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, update) => UtenAdaptiveHierarchyPane(
              canSplit: false,
              selectedLabel: '原材料 / 五金 / 连接件',
              selectionKey: selected,
              openButtonKey: _directoryKey,
              compactHeader: _queryHeader(
                controller,
                related: related,
                onRelated: (value) => update(() => related = value),
              ),
              leading: _tree(
                header: _queryHeader(controller, related: related),
                showSearch: true,
                error: _longError,
                onSelect: (node) => update(() => selected = node.id),
                selected: selected,
              ),
              trailing: ListView(
                key: _resultKey,
                primary: true,
                children: [
                  ListTile(
                    title: const Text('可选结果'),
                    onTap: () => update(() => resultSelections++),
                  ),
                ],
              ),
              splitBuilder: (leading, trailing) => Row(
                children: [
                  Expanded(child: leading),
                  Expanded(child: trailing),
                ],
              ),
            ),
          ),
          width: 320,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'closed directory still lays out its maintained tree',
      );
      final resultElement = tester.element(
        find.byKey(_resultKey, skipOffstage: false),
      );
      await tester.ensureVisible(find.byKey(_relatedKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_relatedKey));
      await tester.pumpAndSettle();
      expect(related, isTrue);
      await tester.ensureVisible(find.byKey(_directoryKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_directoryKey));
      await tester.pumpAndSettle();
      expect(find.text('分类目录'), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'open directory still lays out maintained results',
      );
      await tester.scrollUntilVisible(
        find.text('节点0'),
        100,
        scrollable: _verticalWithin(find.byKey(_treeKey)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('节点0'));
      await tester.pumpAndSettle();
      expect(selected, 'node-0');
      expect(find.text('分类目录'), findsNothing);
      expect(tester.element(find.byKey(_resultKey)), same(resultElement));
      await tester.ensureVisible(find.text('可选结果'));
      await tester.pumpAndSettle();
      expect(find.text('可选结果').hitTestable(), findsOneWidget);
      await tester.tap(find.text('可选结果'));
      expect(resultSelections, 1);
      expect(controller.text, '原查询');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact height transitions retain header IME focus and the mounted result list',
    (tester) async {
      await _prepare(tester);
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      Widget view(double height) => _app(
        UtenAdaptiveHierarchyPane(
          canSplit: false,
          compactHeader: _queryHeader(controller, related: false),
          leading: _tree(onSelect: (_) {}),
          trailing: ListView(
            key: _resultKey,
            primary: true,
            children: const [ListTile(title: Text('保持挂载的结果'))],
          ),
          splitBuilder: (leading, trailing) => Row(
            children: [
              Expanded(child: leading),
              Expanded(child: trailing),
            ],
          ),
        ),
        width: 320,
        height: height,
      );
      await tester.pumpWidget(view(700));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_externalSearch));
      await tester.enterText(find.byKey(_externalSearch), 'M3');
      controller.value = controller.value.copyWith(
        composing: const TextRange(start: 0, end: 2),
      );
      await tester.pump();
      final editable = find.descendant(
        of: find.byKey(_externalSearch),
        matching: find.byType(EditableText),
      );
      final inputElement = tester.element(editable);
      final focus = tester.widget<EditableText>(editable).focusNode;
      final resultElement = tester.element(find.byKey(_resultKey));
      for (final height in [179.0, 700.0]) {
        await tester.pumpWidget(view(height));
        await tester.pumpAndSettle();
        expect(tester.element(editable), same(inputElement));
        expect(focus.hasFocus, isTrue);
        expect(controller.value.composing, const TextRange(start: 0, end: 2));
        expect(
          tester.element(find.byKey(_resultKey, skipOffstage: false)),
          same(resultElement),
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
}

const _longError = '分类定位失败，请检查网络后重试。当前搜索范围与已选内容保持不变，不能把其他业务范围的数据混入。';

Future<void> _prepare(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1100, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Widget _app(Widget child, {double width = 200, double height = 179}) =>
    MaterialApp(
      theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, height: height, child: child),
          ),
        ),
      ),
    );

Widget _queryHeader(
  TextEditingController controller, {
  required bool related,
  ValueChanged<bool>? onRelated,
}) => Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    UtenSearchBar(key: _externalSearch, controller: controller),
    const SizedBox(height: 8),
    const Text('搜索范围：全部授权分类和历史记录'),
    CheckboxListTile(
      key: _relatedKey,
      value: related,
      onChanged: (value) => onRelated?.call(value!),
      title: const Text('显示相关结果（含备注/要求）'),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
    ),
  ],
);

Widget _tree({
  Widget? header,
  List<_Node>? nodes,
  bool showSearch = false,
  bool loading = false,
  String? error,
  String? selected,
  ValueChanged<_Node>? onSelect,
}) => UtenHierarchyTreeView<_Node>(
  key: _treeKey,
  nodes:
      nodes ??
      [
        for (var index = 0; index < 20; index++)
          _Node('node-$index', '节点$index'),
      ],
  mode: UtenTreeSelectMode.single,
  selectedIds: {?selected},
  searchHint: '搜索分类',
  emptyNoun: '分类',
  header: header,
  showSearch: showSearch,
  externalSearchLoading: loading,
  externalSearchError: error,
  onToggleSelect: onSelect,
);

Finder _verticalWithin(Finder parent) => find
    .descendant(
      of: parent,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    )
    .first;

class _Node implements UtenTreeNode<_Node> {
  const _Node(this.id, this.name, {this.children = const []});
  @override
  final String id;
  @override
  final String name;
  @override
  String get code => id;
  @override
  final List<_Node> children;
  @override
  bool get hasChildren => children.isNotEmpty;
}
