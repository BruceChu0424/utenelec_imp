import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';

import 'support/audit_screenshot_support.dart';

const _longCategory = '货品资料中足以超过默认宽度的最长未分类名称（LEGACY_ORPHAN）';
const _categoryPaneKey = Key('category-pane');
const _categoryDeleteKey = Key('category-delete');

Widget _categoryHost({String? persistenceKey, VoidCallback? onDelete}) =>
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.windows),
      home: Scaffold(
        body: UtenSplitView(
          persistenceKey: persistenceKey,
          leading: SizedBox(
            key: _categoryPaneKey,
            child: UtenCategoryTreeView<PaymentStyleNode>(
              nodes: [
                PaymentStyleNode(
                  id: 'long-category',
                  code: 'LONG',
                  name: _longCategory,
                  children: const [],
                ),
              ],
              flatLevelColors: true,
              showSearch: false,
              trailingBuilder: (_) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('15'),
                  const SizedBox(width: 8),
                  IconButton(
                    key: _categoryDeleteKey,
                    tooltip: '删除分类',
                    constraints: const BoxConstraints.tightFor(
                      width: 32,
                      height: 32,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: onDelete ?? () {},
                    icon: const Icon(Icons.delete_outline, size: 16),
                  ),
                ],
              ),
            ),
          ),
          trailing: const Text('分类详情'),
        ),
      ),
    );

double _categoryWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(_categoryPaneKey)).width;

Finder _categoryGutter() => find.byTooltip('拖动调整宽度 · 双击复位');

Widget _host({String? persistenceKey}) {
  return MaterialApp(
    home: Scaffold(
      body: UtenSplitView(
        persistenceKey: persistenceKey,
        leading: Container(color: Colors.red),
        trailing: Container(color: Colors.blue),
      ),
    ),
  );
}

/// 左栏当前宽度（UtenSplitView 内第一个定宽 SizedBox）。
double _leadingWidth(WidgetTester tester) {
  final box = tester.widget<SizedBox>(
    find
        .descendant(
          of: find.byType(UtenSplitView),
          matching: find.byWidgetPredicate(
            (w) => w is SizedBox && w.width != null && w.width! > 12,
          ),
        )
        .first,
  );
  return box.width!;
}

Finder _gutter() => find.byType(Tooltip);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('初始宽度 = initialLeadingWidth(默认 300)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_host());
    expect(_leadingWidth(tester), 300);
  });

  testWidgets('向右拖动分割线 → 左栏变宽；向左拖到底 → 钳在 minLeadingWidth', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_host());

    // 拖动手势会先吃掉 touch slop（测试环境约 20px），故只断言「变宽」，
    // 精确像素由下面的钳位用例保证。
    await tester.drag(_gutter(), const Offset(100, 0));
    await tester.pump();
    expect(_leadingWidth(tester), greaterThan(300));

    await tester.drag(_gutter(), const Offset(-1000, 0));
    await tester.pump();
    expect(_leadingWidth(tester), 220); // 钳在下限
    await tester.pumpAndSettle(); // 冲刷 Tooltip 悬停定时器
  });

  testWidgets('向右拖到底 → 钳在 min(maxLeadingWidth, 总宽-手柄-右栏保底)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_host());

    // 测试视口 800 宽：上限取 min(520, 800-12-360=428) = 428。
    await tester.drag(_gutter(), const Offset(1000, 0));
    await tester.pump();
    expect(_leadingWidth(tester), 428);
    await tester.pumpAndSettle(); // 冲刷 Tooltip 悬停定时器
  });

  testWidgets('双击分割线复位到初始宽度', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_host());

    await tester.drag(_gutter(), const Offset(100, 0));
    await tester.pump();
    expect(_leadingWidth(tester), greaterThan(300));

    await tester.tap(_gutter());
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(_gutter());
    await tester.pumpAndSettle(); // 同时冲刷 Tooltip 悬停定时器
    expect(_leadingWidth(tester), 300);
  });

  testWidgets('persistenceKey：拖动结果落盘，重进页面自动恢复', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_host(persistenceKey: 'test.page'));

    await tester.drag(_gutter(), const Offset(100, 0));
    await tester.pumpAndSettle(); // 松手落盘
    final draggedWidth = _leadingWidth(tester);
    expect(draggedWidth, greaterThan(300));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('uten.splitView.test.page'), draggedWidth);

    // 卸载重挂：恢复上次拖定的宽度。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_host(persistenceKey: 'test.page'));
    await tester.pumpAndSettle();
    expect(_leadingWidth(tester), draggedWidth);
  });

  testWidgets('长分类自然宽可主动左拖缩窄，完整提示和行操作仍可用', (tester) async {
    tester.view.physicalSize = const Size(1600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    var deletes = 0;
    await tester.pumpWidget(_categoryHost(onDelete: () => deletes++));
    await tester.pumpAndSettle();
    expect(_categoryWidth(tester), greaterThan(300));

    await tester.drag(_categoryGutter(), const Offset(-1200, 0));
    await tester.pumpAndSettle();
    expect(_categoryWidth(tester), 220);
    expect(
      tester
          .renderObject<RenderParagraph>(find.text(_longCategory))
          .didExceedMaxLines,
      isTrue,
    );
    expect(find.byTooltip(_longCategory), findsOneWidget);
    final pane = tester.getRect(find.byKey(_categoryPaneKey));
    expect(
      pane.contains(tester.getCenter(find.byKey(_categoryDeleteKey))),
      isTrue,
    );
    await tester.tap(find.byKey(_categoryDeleteKey));
    await tester.pumpAndSettle();
    expect(deletes, 1);

    await tester.drag(_categoryGutter(), const Offset(100, 0));
    await tester.pumpAndSettle();
    final wider = _categoryWidth(tester);
    expect(wider, greaterThan(220));
    await tester.tap(_categoryGutter());
    await tester.pump(const Duration(milliseconds: 350));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(_categoryWidth(tester), wider - 16);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长分类缩窄偏好重挂保留，双击清除偏好并恢复自然宽', (tester) async {
    tester.view.physicalSize = const Size(1600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    const persistenceKey = 'test.long-category';
    const storedKey = 'uten.splitView.$persistenceKey';
    await tester.pumpWidget(_categoryHost(persistenceKey: persistenceKey));
    await tester.pumpAndSettle();
    final naturalWidth = _categoryWidth(tester);
    expect(naturalWidth, greaterThan(300));

    await tester.drag(_categoryGutter(), const Offset(-1200, 0));
    await tester.pumpAndSettle();
    expect(_categoryWidth(tester), 220);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(storedKey), 220);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_categoryHost(persistenceKey: persistenceKey));
    await tester.pumpAndSettle();
    expect(_categoryWidth(tester), 220);

    await tester.tap(_categoryGutter());
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(_categoryGutter());
    await tester.pumpAndSettle();
    expect(_categoryWidth(tester), naturalWidth);
    expect(prefs.getDouble(storedKey), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_categoryHost(persistenceKey: persistenceKey));
    await tester.pumpAndSettle();
    expect(_categoryWidth(tester), naturalWidth);
    expect(tester.takeException(), isNull);
  });

  testWidgets('货品分类缩窄前后真实主题截图', (tester) async {
    tester.view.physicalSize = const Size(1200, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    await loadAuditScreenshotFonts(tester);
    final captureKey = GlobalKey();
    PaymentStyleNode node(String id, String label) =>
        PaymentStyleNode(id: id, code: id, name: label, children: const []);
    final nodes = [
      PaymentStyleNode(
        id: 'goods',
        code: 'GOODS',
        name: '货品资料（GOODS）',
        children: [
          node('01', '原材料（A）'),
          node('02', '半成品（BCP）'),
          node('03', '成品（C）'),
          node('04', '轨道（GD01）'),
          node('05', '辅料（HL）'),
          node('06', '广告展板（HL01）'),
          node('07', 'OEM功能件（OEM）'),
          node('08', 'OEM物料（OEM）'),
          node('09', 'OEM成品（OEM）'),
        ],
      ),
      node('uncategorized', '未分类（LEGACY_ORPHAN）'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: auditScreenshotTheme(
          buildLightTheme().copyWith(platform: TargetPlatform.windows),
        ),
        home: RepaintBoundary(
          key: captureKey,
          child: Scaffold(
            appBar: AppBar(title: const Text('货品资料')),
            body: Padding(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
              child: UtenSplitView(
                leading: SizedBox(
                  key: _categoryPaneKey,
                  child: UtenCategoryTreeView<PaymentStyleNode>(
                    nodes: nodes,
                    flatLevelColors: true,
                    searchHint: '搜索分类/货品名称、英文名称或编号',
                    searchTrailing: IconButton.filledTonal(
                      tooltip: '新增分类',
                      onPressed: () {},
                      icon: const Icon(Icons.create_new_folder_outlined),
                    ),
                    trailingBuilder: (_) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('15'),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: '删除分类',
                          constraints: const BoxConstraints.tightFor(
                            width: 32,
                            height: 32,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: () {},
                          icon: const Icon(Icons.delete_outline, size: 16),
                        ),
                      ],
                    ),
                  ),
                ),
                trailing: const Center(child: Text('请选择分类查看详情')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await saveAuditScreenshot(tester, captureKey, 'split-width-before');
    await tester.drag(_categoryGutter(), const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(_categoryWidth(tester), 220);
    expect(tester.takeException(), isNull);
    await saveAuditScreenshot(tester, captureKey, 'split-width-after');
    await tester.runAsync(() async {
      await Directory('.local-artifacts').create(recursive: true);
      for (final suffix in ['before', 'after']) {
        await File(
          'build/ui-audit/split-width-$suffix.png',
        ).copy('.local-artifacts/split-width-$suffix.png');
      }
    });
  }, skip: !const bool.fromEnvironment('UTEN_CAPTURE_UI'));
}
