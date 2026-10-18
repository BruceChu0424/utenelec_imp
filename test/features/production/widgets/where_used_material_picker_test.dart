import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/widgets/where_used_material_picker.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

const _base = '/production/reports/where-used';
const _sheetKey = Key('goods-picker-sheet');
const _searchKey = Key('uten-goods-picker-search');

class _PickerSnapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

final _pickerPermissions = StateProvider<Set<String>>(
  (ref) => {Perm.productionWhereUsedView},
);

typedef _RequestHandler =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> query);

class _FakeApiClient extends ApiClient {
  _FakeApiClient(this.handler, {this.treeResult}) : super(Dio());

  final _RequestHandler handler;
  final Future<Map<String, dynamic>>? treeResult;
  final paths = <String>[];
  final queries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    paths.add(path);
    if (path == '$_base/material-categories') {
      return treeResult ??
          Future.value({
            'items': [
              _category('material-root', '原材料'),
              _category('history-uncategorized', '历史未分类'),
            ],
          });
    }
    if (path == '$_base/material-category-matches') {
      return {
        'items': ['material-root', 'history-uncategorized'],
      };
    }
    expect(path, '$_base/materials', reason: '反查仅使用报表权限端点');
    final copied = Map<String, dynamic>.of(query ?? const {});
    queries.add(copied);
    return handler(copied);
  }
}

Map<String, dynamic> _category(String id, String name) => {
  'id': id,
  'code': '',
  'name': name,
  'level': 0,
  'children': <Object>[],
};

class _Launcher extends ConsumerWidget {
  const _Launcher({required this.onSelected});
  final ValueChanged<GoodsListItem?> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: FilledButton(
        key: const Key('launch-picker'),
        onPressed: () async =>
            onSelected(await showWhereUsedMaterialPicker(context, ref)),
        child: const Text('选择物料'),
      ),
    ),
  );
}

Map<String, dynamic> _page({
  required List<Map<String, dynamic>> items,
  int page = 1,
  int totalPages = 1,
  int? total,
}) => {
  'items': items,
  'page': page,
  'size': 50,
  'total': total ?? items.length,
  'totalPages': totalPages,
};

Map<String, dynamic> _item({
  required String id,
  required String code,
  required String name,
  String categoryId = 'material-root',
  bool currentBom = false,
  bool bomIssue = false,
  bool productionHistory = false,
  bool subcontractHistory = false,
  bool autoCreated = false,
  bool deleted = false,
  String status = '使用',
}) => {
  'id': id,
  'code': code,
  'name': name,
  'model': 'M-86',
  'spec': '10A',
  'status': status,
  'sourceType': '采购',
  'categoryName': '原材料',
  'categoryId': categoryId,
  'autoCreated': autoCreated,
  'deleted': deleted,
  'currentBom': currentBom,
  'bomIssue': bomIssue,
  'productionHistory': productionHistory,
  'subcontractHistory': subcontractHistory,
};

Future<void> _pumpApp(
  WidgetTester tester,
  _FakeApiClient api, {
  Size size = const Size(1200, 900),
  required ValueChanged<GoodsListItem?> onSelected,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionSnapshotProvider.overrideWith(_PickerSnapshot.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'picker-viewer'),
        ),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_pickerPermissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(home: _Launcher(onSelected: onSelected)),
    ),
  );
  await tester.tap(find.byKey(const Key('launch-picker')));
}

Future<void> _search(WidgetTester tester, String keyword) async {
  await tester.enterText(find.byKey(_searchKey), keyword);
  await tester.pump(const Duration(milliseconds: 301));
}

Finder _row(String id) => find.byKey(ValueKey('goods-picker-item-$id'));

void main() {
  testWidgets(
    'report permission alone browses categories in the shared right panel',
    (tester) async {
      final api = _FakeApiClient(
        (query) async => _page(
          items: [_item(id: 'raw', code: 'MAT-1', name: '分类内物料')],
        ),
      );
      GoodsListItem? selected;
      await _pumpApp(tester, api, onSelected: (value) => selected = value);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(UtenSplitView), findsOneWidget);
      // 2026-10-17 滑窗口径：1200 屏 browse 档宽 = max(720, 900) = 900，
      // 面板左缘 = 1200 - 900 = 300。
      expect(tester.getTopLeft(find.byKey(_sheetKey)).dx, 300);
      expect(api.queries, isEmpty, reason: '沿用销售选择器懒加载');
      await tester.tap(find.text('原材料'));
      await tester.pumpAndSettle();
      expect(api.queries.single, containsPair('categoryId', 'material-root'));
      expect(api.queries.single.containsKey('keyword'), isFalse);
      await tester.tap(_row('raw'));
      await tester.pump();
      expect(selected, isNull);
      expect(find.byKey(_sheetKey), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(find.byKey(_sheetKey), findsNothing);
      expect(api.paths, everyElement(startsWith(_base)));
    },
  );

  testWidgets(
    'historical goods retain evidence and require explicit confirmation',
    (tester) async {
      final api = _FakeApiClient(
        (query) async => _page(
          items: [
            _item(
              id: 'history',
              code: 'OLD-1',
              name: '历史螺丝',
              categoryId: 'history-uncategorized',
              currentBom: true,
              bomIssue: true,
              productionHistory: true,
              subcontractHistory: true,
              autoCreated: true,
              deleted: true,
              status: '禁用',
            ),
          ],
        ),
      );
      GoodsListItem? selected;
      await _pumpApp(tester, api, onSelected: (value) => selected = value);
      await tester.pumpAndSettle();
      await _search(tester, 'OLD-1');
      await tester.pumpAndSettle();
      final table = tester.widget<MasterDataTableView<GoodsListItem>>(
        find.byKey(const Key('goods-picker-paged-list')),
      );
      expect(table.columns.map((column) => column.label), [
        '物料名称',
        '编号',
        '分类',
        '状态 / 提示',
        '关联依据',
      ]);
      expect(table.tableKey, isNull);
      expect(find.text('当前 BOM · 生产历史 · 委外历史'), findsOneWidget);
      for (final label in ['BOM 异常', '状态：禁用', '自动占位', '已删除']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(_row('history'));
      await tester.pump();
      expect(selected, isNull);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(selected?.id, 'history');
      expect(selected?.status, '禁用');
      expect(selected?.autoCreated, isTrue);
      expect(selected?.categoryId, 'history-uncategorized');
      expect(find.byKey(_sheetKey), findsNothing);
    },
  );

  testWidgets(
    'normal and unknown material states remain readable without alert badges',
    (tester) async {
      final statuses = ['使用', '启用', 'ENABLED', 'ACTIVE', '待核实'];
      final api = _FakeApiClient(
        (_) async => _page(
          items: [
            for (var index = 0; index < statuses.length; index++)
              _item(
                id: 'state-$index',
                code: 'STATE-$index',
                name: '状态物料 $index',
                status: statuses[index],
                currentBom: true,
              ),
          ],
        ),
      );
      await _pumpApp(tester, api, onSelected: (_) {});
      await tester.pumpAndSettle();
      await _search(tester, 'STATE');
      await tester.pumpAndSettle();
      for (var index = 0; index < statuses.length; index++) {
        final row = _row('state-$index');
        final status = find.descendant(
          of: row,
          matching: find.textContaining('状态：${statuses[index]}'),
        );
        await tester.ensureVisible(row);
        final text = tester.widget<Text>(status);
        final colors = Theme.of(tester.element(status)).colorScheme;
        expect(text.style?.color, colors.onSurfaceVariant);
        expect(
          find.descendant(of: row, matching: find.text('当前 BOM')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: row,
            matching: find.text('状态：${statuses[index]}'),
          ),
          findsOneWidget,
          reason: '状态列只显示一份中性状态，不重复生成警告徽章',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact classification stays inside the picker and can select history',
    (tester) async {
      final api = _FakeApiClient(
        (query) async => _page(
          items: [
            _item(
              id: 'orphan',
              code: 'ORPHAN',
              name: '无分类历史物料',
              categoryId: 'history-uncategorized',
            ),
          ],
        ),
      );
      GoodsListItem? selected;
      await _pumpApp(
        tester,
        api,
        size: const Size(390, 844),
        onSelected: (value) => selected = value,
      );
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.byIcon(Icons.account_tree_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史未分类'));
      await tester.pumpAndSettle();
      expect(
        api.queries.single,
        containsPair('categoryId', 'history-uncategorized'),
      );
      expect(find.byKey(_sheetKey), findsOneWidget);
      await tester.tap(_row('orphan'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(selected?.id, 'orphan');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'debounces, ignores older search and clearing browses the selected category',
    (tester) async {
      final pending = <String, Completer<Map<String, dynamic>>>{};
      final api = _FakeApiClient((query) {
        final keyword = query['keyword'] as String?;
        if (keyword == null) {
          return Future.value(
            _page(
              items: [_item(id: 'browse', code: 'BROWSE', name: '分类浏览物料')],
            ),
          );
        }
        return (pending[keyword] ??= Completer<Map<String, dynamic>>()).future;
      });
      await _pumpApp(tester, api, onSelected: (_) {});
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(_searchKey), 'MAT');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byKey(_searchKey), 'MAT-0');
      await tester.pump(const Duration(milliseconds: 299));
      expect(api.queries, isEmpty);
      await tester.pump(const Duration(milliseconds: 2));
      expect(api.queries.single['keyword'], 'MAT-0');
      await _search(tester, 'MAT-001');
      pending['MAT-001']!.complete(
        _page(
          items: [
            _item(id: 'same', code: 'MAT-001', name: '最新结果', currentBom: true),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('最新结果'), findsOneWidget);
      pending['MAT-0']!.complete(
        _page(
          items: [
            _item(id: 'same', code: 'MAT-000', name: '旧响应', deleted: true),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('旧响应'), findsNothing);
      await tester.tap(_row('same'));
      await tester.pump();
      expect(find.text('当前 BOM'), findsOneWidget);
      expect(find.text('已删除'), findsNothing, reason: '旧请求不能覆盖同一货品的新证据标签');
      final search = find.byKey(_searchKey);
      await tester.tap(
        find.descendant(of: search, matching: find.byIcon(Icons.close_rounded)),
      );
      await tester.pumpAndSettle();
      expect(find.text('最新结果'), findsNothing);
      expect(find.text('分类浏览物料'), findsOneWidget);
      expect(api.queries.last, containsPair('categoryId', 'material-root'));
      expect(api.queries.last.containsKey('keyword'), isFalse);
    },
  );

  testWidgets(
    'revocation closes the selected picker and rejects delayed results',
    (tester) async {
      final gate = Completer<Map<String, dynamic>>();
      final api = _FakeApiClient((_) => gate.future);
      GoodsListItem? selected;
      await _pumpApp(
        tester,
        api,
        size: const Size(390, 844),
        onSelected: (value) => selected = value,
      );
      await tester.pumpAndSettle();
      await _search(tester, 'OLD');
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(_sheetKey)),
      );
      container.read(_pickerPermissions.notifier).state = {};
      await tester.pumpAndSettle();
      gate.complete(
        _page(
          items: [_item(id: 'old', code: 'OLD', name: '旧范围物料')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_sheetKey), findsNothing);
      expect(find.text('旧范围物料'), findsNothing);
      expect(selected, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'revoke and regrant while loading categories cannot reopen the old snapshot',
    (tester) async {
      final treeGate = Completer<Map<String, dynamic>>();
      final api = _FakeApiClient(
        (_) async => _page(items: []),
        treeResult: treeGate.future,
      );
      await _pumpApp(tester, api, onSelected: (_) {});
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('launch-picker'))),
      );
      container.read(_pickerPermissions.notifier).state = {};
      await tester.pump();
      container.read(_pickerPermissions.notifier).state = {
        Perm.productionWhereUsedView,
      };
      await tester.pump();
      treeGate.complete({
        'items': [_category('material-root', '原材料')],
      });
      await tester.pumpAndSettle();
      expect(find.byKey(_sheetKey), findsNothing);
      expect(api.queries, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keeps API error messages and paging retains earlier rows until confirmation',
    (tester) async {
      var call = 0;
      final nextPage = Completer<Map<String, dynamic>>();
      final api = _FakeApiClient((query) async {
        call++;
        if (call == 1) throw ApiException('NETWORK', '网络暂时不可用');
        if (query['page'] == 2) return nextPage.future;
        return _page(
          items: [_item(id: 'first', code: 'MAT-1', name: '首屏物料')],
          totalPages: 2,
          total: 2,
        );
      });
      GoodsListItem? selected;
      await _pumpApp(tester, api, onSelected: (value) => selected = value);
      await tester.pumpAndSettle();
      await _search(tester, 'MAT');
      await tester.pumpAndSettle();
      expect(find.text('网络暂时不可用'), findsWidgets);
      await tester.tap(find.text('重试').last);
      await tester.pumpAndSettle();
      final list = find.byKey(const Key('goods-picker-paged-list'));
      final originalElement = tester.element(list);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.text('首屏物料'))),
      );
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      await tester.pump();
      await tester.pump();
      expect(api.queries.map((query) => query['page']), [1, 1, 2]);
      expect(find.text('首屏物料'), findsOneWidget);
      expect(tester.element(list), same(originalElement));
      nextPage.complete(
        _page(
          items: [_item(id: 'second', code: 'MAT-2', name: '续页物料')],
          page: 2,
          totalPages: 2,
          total: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('首屏物料'), findsOneWidget);
      expect(find.text('续页物料'), findsOneWidget);
      await tester.tap(_row('first'));
      await tester.pump();
      expect(selected, isNull);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(selected?.id, 'first');
      expect(tester.takeException(), isNull);
    },
  );
}
