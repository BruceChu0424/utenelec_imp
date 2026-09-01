import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/production/widgets/where_used_material_picker.dart';

typedef _RequestHandler =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> query);

class _FakeApiClient extends ApiClient {
  _FakeApiClient(this.handler) : super(Dio());

  final _RequestHandler handler;
  final List<Map<String, dynamic>> queries = [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/production/reports/where-used/materials');
    final copied = Map<String, dynamic>.of(query ?? const {});
    queries.add(copied);
    return handler(copied);
  }
}

class _Launcher extends ConsumerWidget {
  const _Launcher({required this.onSelected});

  final ValueChanged<GoodsListItem?> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const Key('launch-picker'),
          onPressed: () async {
            onSelected(await showWhereUsedMaterialPicker(context, ref));
          },
          child: const Text('选择物料'),
        ),
      ),
    );
  }
}

Map<String, dynamic> _page({
  required List<Map<String, dynamic>> items,
  int page = 1,
  int totalPages = 1,
  int? total,
}) => <String, dynamic>{
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
  bool currentBom = false,
  bool bomIssue = false,
  bool productionHistory = false,
  bool subcontractHistory = false,
  bool autoCreated = false,
  bool deleted = false,
  String status = '使用',
}) => <String, dynamic>{
  'id': id,
  'code': code,
  'name': name,
  'model': 'M-86',
  'spec': '10A',
  'status': status,
  'sourceType': '采购',
  'categoryName': '原材料',
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
  required Size size,
  required ValueChanged<GoodsListItem?> onSelected,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(home: _Launcher(onSelected: onSelected)),
    ),
  );
  await tester.tap(find.byKey(const Key('launch-picker')));
}

void main() {
  testWidgets('empty keyword never requests and clearing restores the prompt', (
    tester,
  ) async {
    final api = _FakeApiClient((query) async {
      if (query['keyword'] == 'NONE') return _page(items: const []);
      return _page(
        items: [
          _item(
            id: '11111111-1111-4111-8111-111111111111',
            code: 'MAT-001',
            name: '历史螺丝',
            currentBom: true,
            bomIssue: true,
            productionHistory: true,
            subcontractHistory: true,
            autoCreated: true,
            deleted: true,
            status: '禁用',
          ),
        ],
      );
    });
    GoodsListItem? selected;

    await _pumpApp(
      tester,
      api,
      size: const Size(1200, 900),
      onSelected: (value) => selected = value,
    );
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('输入编号/名称开始搜索'), findsOneWidget);
    expect(api.queries, isEmpty);

    final search = find.byKey(const Key('where-used-material-search'));
    await tester.enterText(search, '   ');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('输入编号/名称开始搜索'), findsOneWidget);
    expect(api.queries, isEmpty);

    await tester.enterText(search, 'MAT-001');
    await tester.pump(const Duration(milliseconds: 299));
    expect(api.queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pumpAndSettle();

    expect(api.queries, hasLength(1));
    expect(api.queries.single, containsPair('keyword', 'MAT-001'));
    expect(api.queries.single, containsPair('page', 1));
    expect(api.queries.single, containsPair('size', 50));
    expect(find.text('当前 BOM'), findsOneWidget);
    expect(find.text('BOM 异常'), findsOneWidget);
    expect(find.text('生产历史'), findsOneWidget);
    expect(find.text('委外历史'), findsOneWidget);
    expect(find.text('状态：禁用'), findsOneWidget);
    expect(find.text('自动占位'), findsOneWidget);
    expect(find.text('已删除'), findsOneWidget);

    // UtenSearchBar 内置清除按钮（无独立 key，按搜索框内关闭图标定位）。
    await tester.tap(
      find.descendant(
        of: search,
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('输入编号/名称开始搜索'), findsOneWidget);
    expect(find.text('历史螺丝(MAT-001)'), findsNothing);
    expect(api.queries, hasLength(1));

    await tester.enterText(search, 'NONE');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的物料'), findsOneWidget);
    expect(find.text('请尝试更短的编号或名称，也可改用型号或规格。'), findsOneWidget);
    expect(find.textContaining('查看全部'), findsNothing);
    expect(api.queries, hasLength(2));
    await tester.tap(
      find.descendant(
        of: search,
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('输入编号/名称开始搜索'), findsOneWidget);
    expect(api.queries, hasLength(2));

    await tester.enterText(search, 'MAT-001');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(api.queries, hasLength(3));

    await tester.tap(
      find.byKey(
        const ValueKey(
          'where-used-material-11111111-1111-4111-8111-111111111111',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(selected?.id, '11111111-1111-4111-8111-111111111111');
    expect(selected?.code, 'MAT-001');
    expect(selected?.status, '禁用');
    expect(selected?.autoCreated, isTrue);
  });

  testWidgets('debounces keyword and ignores an older response', (
    tester,
  ) async {
    final pending = <String, Completer<Map<String, dynamic>>>{};
    final api = _FakeApiClient((query) {
      final keyword = query['keyword'] as String;
      return (pending[keyword] ??= Completer<Map<String, dynamic>>()).future;
    });

    await _pumpApp(
      tester,
      api,
      size: const Size(1200, 900),
      onSelected: (_) {},
    );
    await tester.pumpAndSettle();
    expect(api.queries, isEmpty);

    final search = find.byKey(const Key('where-used-material-search'));
    await tester.enterText(search, 'MAT');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(search, 'MAT-0');
    await tester.pump(const Duration(milliseconds: 299));
    expect(api.queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 2));
    expect(api.queries, hasLength(1));
    expect(api.queries.last, containsPair('keyword', 'MAT-0'));

    await tester.enterText(search, 'MAT-001');
    await tester.pump(const Duration(milliseconds: 301));
    expect(api.queries, hasLength(2));
    expect(api.queries.last, containsPair('keyword', 'MAT-001'));

    pending['MAT-001']!.complete(
      _page(
        items: [_item(id: 'new-result', code: 'MAT-001', name: '最新结果')],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('最新结果(MAT-001)'), findsOneWidget);

    pending['MAT-0']!.complete(
      _page(
        items: [_item(id: 'old-result', code: 'MAT-000', name: '旧响应')],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('最新结果(MAT-001)'), findsOneWidget);
    expect(find.text('旧响应(MAT-000)'), findsNothing);
  });

  testWidgets('allows selecting a matching good without known relations', (
    tester,
  ) async {
    final api = _FakeApiClient(
      (_) async => _page(
        items: [
          _item(
            id: '22222222-2222-4222-8222-222222222222',
            code: 'FREE-001',
            name: '暂无关系物料',
          ),
        ],
      ),
    );
    GoodsListItem? selected;

    await _pumpApp(
      tester,
      api,
      size: const Size(1200, 900),
      onSelected: (value) => selected = value,
    );
    await tester.pumpAndSettle();
    expect(api.queries, isEmpty);

    await tester.enterText(
      find.byKey(const Key('where-used-material-search')),
      'FREE-001',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();

    expect(api.queries, hasLength(1));
    expect(api.queries.single, containsPair('keyword', 'FREE-001'));
    expect(find.text('暂无已知关系'), findsOneWidget);

    await tester.tap(
      find.byKey(
        const ValueKey(
          'where-used-material-22222222-2222-4222-8222-222222222222',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(selected?.id, '22222222-2222-4222-8222-222222222222');
    expect(selected?.code, 'FREE-001');
    expect(selected?.name, '暂无关系物料');
  });

  testWidgets('compact picker recovers from error and paginates', (
    tester,
  ) async {
    var call = 0;
    final api = _FakeApiClient((query) async {
      call += 1;
      if (call == 1) throw ApiException('NETWORK', '网络暂时不可用');
      final page = query['page'] as int;
      return _page(
        items: [
          _item(
            id: 'page-$page',
            code: 'MAT-$page',
            name: '第 $page 页物料',
            productionHistory: true,
          ),
        ],
        page: page,
        totalPages: 2,
        total: 2,
      );
    });

    await _pumpApp(tester, api, size: const Size(390, 844), onSelected: (_) {});
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('输入编号/名称开始搜索'), findsOneWidget);
    expect(api.queries, isEmpty);
    await tester.enterText(
      find.byKey(const Key('where-used-material-search')),
      'MAT',
    );
    await tester.pump(const Duration(milliseconds: 301));
    await tester.tap(find.byKey(const Key('where-used-material-retry')));
    await tester.pumpAndSettle();
    expect(find.text('第 1 页物料(MAT-1)'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('where-used-material-next')));
    await tester.pumpAndSettle();
    expect(api.queries.last, containsPair('page', 2));
    expect(find.text('第 2 页物料(MAT-2)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
