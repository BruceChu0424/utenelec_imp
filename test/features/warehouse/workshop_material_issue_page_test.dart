// 仓库直接发料页 (ADR-131 §5.2, 实现规格 §5.4):
// 袋数↔公斤联动; 同一种料两个出库仓库两行; 领料人默认上一次; 盘点中提示"算到下一期";
// 勾"这批料是上一期漏录的"后出现期间下拉与原因; 失败保留输入、原样重试用同一个请求号。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/models/goods_issue_method.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_issue_method_repository.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_issue_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

import 'workshop_material_test_support.dart';

class _FirstUsePreview implements GoodsIssueMethodRepository {
  bool blocked = false;
  bool missingVersion = false;
  int applyCalls = 0;
  final previews = <({String goodsId, String target, String? costBasis})>[];

  @override
  Future<GoodsIssueMethodPreview> preview(
    String goodsId, {
    required String target,
    String? costBasis,
  }) async {
    previews.add((goodsId: goodsId, target: target, costBasis: costBasis));
    return GoodsIssueMethodPreview(
      goodsId: goodsId,
      goodsName: 'PP 颗粒',
      targetIssueMethod: target,
      targetCostBasis: costBasis,
      currentIssueMethod: 'ORDER',
      version: missingVersion ? null : 17,
      unitName: '公斤',
      canSwitch: !blocked,
      blockers: blocked ? ['还有一张工单未清账'] : const [],
      bomRows: [
        GoodsIssueMethodBomRow(
          productName: '外壳',
          action: blocked
              ? 'BLOCKED'
              : costBasis == 'OWN'
              ? 'CONVERT'
              : 'REMOVE',
          note: blocked ? '这行要先改为按每件' : '这项影响所有使用该料的任务',
        ),
        const GoodsIssueMethodBomRow(productName: '旋钮', action: 'CONVERT'),
      ],
    );
  }

  @override
  Future<void> apply(List<GoodsIssueMethodChange> items) async {
    applyCalls++;
    throw StateError('首次用途不得单独 apply');
  }
}

class _RequestIssueRepository extends FakeWorkshopMaterialRepository {
  _RequestIssueRepository({String kind = 'ISSUE', bool orderMaterial = true}) {
    materialsByWorkshop = const {
      'w1': [wmTestPp],
    };
    requisitionById = {
      'request-1': WmRequisition(
        id: 'request-1',
        requestNo: 'LL-1',
        kind: kind,
        status: 'PENDING',
        workshopDepartmentId: 'w1',
        workshopName: '注塑车间',
        binWarehouseId: 'bin1',
        rowVersion: 3,
        allowedActions: const ['FULFIL'],
        lines: [
          WmRequisitionLine(
            id: 'line-1',
            goodsId: 'pp',
            goodsName: 'PP 颗粒',
            unitName: '公斤',
            requestedQty: 25,
            suggestedLeafWarehouseId: 'leafA',
            issueMethod: orderMaterial ? 'ORDER' : 'PERIODIC',
          ),
        ],
      ),
    };
  }

  int failuresLeft = 0;
  final candidates = <List<String>>[];
  final fulfils =
      <
        ({
          int version,
          List<Map<String, dynamic>> setup,
          List<Map<String, dynamic>> lines,
          String key,
        })
      >[];

  @override
  Future<PagedResult<WmMaterialOption>> requestMaterials(
    String workshopId, {
    String keyword = '',
    List<String> goodsIds = const [],
    int page = 1,
    int size = 50,
  }) async {
    candidates.add(goodsIds);
    return super.requestMaterials(
      workshopId,
      goodsIds: goodsIds,
      page: page,
      size: size,
    );
  }

  @override
  Future<WmIssueResult> fulfil(
    String id, {
    required int expectedVersion,
    required List<Map<String, dynamic>> lines,
    List<Map<String, dynamic>> materialSetup = const [],
    WmSupplement? supplement,
    required String idempotencyKey,
  }) async {
    fulfils.add((
      version: expectedVersion,
      setup: materialSetup,
      lines: lines,
      key: idempotencyKey,
    ));
    if (failuresLeft-- > 0) {
      throw ApiException('STOCK_SHORT', '库存不足，本次未发料也未改变材料用途');
    }
    return const WmIssueResult(requestNo: 'LL-1');
  }
}

Future<void> _mountRequest(
  WidgetTester tester,
  _RequestIssueRepository repo,
  _FirstUsePreview preview, {
  bool canConfigure = true,
}) async {
  final router = GoRouter(
    initialLocation: '/issue',
    routes: [
      GoRoute(
        path: '/issue',
        builder: (_, _) =>
            const WorkshopMaterialIssuePage(requisitionId: 'request-1'),
      ),
      GoRoute(
        path: RouteName.warehouseTasks,
        builder: (_, _) => const Scaffold(body: Text('已返回仓库任务')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await pumpWorkshopMaterialPage(
    tester,
    ProviderScope(
      overrides: [
        goodsIssueMethodRepositoryProvider.overrideWithValue(preview),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
    repo: repo,
    permissions: {
      Perm.workshopMaterialView,
      Perm.workshopMaterialIssue,
      if (canConfigure) ...[Perm.goodsEdit, Perm.goodsBomEdit],
    },
  );
}

Future<void> _confirmFirstUse(WidgetTester tester) async {
  final checkbox = find.byKey(const ValueKey('wm-first-use-confirm-pp'));
  await tester.ensureVisible(checkbox);
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

Future<void> _submitRequest(WidgetTester tester) async {
  final submit = find.byKey(const Key('wm-issue-submit'));
  await tester.ensureVisible(submit);
  await tester.tap(submit);
  await tester.pumpAndSettle();
}

FakeWorkshopMaterialRepository _repo() => FakeWorkshopMaterialRepository()
  ..settingsResult = const [wmTestWorkshop]
  ..materialsByWorkshop = const {
    'w1': [wmTestPp],
  }
  ..defaultsByWorkshop = const {
    'w1': WmDirectIssueDefaults(
      receiverEmployeeId: 'e1',
      receiverName: '张三',
      receiverCode: 'E001',
    ),
  }
  ..periodsByBin = const {
    'bin1': [
      WmPeriod(
        id: 'p1',
        periodNo: 1,
        startDate: '2026-09-01',
        endDate: '2026-09-27',
        status: 'COUNTING',
      ),
      WmPeriod(id: 'p2', periodNo: 2, startDate: '2026-09-28', status: 'OPEN'),
    ],
  };

TextEditingController _controller(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!;

Future<void> _pickMaterial(WidgetTester tester, String rowId) async {
  final field = find.byKey(ValueKey('wm-line-material-$rowId'));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text('PP 颗粒').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('first use previews global BOM impact and sends one atomic '
      'fulfil with the acknowledged material version', (tester) async {
    final repo = _RequestIssueRepository();
    final preview = _FirstUsePreview();
    await _mountRequest(tester, repo, preview);
    expect(repo.candidates.single, ['pp']);
    expect(preview.previews.single.costBasis, 'OWN');
    expect(find.textContaining('影响所有车间和后续任务'), findsOneWidget);
    expect(find.text('关联 BOM 2 行，其中 2 行将调整'), findsOneWidget);
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('wm-issue-submit')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('关联 BOM 2 行，其中 2 行将调整'));
    await tester.pumpAndSettle();
    expect(find.textContaining('外壳：改成只填单个重量'), findsOneWidget);
    expect(find.textContaining('旋钮：改成只填单个重量'), findsOneWidget);
    await _confirmFirstUse(tester);
    expect(preview.applyCalls, 0);
    expect(repo.fulfils, isEmpty);
    await _submitRequest(tester);
    expect(repo.fulfils.single.version, 3);
    expect(repo.fulfils.single.setup, [
      {'goodsId': 'pp', 'expectedVersion': 17, 'periodicCostBasis': 'OWN'},
    ]);
    expect(repo.fulfils.single.lines.single['qty'], 25);
    expect(preview.applyCalls, 0);
    expect(find.text('已返回仓库任务'), findsOneWidget);
  });

  testWidgets('blocked or unversioned preview never enables material setup', (
    tester,
  ) async {
    final repo = _RequestIssueRepository();
    final preview = _FirstUsePreview()..blocked = true;
    await _mountRequest(tester, repo, preview);
    expect(find.textContaining('还有一张工单未清账'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('wm-first-use-confirm-pp')),
          )
          .onChanged,
      isNull,
    );
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('wm-issue-submit')))
          .onPressed,
      isNull,
    );
    preview
      ..blocked = false
      ..missingVersion = true;
    final refresh = find.byKey(const ValueKey('wm-first-use-refresh-pp'));
    await tester.ensureVisible(refresh);
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(find.textContaining('没有读到货品版本'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('wm-first-use-confirm-pp')),
          )
          .onChanged,
      isNull,
    );
    expect(repo.fulfils, isEmpty);
    expect(preview.applyCalls, 0);
  });

  testWidgets(
    'warehouse issue alone cannot confirm the global first-use change',
    (tester) async {
      final repo = _RequestIssueRepository();
      final preview = _FirstUsePreview();
      await _mountRequest(tester, repo, preview, canConfigure: false);
      expect(find.textContaining('需要货品编辑和 BOM 编辑权限'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('wm-first-use-confirm-pp')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('wm-issue-submit')))
            .onPressed,
        isNull,
      );
      expect(repo.fulfils, isEmpty);
    },
  );

  testWidgets('failed fulfil retains acknowledgement and input; retry uses '
      'the same key while a new purpose requires reconfirmation', (
    tester,
  ) async {
    final repo = _RequestIssueRepository()..failuresLeft = 2;
    final preview = _FirstUsePreview();
    await _mountRequest(tester, repo, preview);
    await _confirmFirstUse(tester);
    await _submitRequest(tester);
    expect(find.text('库存不足，本次未发料也未改变材料用途'), findsOneWidget);
    expect(_controller(tester, 'wm-line-qty-r1').text, '25');
    await _submitRequest(tester);
    expect(repo.fulfils[0].key, repo.fulfils[1].key);
    final basis = find.byKey(const ValueKey('wm-first-use-basis-pp'));
    await tester.ensureVisible(basis);
    await tester.tap(basis);
    await tester.pumpAndSettle();
    await tester.tap(find.text('辅料：按主料用量分摊').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('wm-first-use-confirm-pp')),
          )
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('wm-issue-submit')))
          .onPressed,
      isNull,
    );
    await _confirmFirstUse(tester);
    await _submitRequest(tester);
    expect(repo.fulfils.last.setup.single['periodicCostBasis'], 'SHARED');
    expect(repo.fulfils.last.key, isNot(repo.fulfils.first.key));
    expect(preview.applyCalls, 0);
  });

  testWidgets(
    'return receipts keep their original flow without first-use setup',
    (tester) async {
      final repo = _RequestIssueRepository(kind: 'RETURN');
      final preview = _FirstUsePreview();
      await _mountRequest(tester, repo, preview, canConfigure: false);
      expect(
        find.byKey(const ValueKey('wm-first-use-confirm-pp')),
        findsNothing,
      );
      expect(preview.previews, isEmpty);
      expect(repo.candidates, isEmpty);
      await _submitRequest(tester);
      expect(repo.fulfils.single.setup, isEmpty);
      expect(preview.applyCalls, 0);
    },
  );

  testWidgets('领料人默认上一次, 盘点中提示这批料算到下一期', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssuePage(mode: 'direct'),
      repo: repo,
    );

    expect(find.byKey(const Key('wm-issue-counting-hint')), findsOneWidget);
    expect(find.text('已开始盘点, 这批料算到下一期'), findsOneWidget);

    await _pickMaterial(tester, 'r1');
    await tester.enterText(find.byKey(const ValueKey('wm-line-qty-r1')), '50');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();

    expect(repo.directIssues, hasLength(1));
    // 没动领料人: 提交的就是该车间上一次的领料人。
    expect(repo.directIssues.single.receiverId, 'e1');
    expect(repo.directIssues.single.workshopId, 'w1');
    expect(repo.directIssues.single.supplement, isNull);
  });

  testWidgets('袋数与公斤联动, 同一种料从两个仓库出就是两行', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssuePage(mode: 'direct'),
      repo: repo,
    );

    await _pickMaterial(tester, 'r1');
    // 选了料, 出库仓库默认货品归属仓。
    await tester.enterText(find.byKey(const ValueKey('wm-line-bags-r1')), '4');
    await tester.pump();
    expect(_controller(tester, 'wm-line-qty-r1').text, '100');

    // 改公斤反算袋数。
    await tester.enterText(find.byKey(const ValueKey('wm-line-qty-r1')), '60');
    await tester.pump();
    expect(_controller(tester, 'wm-line-bags-r1').text, '2.4');

    // 第二行: 同一种料, 改从原料仓 B 出。
    final addRow = find.text('添加行');
    await tester.ensureVisible(addRow);
    await tester.tap(addRow);
    await tester.pumpAndSettle();
    await _pickMaterial(tester, 'r2');
    final leaf = find.byKey(const ValueKey('wm-line-leaf-r2'));
    await tester.ensureVisible(leaf);
    await tester.tap(leaf);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('原料仓 B').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('wm-line-bags-r2')), '2');
    await tester.pump();
    expect(_controller(tester, 'wm-line-qty-r2').text, '50');

    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();

    expect(repo.directIssues, hasLength(1));
    final lines = repo.directIssues.single.lines;
    expect(lines, hasLength(2));
    expect(lines[0]['leafWarehouseId'], 'leafA');
    expect(lines[0]['qty'], 60);
    expect(lines[0]['bags'], 2.4);
    expect(lines[1]['leafWarehouseId'], 'leafB');
    expect(lines[1]['qty'], 50);
    expect(lines.every((l) => l['goodsId'] == 'pp'), isTrue);
  });

  testWidgets('勾"这批料是上一期漏录的"后出现补到哪一期与原因', (tester) async {
    final repo = _repo();
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssuePage(mode: 'direct'),
      repo: repo,
    );

    expect(find.byKey(const Key('wm-issue-supplement-period')), findsNothing);
    final flag = find.byKey(const Key('wm-issue-supplement'));
    await tester.ensureVisible(flag);
    await tester.tap(flag);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('wm-issue-supplement-period')), findsOneWidget);
    expect(find.byKey(const Key('wm-issue-supplement-reason')), findsOneWidget);
    // 补录时不再提示"算到下一期"。
    expect(find.byKey(const Key('wm-issue-counting-hint')), findsNothing);

    await _pickMaterial(tester, 'r1');
    await tester.enterText(find.byKey(const ValueKey('wm-line-qty-r1')), '25');
    await tester.pump();
    // 没写原因提交被拦住。
    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();
    expect(repo.directIssues, isEmpty);
    expect(find.byKey(const Key('wm-issue-error')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('wm-issue-supplement-reason')),
      '9 月 26 日夜班发的料忘了录',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();

    expect(repo.directIssues, hasLength(1));
    final supplement = repo.directIssues.single.supplement;
    // 只有一期可补 (盘点中那一期), 自动选中。
    expect(supplement?.periodId, 'p1');
    expect(supplement?.reason, '9 月 26 日夜班发的料忘了录');
  });

  testWidgets('失败保留输入, 原样重试用同一个请求号', (tester) async {
    final repo = _repo()
      ..directIssueFailure = ApiException('STOCK_SHORT', '原料仓 A 的 PP 颗粒不够')
      ..directIssueFailuresLeft = 1;
    await pumpWorkshopMaterialPage(
      tester,
      const WorkshopMaterialIssuePage(mode: 'direct'),
      repo: repo,
    );

    await _pickMaterial(tester, 'r1');
    await tester.enterText(find.byKey(const ValueKey('wm-line-qty-r1')), '75');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();

    expect(find.text('原料仓 A 的 PP 颗粒不够'), findsOneWidget);
    expect(_controller(tester, 'wm-line-qty-r1').text, '75');
    expect(_controller(tester, 'wm-line-bags-r1').text, '3');

    await tester.ensureVisible(find.byKey(const Key('wm-issue-submit')));
    await tester.tap(find.byKey(const Key('wm-issue-submit')));
    await tester.pumpAndSettle();

    expect(repo.directIssues, hasLength(2));
    expect(repo.directIssues[1].key, repo.directIssues[0].key);
    // 成功后清空明细, 换新的一行等下一次发料。
    expect(_controller(tester, 'wm-line-qty-r2').text, '');
  });
}
