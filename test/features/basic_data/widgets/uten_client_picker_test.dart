import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/client_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_client_picker.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

import '../../../support/audit_screenshot_support.dart';

final _captureBoundary = GlobalKey(debugLabel: 'client-picker-table-capture');
const _longOverseasCategory = '海外客户及东南亚长期合作重点客户分类';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('客户分类区可拖到160且搜索清除展开选择确认和宽度记忆均可用', (tester) async {
    await loadAuditScreenshotFonts(tester);
    final repository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(1440, 900),
      clientRepository: repository,
      categoryTree: _clientTree(overseasName: _longOverseasCategory),
      theme: auditScreenshotTheme(
        buildLightTheme().copyWith(platform: TargetPlatform.windows),
      ),
    );
    await _openPicker(tester);
    final naturalWidth = tester.getSize(_categoryPane()).width;
    expect(naturalWidth, greaterThan(200));

    await tester.drag(_splitGutter(), const Offset(-1400, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(_categoryPane()).width, 160);
    expect(tester.getSize(_searchTextField()).width, 144);
    expect(
      tester
          .renderObject<RenderParagraph>(find.text(_longOverseasCategory))
          .didExceedMaxLines,
      isTrue,
    );
    expect(find.byTooltip(_longOverseasCategory), findsOneWidget);

    await tester.tap(find.byTooltip('展开$_longOverseasCategory'));
    await tester.pumpAndSettle();
    expect(find.text('东南亚客户').hitTestable(), findsOneWidget);
    await tester.tap(find.text('东南亚客户'));
    await tester.pumpAndSettle();
    expect(repository.listCategoryIds.last, 'southeast-asia');
    expect(find.text('远洋电器'), findsOneWidget);

    await tester.enterText(_searchEditable(), '远洋');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(repository.searchQueries, ['远洋']);
    expect(tester.getSize(_searchEditable()).width, greaterThan(48));
    expect(find.text('远洋电器'), findsOneWidget);
    final clear = find.byTooltip('清除搜索');
    _expectInsideCategoryPane(tester, clear);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_searchTextField()).controller!.text, '');
    expect(repository.listCategoryIds.last, 'southeast-asia');
    expect(tester.getSize(_categoryPane()).width, 160);

    await tester.tap(find.text('远洋电器'));
    await tester.pumpAndSettle();
    expect(find.text('已选择：远洋电器(C-002)'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('selected-client-name'))).data,
      '未选择',
    );
    if (const bool.fromEnvironment('UTEN_CAPTURE_UI')) {
      await saveAuditScreenshot(
        tester,
        _captureBoundary,
        'client-picker-table-narrow',
      );
    }
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('已选择：远洋电器'), findsOneWidget);

    await _openPicker(tester);
    expect(tester.getSize(_categoryPane()).width, 160);
    expect(find.byTooltip(_longOverseasCategory), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('客户分类窄栏在1.6文字缩放和${platform.name}操作尺寸下仍可使用', (tester) async {
      final repository = _FakeClientRepository();
      await _pumpPicker(
        tester,
        size: const Size(1440, 900),
        clientRepository: repository,
        theme: buildLightTheme().copyWith(platform: platform),
        textScale: 1.6,
      );
      await _openPicker(tester);
      await tester.drag(_splitGutter(), const Offset(-1400, 0));
      await tester.pumpAndSettle();
      final width = tester.getSize(_categoryPane()).width;
      expect(width, greaterThan(160), reason: '文字和操作尺寸继续决定安全下限');
      expect(width, lessThan(280));

      final expand = find.byTooltip('展开海外客户');
      _expectInsideCategoryPane(tester, expand);
      if (platform == TargetPlatform.android) {
        expect(tester.getSize(expand).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(expand).height, greaterThanOrEqualTo(48));
      }
      await tester.tap(expand);
      await tester.pumpAndSettle();
      await tester.tap(find.text('东南亚客户'));
      await tester.pumpAndSettle();
      expect(repository.listCategoryIds.last, 'southeast-asia');

      await tester.enterText(_searchEditable(), '远洋');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(repository.searchQueries, ['远洋']);
      expect(tester.getSize(_searchEditable()).width, greaterThan(48));
      final clear = find.byTooltip('清除搜索');
      _expectInsideCategoryPane(tester, clear);
      if (platform == TargetPlatform.android) {
        expect(tester.getSize(clear).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(clear).height, greaterThanOrEqualTo(48));
      }
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_searchTextField()).controller!.text, '');
      expect(tester.getSize(_categoryPane()).width, width);
      expect(find.text('远洋电器').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('客户以四列重点信息展示且不混入地址和财务资料', (tester) async {
    await _pumpPicker(
      tester,
      size: const Size(1200, 900),
      clientRepository: _FakeClientRepository(),
    );
    await _openPicker(tester);

    final table = tester.widget<MasterDataTableView<ClientListItem>>(
      find.byType(MasterDataTableView<ClientListItem>),
    );
    expect(table.columns.map((column) => column.label), [
      '客户名称',
      '编号',
      '联系人',
      '联系电话',
    ]);
    expect(table.listItemBuilder, isNull);
    expect(table.tableKey, isNull, reason: '不能继承客户主档的扩展列和列布局');
    expect(
      table.columns.every((column) => !column.supportsKeywordSearch),
      isTrue,
    );
    expect(table.showColumnChooser, isFalse);
    expect(find.text('本地客户'), findsOneWidget);
    expect(find.text('C-001'), findsOneWidget);
    expect(find.text('陈小姐'), findsOneWidget);
    expect(find.text('13800138000'), findsOneWidget);
    expect(find.text('0755-80000000'), findsNothing);
    expect(find.text('不应展示的详细地址'), findsNothing);
    expect(find.text('财务专用银行账号'), findsNothing);
    expect(find.text('客户银行'), findsNothing);
    expect(find.text('信用额度'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('空白简称和手机回退到客户全称与固定电话', (tester) async {
    await _pumpPicker(
      tester,
      size: const Size(1200, 900),
      clientRepository: _FakeClientRepository(
        categoryItems: const [
          ClientListItem(
            id: 'client-fallback',
            name: '  ',
            fullName: '回退客户有限公司',
            code: 'C-003',
            mobile: '  ',
            phone: '0755-81234567',
            categoryId: 'domestic',
            status: '使用',
          ),
        ],
      ),
    );
    await _openPicker(tester);

    expect(find.text('回退客户有限公司'), findsOneWidget);
    expect(find.text('0755-81234567'), findsOneWidget);
    await tester.tap(find.text('回退客户有限公司'));
    await tester.pumpAndSettle();
    expect(find.text('已选择：回退客户有限公司(C-003)'), findsOneWidget);
    expect(find.text('选择客户'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('表格单击仅暂选且取消不回写客户', (tester) async {
    await _pumpPicker(
      tester,
      size: const Size(1200, 900),
      clientRepository: _FakeClientRepository(),
    );
    await _openPicker(tester);
    await tester.tap(find.text('本地客户'));
    await tester.pumpAndSettle();

    expect(find.text('已选择：本地客户(C-001)'), findsOneWidget);
    final table = tester.widget<MasterDataTableView<ClientListItem>>(
      find.byType(MasterDataTableView<ClientListItem>),
    );
    expect(table.isSelected!(_FakeClientRepository.localClient), isTrue);
    expect(
      tester.widget<Text>(find.byKey(const Key('selected-client-name'))).data,
      '未选择',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('选择客户'), findsNothing);
    expect(find.text('未选择'), findsOneWidget);
  });

  testWidgets('定位未完成时点客户分类不产生分类请求', (tester) async {
    final repository = _FakeClientRepository();
    repository.delayedQuery = '海外客户';
    await _pumpPicker(
      tester,
      size: const Size(1800, 900),
      clientRepository: repository,
    );
    await _openPicker(tester);
    await tester.enterText(_searchEditable(), '海外客户');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.tap(find.text('海外客户').last);
    await tester.pump();
    expect(repository.listKeywords, [null]);
    repository.delayedSearch.complete(_page(const [], page: 1, size: 100));
    await tester.pumpAndSettle();
    expect(repository.listKeywords, [null]);
  });

  testWidgets('输入防抖期间点分类仍派发全局搜索', (tester) async {
    final repository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(1800, 900),
      clientRepository: repository,
    );
    await _openPicker(tester);
    await tester.enterText(_searchEditable(), '海外客户');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('海外客户').last);
    await tester.pumpAndSettle();
    expect(repository.listKeywords, [null]);
    expect(repository.searchQueries, ['海外客户']);
  });

  testWidgets('宽屏只保留左侧统一搜索且客户结果可跨分类回填', (tester) async {
    final clientRepository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(1200, 900),
      clientRepository: clientRepository,
    );

    await _openPicker(tester);

    // 左树默认全部收起（2026-09-24 用户口径）：只显示一级分类，
    // 二级「东南亚客户」须点父级行展开后才可见。
    expect(find.text('海外客户'), findsOneWidget);
    expect(find.text('东南亚客户'), findsNothing);

    final sheet = _widePickerSheet();
    expect(sheet, findsOneWidget);
    final searchFields = find.descendant(
      of: sheet,
      matching: find.byType(TextField),
    );
    expect(searchFields, findsOneWidget);
    expect(
      tester.widget<TextField>(searchFields).decoration?.hintText,
      '搜索分类/客户',
    );

    await tester.enterText(_searchEditable(), '远洋');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(clientRepository.searchQueries, ['远洋']);
    expect(find.text('远洋电器'), findsOneWidget);
    expect(find.text('C-002'), findsOneWidget);
    expect(find.text('本地客户'), findsNothing);

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.showSearch, isFalse);
    expect(tree.visibleFilterIds, {'overseas', 'southeast-asia'});
    expect(tree.selectedIds, {'domestic'});

    // 点击包含客户命中的父分类仍保留左侧查询，并用「分类 + 查询词」刷新右侧。
    await tester.tap(find.text('海外客户').last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_searchTextField()).controller?.text, '远洋');
    expect(clientRepository.listKeywords, [null]);
    expect(find.text('远洋电器'), findsOneWidget);
    // 层级色梯度：展开后二级行用第二档色（与一级深绿拉开），四档内各不相同。
    final rootRow = tester.widget<Material>(
      find
          .ancestor(of: find.text('海外客户'), matching: find.byType(Material))
          .first,
    );
    final childRow = tester.widget<Material>(
      find
          .ancestor(of: find.text('东南亚客户'), matching: find.byType(Material))
          .first,
    );
    expect(rootRow.color, UtenColors.treeLevel1);
    expect(childRow.color, UtenColors.treeLevel2);

    await tester.tap(find.text('远洋电器'));
    await tester.pumpAndSettle();
    // 二次操作契约：点行仅高亮（底栏显示已选择），还需点「确定」才选中返回。
    expect(find.text('已选择：远洋电器(C-002)'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('selected-client-name')), findsOneWidget);
    expect(find.text('已选择：远洋电器'), findsOneWidget);
  });

  testWidgets('分类名称搜索使用全局接口返回结果，左树点击不切回分类列表', (tester) async {
    final clientRepository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(1200, 900),
      clientRepository: clientRepository,
    );

    await _openPicker(tester);
    await tester.enterText(_searchEditable(), '海外客户');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(clientRepository.searchQueries, ['海外客户']);
    expect(clientRepository.listCategoryIds, ['domestic']);
    expect(find.text('远洋电器'), findsOneWidget);

    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.visibleFilterIds, {'overseas', 'southeast-asia'});
    expect(tree.selectedIds, {'domestic'});

    // 纯分类命中不退出左树搜索，也不得把分类词当作客户过滤词。
    await tester.tap(find.text('海外客户').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_searchTextField()).controller?.text,
      '海外客户',
    );
    expect(clientRepository.listKeywords.last, isNull);
    expect(clientRepository.excludeLegacyFlags.last, isTrue);
  });

  testWidgets('客户搜索会汇总全部分页的分类用于完整展开', (tester) async {
    final clientRepository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(1200, 900),
      clientRepository: clientRepository,
    );

    await _openPicker(tester);
    await tester.enterText(_searchEditable(), '集团');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(clientRepository.searchPages, [1, 2]);
    final tree = tester.widget<UtenCategoryTreeView<ProductCategoryNode>>(
      find.byType(UtenCategoryTreeView<ProductCategoryNode>),
    );
    expect(tree.visibleFilterIds, {'domestic', 'overseas', 'southeast-asia'});
  });

  testWidgets('服务端可选客户口径决定结果数量和页数', (tester) async {
    final clientRepository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(1200, 900),
      clientRepository: clientRepository,
    );

    await _openPicker(tester);
    await tester.enterText(_searchEditable(), '含占位');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(clientRepository.searchPages, [1]);
    expect(find.text('历史财务占位(LEGACY-FIN-CL-001)'), findsNothing);
    expect(find.text('远洋电器'), findsOneWidget);
    // 服务端过滤在分页前完成；有效结果仅一页时分页条应隐藏。
    expect(find.text('1 / 2'), findsNothing);
    expect(clientRepository.excludeLegacyFlags, everyElement(isTrue));
    expect(clientRepository.selectableOnlyFlags, everyElement(isTrue));
  });

  testWidgets('紧凑端底部滑窗使用同一统一搜索且无布局异常', (tester) async {
    final clientRepository = _FakeClientRepository();
    await _pumpPicker(
      tester,
      size: const Size(375, 812),
      clientRepository: clientRepository,
    );

    await _openPicker(tester);

    expect(_compactPickerSheet(const Size(375, 812)), findsOneWidget);
    expect(find.byKey(const Key('uten-client-picker-search')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(_searchEditable(), '远洋');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(find.text('远洋电器').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('远洋电器'));
    await tester.pumpAndSettle();
    // 二次操作契约：点行仅高亮，还需点「确定」才选中返回。
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('已选择：远洋电器'), findsOneWidget);
  });

  testWidgets('客户表格在明暗主题和紧凑放大界面保持可选且无溢出', (tester) async {
    await loadAuditScreenshotFonts(tester);
    for (final config in [
      (name: 'light', size: const Size(1440, 900), dark: false, zoom: 1.0),
      (name: 'dark', size: const Size(1440, 900), dark: true, zoom: 1.0),
      (name: 'compact', size: const Size(390, 844), dark: false, zoom: 1.0),
      (name: 'zoom', size: const Size(1200, 900), dark: true, zoom: 1.6),
    ]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _pumpPicker(
        tester,
        size: config.size,
        clientRepository: _FakeClientRepository(),
        theme: auditScreenshotTheme(
          config.dark ? buildDarkTheme() : buildLightTheme(),
        ),
        displayZoom: config.zoom,
      );
      await _openPicker(tester);
      await tester.tap(find.text('本地客户'));
      await tester.pumpAndSettle();
      expect(find.text('已选择：本地客户(C-001)'), findsOneWidget);
      expect(find.text('确定').hitTestable(), findsOneWidget);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      if (const bool.fromEnvironment('UTEN_CAPTURE_UI')) {
        await saveAuditScreenshot(
          tester,
          _captureBoundary,
          'client-picker-table-${config.name}',
        );
      }
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('已选择：本地客户'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}

Future<void> _pumpPicker(
  WidgetTester tester, {
  required Size size,
  required ClientRepository clientRepository,
  List<ProductCategoryNode>? categoryTree,
  ThemeData? theme,
  double displayZoom = 1,
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clientCategoryRepositoryProvider.overrideWithValue(
          _FakeClientCategoryRepository(categoryTree),
        ),
        clientRepositoryProvider.overrideWithValue(clientRepository),
      ],
      child: RepaintBoundary(
        key: _captureBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: UtenDisplayZoomBox(fontFactor: displayZoom, child: child!),
          ),
          home: const _PickerHarness(),
        ),
      ),
    ),
  );
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-client-picker')));
  await tester.pumpAndSettle();
  expect(find.text('选择客户'), findsOneWidget);
}

// 2026-10-17 滑窗口径：1200 屏 browse 档 = max(720, 1200 × 75%) = 900。
Finder _widePickerSheet() => find.byWidgetPredicate(
  (widget) =>
      widget is SizedBox &&
      widget.width == 900 &&
      widget.height == double.infinity,
);

Finder _compactPickerSheet(Size surfaceSize) => find.byWidgetPredicate(
  (widget) =>
      widget is SizedBox &&
      widget.width == null &&
      widget.height != null &&
      (widget.height! - surfaceSize.height * 0.85).abs() < 0.01,
);

/// 统一搜索已换成 UtenSearchBar：key 在组件上，输入/取控件须定位其内部输入框。
Finder _searchEditable() => find.descendant(
  of: find.byKey(const Key('uten-client-picker-search')),
  matching: find.byType(EditableText),
);

Finder _searchTextField() => find.descendant(
  of: find.byKey(const Key('uten-client-picker-search')),
  matching: find.byType(TextField),
);

Finder _categoryPane() =>
    find.byType(UtenCategoryTreeView<ProductCategoryNode>);

Finder _splitGutter() => find.byTooltip('拖动调整宽度 · 双击复位');

void _expectInsideCategoryPane(WidgetTester tester, Finder control) {
  final pane = tester.getRect(_categoryPane());
  final rect = tester.getRect(control);
  expect(rect.left, greaterThanOrEqualTo(pane.left));
  expect(rect.right, lessThanOrEqualTo(pane.right));
  expect(rect.top, greaterThanOrEqualTo(pane.top));
  expect(rect.bottom, lessThanOrEqualTo(pane.bottom));
  expect(control.hitTestable(), findsOneWidget);
}

class _PickerHarness extends ConsumerStatefulWidget {
  const _PickerHarness();

  @override
  ConsumerState<_PickerHarness> createState() => _PickerHarnessState();
}

class _PickerHarnessState extends ConsumerState<_PickerHarness> {
  String? _selectedName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          ElevatedButton(
            key: const Key('open-client-picker'),
            onPressed: () async {
              final selected = await showUtenClientPicker(context, ref);
              if (!mounted || selected == null) return;
              setState(
                () => _selectedName = selected.name ?? selected.fullName,
              );
            },
            child: const Text('打开客户选择'),
          ),
          Text(
            _selectedName == null ? '未选择' : '已选择：$_selectedName',
            key: const Key('selected-client-name'),
          ),
        ],
      ),
    );
  }
}

class _FakeClientCategoryRepository implements ClientCategoryRepository {
  _FakeClientCategoryRepository(this.nodes);

  final List<ProductCategoryNode>? nodes;

  @override
  Future<CategoryPrefixAvailability> prefixAvailability(
    String prefix, {
    String? categoryId,
  }) => throw UnsupportedError('not used');

  @override
  Future<CategoryPrefixPreview> prefixPreview(
    String id,
    String prefix, {
    String? parentId,
  }) => throw UnsupportedError('not used');

  @override
  Future<List<ProductCategoryNode>> tree() async => nodes ?? _clientTree();

  @override
  Future<ProductCategoryDetail> create(ProductCategorySaveInput input) =>
      throw UnsupportedError('not used');

  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');

  @override
  Future<ProductCategoryDetail> detail(String id) =>
      throw UnsupportedError('not used');

  @override
  Future<List<ProductCategoryNode>> subtree(String id) =>
      throw UnsupportedError('not used');

  @override
  Future<ProductCategoryDetail> update(
    String id,
    ProductCategoryUpdateInput input,
  ) => throw UnsupportedError('not used');
}

class _FakeClientRepository implements ClientRepository {
  _FakeClientRepository({this.categoryItems});

  final List<ClientListItem>? categoryItems;
  String? delayedQuery;
  final delayedSearch = Completer<PagedResult<ClientListItem>>();
  final listCategoryIds = <String>[];
  final listKeywords = <String?>[];
  final searchQueries = <String>[];
  final searchPages = <int>[];
  final excludeLegacyFlags = <bool>[];
  final selectableOnlyFlags = <bool>[];

  static const localClient = ClientListItem(
    id: 'client-local',
    code: 'C-001',
    name: '本地客户',
    linkman: '陈小姐',
    mobile: '13800138000',
    phone: '0755-80000000',
    address: '不应展示的详细地址',
    bank: '客户银行',
    bankAccount: '财务专用银行账号',
    credit: 500000,
    categoryId: 'domestic',
    status: '使用',
  );
  static const overseasClient = ClientListItem(
    id: 'client-overseas',
    code: 'C-002',
    name: '远洋电器',
    categoryId: 'southeast-asia',
    status: '使用',
  );
  static const legacyFinanceStub = ClientListItem(
    id: 'client-legacy-finance-stub',
    code: 'LEGACY-FIN-CL-001',
    name: '历史财务占位',
    categoryId: 'domestic',
  );

  @override
  Future<PagedResult<ClientListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
    bool excludeLegacyFinanceStub = true,
    bool selectableOnly = false,
  }) async {
    excludeLegacyFlags.add(excludeLegacyFinanceStub);
    selectableOnlyFlags.add(selectableOnly);
    listCategoryIds.add(categoryId);
    listKeywords.add(keyword);
    final items =
        categoryItems ??
        switch (categoryId) {
          'domestic' => const [localClient],
          'overseas' || 'southeast-asia' => const [overseasClient],
          _ => const <ClientListItem>[],
        };
    return _page(items, page: page, size: size);
  }

  @override
  Future<PagedResult<ClientListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
    bool excludeLegacyFinanceStub = true,
    bool selectableOnly = false,
  }) async {
    excludeLegacyFlags.add(excludeLegacyFinanceStub);
    selectableOnlyFlags.add(selectableOnly);
    searchQueries.add(keyword);
    searchPages.add(page);
    if (keyword == delayedQuery) return delayedSearch.future;
    if (keyword == '集团') {
      return PagedResult(
        items: page == 1 ? const [localClient] : const [overseasClient],
        page: page,
        size: size,
        total: 2,
        totalPages: 2,
      );
    }
    if (keyword == '含占位') {
      if (selectableOnly && excludeLegacyFinanceStub) {
        return PagedResult(
          items: const [overseasClient],
          page: 1,
          size: size,
          total: 1,
          totalPages: 1,
        );
      }
      return PagedResult(
        items: page == 1 ? const [legacyFinanceStub] : const [overseasClient],
        page: page,
        size: size,
        total: 2,
        totalPages: 2,
      );
    }
    final items = keyword == '远洋' || keyword == '海外客户'
        ? const [overseasClient]
        : const <ClientListItem>[];
    return _page(items, page: page, size: size);
  }

  @override
  Future<void> create(Map<String, dynamic> body) =>
      throw UnsupportedError('not used');

  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');

  @override
  Future<ClientDetail> detail(String id) => throw UnsupportedError('not used');

  @override
  Future<ClientFacets> facets(String categoryId) =>
      throw UnsupportedError('not used');

  @override
  Future<void> update(String id, Map<String, dynamic> body) =>
      throw UnsupportedError('not used');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PagedResult<ClientListItem> _page(
  List<ClientListItem> items, {
  required int page,
  required int size,
}) => PagedResult(
  items: items,
  page: page,
  size: size,
  total: items.length,
  totalPages: 1,
);

List<ProductCategoryNode> _clientTree({String overseasName = '海外客户'}) => [
  ProductCategoryNode(
    id: 'domestic',
    code: 'DOMESTIC',
    name: '国内客户',
    level: 0,
    children: const [],
  ),
  ProductCategoryNode(
    id: 'overseas',
    code: 'OVERSEAS',
    name: overseasName,
    level: 0,
    children: [
      ProductCategoryNode(
        id: 'southeast-asia',
        code: 'SEA',
        name: '东南亚客户',
        level: 1,
        parentId: 'overseas',
        children: const [],
      ),
    ],
  ),
];
