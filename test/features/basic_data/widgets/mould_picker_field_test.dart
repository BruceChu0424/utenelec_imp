import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/mould_picker_field.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

import '../../../support/audit_screenshot_support.dart';

final _captureBoundary = GlobalKey();

void main() {
  testWidgets(
    'typing suggests real moulds and selecting commits only their UUID',
    (tester) async {
      final repository = _Moulds();
      String? selected;
      await _open(
        tester,
        repository,
        openPicker: false,
        onChanged: (v) => selected = v as String?,
      );
      await tester.enterText(find.byType(TextField), '5M');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(repository.hintRequests, ['5M']);
      expect(selected, isNull);
      await tester.tap(find.text('M1 候选模具'));
      await tester.pumpAndSettle();
      expect(selected, 'mould-1');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'M1 候选模具',
      );
      expect(find.text('选择模具'), findsNothing);
    },
  );

  testWidgets(
    'picker carries the typed query and cancel restores the bound reference',
    (tester) async {
      final repository = _Moulds();
      final changes = <dynamic>[];
      await _open(
        tester,
        repository,
        openPicker: false,
        initialValue: 'old-id',
        initialDisplay: 'OLD 旧模具',
        onChanged: changes.add,
      );
      await tester.enterText(find.byType(TextField), '5M开关');
      await tester.tap(find.text('选择'));
      await tester.pumpAndSettle();
      expect(repository.requests, [('5M开关', 1)]);
      expect(repository.hintRequests, isEmpty);
      expect(find.text('系列 / 分类'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'OLD 旧模具',
      );
      await tester.tap(find.byTooltip('清除模具'));
      await tester.pumpAndSettle();
      expect(changes, [null]);
    },
  );

  testWidgets('分类与明细并排，分类筛选和列搜索传到服务器并回填UUID', (tester) async {
    final repository = _Moulds();
    String? picked;
    await _open(tester, repository, onChanged: (v) => picked = v as String?);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.text('五金模具'));
    await tester.pumpAndSettle();
    expect(repository.categories.last, 'metal');
    expect(find.text('分类模具'), findsOneWidget);
    await tester.tap(find.text('模具编号'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-column-keyword-input')),
      'M3',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(repository.filtersSent.last, {'search.code': 'M3'});
    await tester.tap(find.text('分类模具'));
    await tester.pumpAndSettle();
    expect(picked, isNull);
    expect(find.text('选择模具'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(picked, 'mould-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('新输入防抖期间旧成功响应不能展示无关模具', (tester) async {
    final repository = _Moulds();
    final old = repository.hold('', 1);
    final fresh = repository.hold('螺丝 M3', 1);
    await _open(tester, repository);
    await tester.enterText(_search(), '螺丝 M3');
    old.complete(_page('旧模具', page: 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('旧模具'), findsNothing);
    expect(repository.requests, [('', 1)]);
    await tester.pump(const Duration(milliseconds: 201));
    fresh.complete(_page('新模具', page: 1));
    await tester.pumpAndSettle();
    expect(repository.requests, [('', 1), ('螺丝 M3', 1)]);
    expect(find.text('新模具'), findsOneWidget);
    expect(find.text('旧模具'), findsNothing);
  });

  testWidgets('旧错误不会覆盖新结果或关闭新查询的加载状态', (tester) async {
    final repository = _Moulds();
    final old = repository.hold('', 1);
    final fresh = repository.hold('新词', 1);
    await _open(tester, repository);
    await tester.enterText(_search(), '新词');
    await tester.pump(const Duration(milliseconds: 301));
    old.completeError(StateError('old request failed'));
    await tester.pump();
    expect(find.text('模具搜索失败，请重试'), findsNothing);
    fresh.complete(_page('新模具', page: 1));
    await tester.pumpAndSettle();
    expect(find.text('新模具'), findsOneWidget);
    expect(find.text('模具搜索失败，请重试'), findsNothing);
  });

  testWidgets('模具可翻到首50条以后的页并回填稳定ID', (tester) async {
    final repository = _Moulds();
    String? picked;
    await _open(
      tester,
      repository,
      onChanged: (value) => picked = value as String?,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('master-table-page-next')));
    await tester.pumpAndSettle();
    expect(repository.requests, [('', 1), ('', 2)]);
    await tester.tap(find.text('第2页模具'));
    await tester.pumpAndSettle();
    expect(picked, isNull);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(picked, 'mould-2');
    expect(find.text('选择模具'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('后页失败可重试同一页', (tester) async {
    final repository = _Moulds();
    final failing = repository.hold('', 2);
    await _open(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('master-table-page-next')));
    await tester.pump();
    failing.completeError(StateError('temporary failure'));
    await tester.pumpAndSettle();
    repository.release('', 2);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(repository.requests, [('', 1), ('', 2), ('', 2)]);
    expect(find.text('第2页模具'), findsOneWidget);
  });

  for (final dismissal in ['取消', '关闭', '遮罩']) {
    testWidgets('模具暂选后$dismissal不覆盖原绑定', (tester) async {
      final changes = <dynamic>[];
      await _open(
        tester,
        _Moulds(),
        initialValue: 'old-id',
        initialDisplay: 'OLD 旧模具',
        onChanged: changes.add,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('第1页模具'));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(find.text('已选择：M1 第1页模具'), findsOneWidget);
      if (dismissal == '遮罩') {
        await tester.tapAt(const Offset(10, 400));
      } else if (dismissal == '关闭') {
        await tester.tap(find.byTooltip('关闭'));
      } else {
        await tester.tap(find.text('取消'));
      }
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(find.text('选择模具'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'OLD 旧模具',
      );
    });
  }

  testWidgets('搜索和翻页清除旧模具暂选，迟到确认不可提交', (tester) async {
    final changes = <dynamic>[];
    await _open(tester, _Moulds(), onChanged: changes.add);
    await tester.pumpAndSettle();
    await tester.tap(find.text('第1页模具'));
    await tester.pumpAndSettle();
    final oldConfirm = tester
        .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
        .onConfirm!;
    await tester.enterText(_search(), '新关键词');
    oldConfirm();
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(find.text('未选择'), findsOneWidget);
    await tester.tap(find.text('第1页模具'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('master-table-page-next')));
    await tester.pumpAndSettle();
    expect(find.text('未选择'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
  });

  testWidgets('模具确认栏在明暗桌面与紧凑屏均可操作', (tester) async {
    await loadAuditScreenshotFonts(tester);
    for (final config in [
      (name: 'desktop', size: const Size(1440, 900), dark: false),
      (name: 'compact-dark', size: const Size(390, 844), dark: true),
    ]) {
      await tester.pumpWidget(const SizedBox.shrink());
      final changes = <dynamic>[];
      await _open(
        tester,
        _Moulds(),
        onChanged: changes.add,
        size: config.size,
        dark: config.dark,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('第1页模具'));
      await tester.pumpAndSettle();
      expect(changes, isEmpty);
      expect(find.text('确定').hitTestable(), findsOneWidget);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('UTEN_CAPTURE_UI')) {
        await saveAuditScreenshot(
          tester,
          _captureBoundary,
          'mould-picker-confirm-${config.name}',
        );
      }
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(changes, ['mould-1']);
    }
  });
}

Finder _search() => find.widgetWithText(TextField, '模具编号 / 名称 / 位置 / 制造商 / 备注');

Future<void> _open(
  WidgetTester tester,
  _Moulds repository, {
  ValueChanged<dynamic>? onChanged,
  bool openPicker = true,
  String? initialValue,
  String? initialDisplay,
  Size size = const Size(1200, 900),
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mouldRepositoryProvider.overrideWithValue(repository),
        mouldCategoryRepositoryProvider.overrideWithValue(_Categories()),
      ],
      child: MaterialApp(
        theme: auditScreenshotTheme(
          dark ? buildDarkTheme() : buildLightTheme(),
        ),
        builder: (_, child) =>
            RepaintBoundary(key: _captureBoundary, child: child),
        home: Scaffold(
          body: MouldPickerField(
            initialValue: initialValue,
            initialDisplay: initialDisplay,
            initialDisplayId: initialValue,
            onChanged: onChanged ?? (_) {},
          ),
        ),
      ),
    ),
  );
  if (openPicker) await tester.tap(find.text('选择'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

class _Moulds extends Fake implements MouldRepository {
  final hintRequests = <String>[];
  final requests = <(String, int)>[];
  final categories = <String?>[];
  final filtersSent = <Map<String, String?>>[];
  final _held = <(String, int), Completer<PagedResult<MouldListItem>>>{};

  Completer<PagedResult<MouldListItem>> hold(String query, int page) =>
      _held[(query, page)] = Completer<PagedResult<MouldListItem>>();

  void release(String query, int page) => _held.remove((query, page));

  @override
  Future<PagedResult<MouldListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
  }) async {
    hintRequests.add(keyword);
    return PagedResult(
      items: const [
        MouldListItem(
          id: 'mould-1',
          code: 'M1',
          name: '候选模具',
          categoryName: '5M系列',
        ),
      ],
      page: 1,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }

  @override
  Future<MouldFacets> globalFacets() async =>
      const MouldFacets(fields: {}, nullCounts: {});

  @override
  Future<MouldFacets> facets(String id) => globalFacets();

  @override
  Future<PagedResult<MouldListItem>> listGlobal({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  }) async {
    categories.add(null);
    filtersSent.add(Map.of(filters));
    requests.add((keyword ?? '', page));
    return _held[(keyword ?? '', page)]?.future ??
        _page('第$page页模具', page: page);
  }

  @override
  Future<PagedResult<MouldListItem>> list(
    String categoryId, {
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  }) async {
    categories.add(categoryId);
    filtersSent.add(Map.of(filters));
    requests.add((keyword ?? '', page));
    return _page('分类模具', page: page);
  }
}

PagedResult<MouldListItem> _page(String name, {required int page}) =>
    PagedResult(
      items: [MouldListItem(id: 'mould-$page', code: 'M$page', name: name)],
      page: page,
      size: 50,
      total: 51,
      totalPages: 2,
    );

class _Categories extends Fake implements MouldCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'plastic',
      code: 'P',
      name: '塑胶模具',
      level: 1,
      children: [],
    ),
    ProductCategoryNode(
      id: 'metal',
      code: 'M',
      name: '五金模具',
      level: 1,
      children: [],
    ),
  ];
}
