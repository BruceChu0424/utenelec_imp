import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_request_dialog.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

import 'workshop_material_test_support.dart';

const _raw = WmMaterialOption(
  goodsId: 'raw',
  goodsName: '首次申请原料',
  goodsCode: 'RAW-601',
  colorId: 'white',
  colorName: '白',
  unitName: 'g',
  warehouseAvailableQty: 800,
);
const _later = WmMaterialOption(
  goodsId: 'later',
  goodsName: '第二种原料',
  unitName: 'kg',
);

class _RequestRepo extends FakeWorkshopMaterialRepository {
  int strictReads = 0;
  int failures = 0;
  final calls = <({String keyword, int page, List<String> goodsIds})>[];
  final submits =
      <
        ({
          String workshop,
          String kind,
          List<Map<String, dynamic>> lines,
          String key,
        })
      >[];
  Completer<PagedResult<WmMaterialOption>>? slowSearch;

  @override
  Future<List<WmMaterialOption>> materials(String workshopId) async {
    strictReads++;
    return const [];
  }

  @override
  Future<PagedResult<WmMaterialOption>> requestMaterials(
    String workshopId, {
    String keyword = '',
    List<String> goodsIds = const [],
    int page = 1,
    int size = 50,
  }) async {
    expect(workshopId, 'w1');
    calls.add((keyword: keyword, page: page, goodsIds: goodsIds));
    if (keyword == '旧搜索' && slowSearch != null) return slowSearch!.future;
    final rows = keyword == 'RAW-601' || goodsIds.contains('raw')
        ? [_raw]
        : keyword == '新搜索'
        ? [_later]
        : <WmMaterialOption>[];
    return PagedResult(
      items: rows,
      page: page,
      size: size,
      total: rows.length,
      totalPages: 1,
    );
  }

  @override
  Future<WmRequisition> createRequisition({
    required String kind,
    required String workshopDepartmentId,
    required List<Map<String, dynamic>> lines,
    String? remark,
    required String idempotencyKey,
  }) async {
    submits.add((
      workshop: workshopDepartmentId,
      kind: kind,
      lines: lines,
      key: idempotencyKey,
    ));
    if (failures-- > 0) throw ApiException('NETWORK_ERROR', '网络中断，请重试');
    return const WmRequisition(
      id: 'r1',
      requestNo: 'ZL-test',
      kind: 'ISSUE',
      status: 'PENDING',
    );
  }
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('wm-line-material-r1')));
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String keyword) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(const Key('wm-request-material-search')),
      matching: find.byType(TextField),
    ),
    keyword,
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('没有整批材料配置也能搜索首次原料，按其克单位直接申请', (tester) async {
    final repo = _RequestRepo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialRequestPanel(
        kind: 'ISSUE',
        workshopId: 'w1',
        workshopName: '注塑车间',
      ),
      repo: repo,
    );
    expect(find.textContaining('请先在基础资料'), findsNothing);
    expect(find.text('选择物料'), findsWidgets);
    await _openPicker(tester);
    await _search(tester, 'RAW-601');
    expect(repo.calls.last.keyword, 'RAW-601');
    await tester.tap(
      find.byKey(const ValueKey('wm-request-material-raw|white')),
    );
    await tester.pumpAndSettle();
    expect(find.text('g'), findsWidgets);
    expect(find.textContaining('每袋'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('wm-line-qty-r1')),
      '12.5',
    );
    await tester.tap(find.byKey(const Key('wm-request-submit')));
    await tester.pumpAndSettle();
    expect(repo.strictReads, 0, reason: '申请不再读取只允许PERIODIC的清单');
    expect(repo.submits, hasLength(1));
    expect(repo.submits.single.workshop, 'w1');
    expect(repo.submits.single.kind, 'ISSUE');
    expect(repo.submits.single.lines.single['goodsId'], 'raw');
    expect(repo.submits.single.lines.single['colorId'], 'white');
    expect(
      repo.submits.single.lines.single['qty'],
      12.5,
      reason: '12.5克不能被当公斤换算',
    );
  });

  testWidgets('提交失败保留所选物料和数量，原样重试复用幂等键', (tester) async {
    final repo = _RequestRepo()..failures = 1;
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialRequestPanel(
        kind: 'ISSUE',
        workshopId: 'w1',
        workshopName: '注塑车间',
        initialMaterialKeys: {'raw|white'},
      ),
      repo: repo,
    );
    await tester.enterText(find.byKey(const ValueKey('wm-line-qty-r1')), '300');
    await tester.tap(find.byKey(const Key('wm-request-submit')));
    await tester.pumpAndSettle();
    expect(find.text('网络中断，请重试'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('wm-line-qty-r1')))
          .controller!
          .text,
      '300',
    );
    await tester.tap(find.byKey(const Key('wm-request-submit')));
    await tester.pumpAndSettle();
    expect(repo.submits, hasLength(2));
    expect(repo.submits[0].key, repo.submits[1].key);
  });

  testWidgets('旧搜索晚返回不能替换新搜索结果', (tester) async {
    final repo = _RequestRepo()
      ..slowSearch = Completer<PagedResult<WmMaterialOption>>();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialRequestPanel(
        kind: 'ISSUE',
        workshopId: 'w1',
        workshopName: '注塑车间',
      ),
      repo: repo,
    );
    await _openPicker(tester);
    final search = find.descendant(
      of: find.byKey(const Key('wm-request-material-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, '旧搜索');
    await tester.pump(const Duration(milliseconds: 350));
    await _search(tester, '新搜索');
    expect(find.text('第二种原料'), findsOneWidget);
    repo.slowSearch!.complete(
      const PagedResult(
        items: [_raw],
        page: 1,
        size: 50,
        total: 1,
        totalPages: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第二种原料'), findsOneWidget);
    expect(find.text(_raw.displayName), findsNothing);
  });
}
