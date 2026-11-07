import '../../support/table_read_status.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pump_until.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_request_dialog.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_request_material_picker.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

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
  Future<PagedResult<WmMaterialOption>> Function(int page)? pagedResponse;

  @override
  Future<List<WmMaterialOption>> materials(String workshopId) async {
    strictReads++;
    return const [];
  }

  @override
  Future<PagedResult<WmMaterialOption>> requestMaterials(
    String workshopId, {
    String keyword = '',
    String? categoryId,
    bool includeRelated = false,
    List<String> goodsIds = const [],
    int page = 1,
    int size = 50,
  }) async {
    expectSync(workshopId, 'w1');
    calls.add((keyword: keyword, page: page, goodsIds: goodsIds));
    if (pagedResponse != null) return pagedResponse!(page);
    if (keyword == '失败搜索') throw ApiException('FORBIDDEN', '申请范围已变化');
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
  for (final multi in [false, true]) {
    for (final defect in ['duplicate identity', 'scope drift']) {
      testWidgets(
        'complete workshop candidates reject $defect (multi=$multi)',
        (tester) async {
          var defective = true;
          final repo = _RequestRepo()
            ..pagedResponse = (page) async => PagedResult(
              items: [
                page == 1 || (defective && defect == 'duplicate identity')
                    ? _raw
                    : _later,
              ],
              page: page,
              size: 1,
              total: 2,
              totalPages: 2,
              readScopeVersion:
                  defective && defect == 'scope drift' && page == 2
                  ? 'request-v2'
                  : 'request-v1',
            );
          final selected = <List<WmMaterialOption>>[];
          await pumpWorkshopMaterialPage(
            tester,
            multi
                ? Consumer(
                    builder: (context, ref, _) => Scaffold(
                      body: TextButton(
                        onPressed: () async => selected.add(
                          await showWorkshopRequestMaterialPickerMulti(
                            context,
                            ref,
                            workshopId: 'w1',
                            workshopName: '注塑车间',
                          ),
                        ),
                        child: const Text('打开物料'),
                      ),
                    ),
                  )
                : _pickerButton((value) => selected.add([?value])),
            repo: repo,
          );
          await tester.tap(find.text('打开物料'));
          await tester.pumpAndSettle();
          if (multi) {
            final tree = find.byType(UtenCategoryTreeView<ProductCategoryNode>);
            if (!tester.any(tree)) {
              await tester.tap(find.byIcon(Icons.account_tree_rounded));
              await tester.pumpAndSettle();
            }
            await tester.tap(
              find.descendant(of: tree, matching: find.text('物料')),
            );
            await tester.pumpAndSettle();
          }
          MasterDataTableView<dynamic> table() => tester.widget(
            find.byWidgetPredicate(
              (widget) => widget is MasterDataTableView<dynamic>,
            ),
          );
          expect(table().items, isEmpty);
          expect(table().error, isNotNull);
          final confirm = find.byKey(
            Key(
              multi
                  ? 'goods-picker-multi-confirm'
                  : 'wm-request-material-confirm',
            ),
          );
          expect(tester.widget<UtenButton>(confirm).onPressed, isNull);
          expect(selected, isEmpty);
          defective = false;
          table().onRetry!();
          await tester.pumpAndSettle();
          expect(
            table().items,
            hasLength(2),
            reason: 'retry error=${table().error}; calls=${repo.calls}',
          );
          expect(table().error, isNull);
          await tester.tap(
            find.byKey(
              ValueKey(
                multi
                    ? 'goods-picker-item-raw|white'
                    : 'wm-request-material-raw|white',
              ),
            ),
          );
          await tester.pump();
          await tester.tap(confirm);
          await tester.pumpAndSettle();
          expect(selected.single.single, same(_raw));
          expect(repo.strictReads, 0);
          expect(repo.submits, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
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
    final table = tester.widget<MasterDataTableView<WmMaterialOption>>(
      find.byType(MasterDataTableView<WmMaterialOption>),
    );
    expect(table.columns.map((column) => column.label), [
      '物料名称',
      '编号',
      '颜色',
      '仓库可发',
    ]);
    expect(table.tableKey, isNull);
    expect(find.text('800 g'), findsOneWidget);
    expect(
      tester.getSize(find.byType(MasterDataTableView<WmMaterialOption>)).height,
      greaterThan(200),
      reason: 'Scaffold底部确认栏不能占满高度挤掉候选表格',
    );
    await tester.tap(
      find.byKey(const ValueKey('wm-request-material-raw|white')),
    );
    await tester.pumpAndSettle();
    expect(find.text('选择申请物料'), findsOneWidget);
    expect(repo.submits, isEmpty);
    await tester.tap(find.byKey(const Key('wm-request-material-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('g'), findsWidgets);
    final requestHint = find.byWidgetPredicate(
      (widget) =>
          widget is UtenFieldHintIcon && (widget.info?.contains('每袋') ?? false),
    );
    await tester.tap(requestHint);
    await tester.pumpAndSettle();
    expect(find.textContaining('每袋'), findsWidgets);
    Tooltip.dismissAllToolTips();
    await tester.pumpAndSettle();
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

  for (final dismissal in ['取消', '关闭', '遮罩']) {
    testWidgets('申请物料暂选后$dismissal不回填', (tester) async {
      final results = <WmMaterialOption?>[];
      await pumpWorkshopMaterialPage(
        tester,
        _pickerButton(results.add),
        repo: _RequestRepo(),
      );
      await tester.tap(find.text('打开物料'));
      await tester.pumpAndSettle();
      await _search(tester, 'RAW-601');
      await tester.tap(
        find.byKey(const ValueKey('wm-request-material-raw|white')),
      );
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(
        tester
            .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
            .selectedCount,
        1,
      );
      if (dismissal == '遮罩') {
        await tester.tapAt(const Offset(20, 400));
      } else if (dismissal == '关闭') {
        await tester.tap(find.byTooltip('关闭'));
      } else {
        await tester.tap(find.text('取消'));
      }
      await tester.pumpAndSettle();
      expect(results, [null]);
    });
  }

  testWidgets('搜索改变立即作废物料暂选与旧确认，失败后不能回填', (tester) async {
    final results = <WmMaterialOption?>[];
    await pumpWorkshopMaterialPage(
      tester,
      _pickerButton(results.add),
      repo: _RequestRepo(),
    );
    await tester.tap(find.text('打开物料'));
    await tester.pumpAndSettle();
    await _search(tester, 'RAW-601');
    final row = find.byKey(const ValueKey('wm-request-material-raw|white'));
    final table = tester.widget<MasterDataTableView<WmMaterialOption>>(
      find.byType(MasterDataTableView<WmMaterialOption>),
    );
    final oldMaterial = table.items.singleWhere(
      (item) => item.key == 'raw|white',
    );
    void oldSelect() => table.onRowTap!(oldMaterial);
    await tester.tap(row);
    await tester.pumpAndSettle();
    final oldConfirm = tester
        .widget<UtenButton>(
          find.byKey(const Key('wm-request-material-confirm')),
        )
        .onPressed!;
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('wm-request-material-search')),
        matching: find.byType(TextField),
      ),
      '失败搜索',
    );
    oldSelect();
    oldConfirm();
    await tester.pump();
    expect(results, isEmpty);
    expect(
      tester
          .widget<UtenButton>(
            find.byKey(const Key('wm-request-material-confirm')),
          )
          .onPressed,
      isNull,
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await expectTableReadFailureDetails(tester, '申请范围已变化');
    expect(
      tester
          .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
          .selectedCount,
      0,
    );
    await _search(tester, '新搜索');
    await tester.tap(find.byKey(const ValueKey('wm-request-material-later|')));
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    await tester.tap(find.byKey(const Key('wm-request-material-confirm')));
    await tester.pumpAndSettle();
    expect(results.single?.goodsId, 'later');
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

  testWidgets('权限变化清除申请物料暂选，旧行与旧确认不能回填', (tester) async {
    final permissions = StateProvider<Set<String>>(
      (ref) => {Perm.workshopMaterialView},
    );
    final results = <WmMaterialOption?>[];
    final repo = _RequestRepo();
    await pumpWorkshopMaterialPage(
      tester,
      _pickerButton(results.add),
      repo: repo,
      permissionState: permissions,
    );
    await tester.tap(find.text('打开物料'));
    await tester.pumpAndSettle();
    await _search(tester, 'RAW-601');
    final row = find.byKey(const ValueKey('wm-request-material-raw|white'));
    final table = tester.widget<MasterDataTableView<WmMaterialOption>>(
      find.byType(MasterDataTableView<WmMaterialOption>),
    );
    final oldMaterial = table.items.singleWhere(
      (item) => item.key == 'raw|white',
    );
    void oldSelect() => table.onRowTap!(oldMaterial);
    await tester.tap(row);
    await tester.pumpAndSettle();
    final oldConfirm = tester
        .widget<UtenButton>(
          find.byKey(const Key('wm-request-material-confirm')),
        )
        .onPressed!;
    final container = ProviderScope.containerOf(
      tester.element(row),
      listen: false,
    );
    final denied = Completer<PagedResult<WmMaterialOption>>();
    repo.pagedResponse = (_) => denied.future;
    final previousReads = repo.calls.length;
    container.read(permissions.notifier).state = {};
    oldSelect();
    oldConfirm();
    await pumpUntil(
      tester,
      () => repo.calls.length > previousReads,
      reason: 'The replacement scope must be checked by the server',
    );
    expect(row, findsNothing);
    denied.completeError(ApiException('FORBIDDEN', '没有查看权限', httpStatus: 403));
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(row, findsNothing);
    await expectTableReadFailureDetails(tester, '没有查看权限');
    expect(
      tester
          .widget<UtenButton>(
            find.byKey(const Key('wm-request-material-confirm')),
          )
          .onPressed,
      isNull,
    );
  });

  for (final scenario in ['refresh', 'scope change', 'forbidden']) {
    testWidgets('申请物料完整候选维护原暂选与读取退休：$scenario', (tester) async {
      final repo = _RequestRepo();
      Completer<PagedResult<WmMaterialOption>>? held;
      PagedResult<WmMaterialOption> response(int page) => PagedResult(
        items: page == 1
            ? [
                _raw,
                for (var index = 1; index < 30; index++)
                  WmMaterialOption(
                    goodsId: 'first-$index',
                    goodsName: '候选原料 $index',
                  ),
              ]
            : [_later],
        page: page,
        size: 30,
        total: 31,
        totalPages: 2,
        readScopeVersion: 'request-v1',
      );
      repo.pagedResponse = (page) async {
        if (repo.calls.last.keyword == '新搜索') {
          return const PagedResult(
            items: [_later],
            page: 1,
            size: 30,
            total: 1,
            totalPages: 1,
            readScopeVersion: 'request-new-query',
          );
        }
        if (page == 2 && held != null) return held.future;
        return response(page);
      };
      final results = <WmMaterialOption?>[];
      await pumpWorkshopMaterialPage(
        tester,
        _pickerButton(results.add),
        repo: repo,
      );
      await tester.tap(find.text('打开物料'));
      await tester.pumpAndSettle();
      final tableFinder = find.byType(MasterDataTableView<WmMaterialOption>);
      MasterDataTableView<WmMaterialOption> table() =>
          tester.widget(tableFinder);
      expect(table().items, hasLength(31));
      expect(repo.calls.map((call) => call.page), [1, 2]);
      expect(
        find.byKey(const ValueKey('master-table-page-next')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('wm-request-material-raw|white')),
      );
      await tester.pumpAndSettle();
      final previousRows = table().items;
      final beforeRefresh = repo.calls.length;
      held = Completer<PagedResult<WmMaterialOption>>();
      table().onRetry!();
      for (
        var frame = 0;
        frame < 30 && repo.calls.length < beforeRefresh + 2;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(repo.calls.skip(beforeRefresh).map((call) => call.page), [1, 2]);
      expect(table().items, same(previousRows));
      final confirm = find.byKey(const Key('wm-request-material-confirm'));
      expect(
        tester
            .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
            .selectedCount,
        1,
      );
      expect(tester.widget<UtenButton>(confirm).onPressed, isNull);
      expect(results, isEmpty);
      if (scenario == 'scope change') {
        await _search(tester, '新搜索');
        expect(table().items, [_later]);
        expect(
          tester
              .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
              .selectedCount,
          0,
        );
        await tester.tap(
          find.byKey(const ValueKey('wm-request-material-later|')),
        );
        await tester.pump();
        held.complete(response(2));
        held = null;
        await tester.pumpAndSettle();
        expect(table().items, [_later]);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(results.single, same(_later));
      } else if (scenario == 'forbidden') {
        held.completeError(ApiException('FORBIDDEN', '候选范围已变化'));
        held = null;
        await tester.pumpAndSettle();
        expect(table().items, isEmpty);
        expect(
          tester
              .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
              .selectedCount,
          0,
        );
        expect(tester.widget<UtenButton>(confirm).onPressed, isNull);
        expect(results, isEmpty);
      } else {
        held.complete(response(2));
        held = null;
        await tester.pumpAndSettle();
        expect(table().items, hasLength(31));
        final reads = repo.calls.length;
        await tester.dragUntilVisible(
          find.byKey(const ValueKey('wm-request-material-later|')),
          tableFinder,
          const Offset(0, -350),
        );
        await tester.pumpAndSettle();
        expect(
          find
              .byKey(const ValueKey('wm-request-material-later|'))
              .hitTestable(),
          findsOneWidget,
        );
        await tester.dragUntilVisible(
          find.byKey(const ValueKey('wm-request-material-raw|white')),
          tableFinder,
          const Offset(0, 350),
        );
        await tester.pumpAndSettle();
        expect(repo.calls, hasLength(reads));
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(results.single, same(_raw));
      }
      expect(repo.strictReads, 0);
      expect(repo.submits, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

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
    expect(
      find.byKey(const ValueKey('wm-request-material-raw|white')),
      findsNothing,
    );
  });
}

Widget _pickerButton(ValueChanged<WmMaterialOption?> onSelected) => Builder(
  builder: (context) => Scaffold(
    body: TextButton(
      onPressed: () async => onSelected(
        await showWorkshopRequestMaterialPicker(context, workshopId: 'w1'),
      ),
      child: const Text('打开物料'),
    ),
  ),
);
