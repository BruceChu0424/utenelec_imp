import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_mutation_reload_safety.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/core/network/business_precision_coordinator.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';
// 盘点页 (手机优先, ADR-131 §5.7, 实现规格 §5.4):
// 21 台机卡片渲染、满/半/空每台 2 下; "本机停机、全空"; "其余记 0";
// 逐行保存 409 回显最新值; 窄屏 (375) 与大字体无截断。
import 'package:flutter/material.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/inputs/uten_field_message.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/pages/workshop_material_count_page.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/machine_count_card.dart';

import 'workshop_material_test_support.dart';

const _pp = WmCountMaterial(
  goodsId: 'pp',
  goodsName: 'PP 颗粒',
  bulkPackageQty: 25,
);

List<WmCountMachine> _machines(int n) => [
  for (var i = 1; i <= n; i++)
    WmCountMachine(
      machineId: 'm$i',
      name: '$i 号机',
      code: 'ZS$i',
      sortOrder: i,
      lastGoodsId: 'pp',
      containers: [
        WmCountContainer(
          containerId: 'm$i-hopper',
          name: '干燥机料斗',
          capacityQty: 50,
        ),
        WmCountContainer(
          containerId: 'm$i-barrel',
          name: '储料桶',
          capacityQty: 100,
          sortOrder: 1,
        ),
      ],
    ),
];

FakeWorkshopMaterialRepository _repo({int machines = 21}) {
  final count = WmCount(
    id: 'c1',
    periodId: 'p1',
    status: 'DRAFT',
    machines: _machines(machines),
    materials: const [_pp],
    allowedActions: const ['EDIT_COUNT', 'SUBMIT_COUNT'],
  );
  return FakeWorkshopMaterialRepository()
    ..periodById = const {
      'p1': WmPeriod(
        id: 'p1',
        periodNo: 3,
        startDate: '2026-09-01',
        endDate: '2026-09-28',
        status: 'COUNTING',
        currentCountId: 'c1',
        allowedActions: ['WITHDRAW_COUNT'],
      ),
    }
    ..countById = {'c1': count};
}

Set<String>? _selected(WidgetTester tester, String containerId) => tester
    .widget<UtenSegmentRow<String>>(find.byKey(Key('wm-fill-$containerId')))
    .selected;

Future<void> _pumpCount(
  WidgetTester tester,
  Widget page, {
  required FakeWorkshopMaterialRepository repo,
  Size size = const Size(1400, 900),
  double textScale = 1,
  FormDraftStorage? draftStorage,
}) => pumpWorkshopMaterialPage(
  tester,
  page,
  repo: repo,
  size: size,
  textScale: textScale,
  draftStorage: draftStorage,
  permissions: const {Perm.workshopMaterialView, Perm.workshopMaterialCount},
);

class _CountWire extends FakeWorkshopMaterialRepository {
  _CountWire(ApiClient client) : super(client: client);
  @override
  Future<WmCountLine> saveCountLine(String countId, WmCountLine line) =>
      WorkshopMaterialRepository(api).saveCountLine(countId, line);
}

class _CountServer implements HttpClientAdapter {
  final requests = <Map<String, dynamic>>[];
  final headers = <String?>[];
  int writes = 0;
  Map<String, dynamic>? receipt;
  bool lost = false;
  ResponseBody json(Map<String, dynamic> value, int status) =>
      ResponseBody.fromString(
        jsonEncode(value),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(request.data)) as Map),
    );
    final header = request.headers[businessPrecisionHeader] as String?;
    headers.add(header);
    if (header == null) {
      return json({
        'code': 'PRECISION_CHOICE_REQUIRED',
        'message': '请选择本次盘点数量精度',
        'details': {
          'calculationKey': 'workshop.material.count-quantity',
          'groupKey': 'workshop.material.count-quantity',
          'label': '本次车间物料盘点数量',
          'maxScale': 24,
          'reason': 'PRECISION_LIMIT',
          'notWritten': true,
        },
      }, 422);
    }
    receipt ??= {
      ...requests.last,
      'id': 'count-line-original',
      'clientLineKey': request.uri.pathSegments.last,
      'rowVersion': 0,
      'qtyBase': '1.000000000000000000000002',
    };
    if (writes == 0) {
      writes++;
    }
    if (!lost) {
      lost = true;
      throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
        error: 'committed response lost',
      );
    }
    return json(receipt!, 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets('恢复时原盘点行版本变化不静默套用，原输入只读保留', (tester) async {
    final repo = _repo(machines: 0), storage = MemoryFormDraftStorage();
    final original = repo.countById['c1']!;
    WmCount count(int version) => WmCount(
      id: 'c1',
      periodId: 'p1',
      status: 'DRAFT',
      materials: original.materials,
      allowedActions: original.allowedActions,
      lines: [
        WmCountLine(
          id: 'original-row',
          clientLineKey: 'B:pp:-',
          lineKind: WmLineKind.fullBags,
          goodsId: 'pp',
          bagCount: '1',
          bagNetQty: '25',
          qtyBase: '25',
          rowVersion: version,
        ),
      ],
    );
    repo.countById = {'c1': count(2)};
    await _pumpCount(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
      draftStorage: storage,
    );
    final field = find.byKey(const Key('wm-bag-count-pp-'));
    await tester.enterText(field, '1.0e');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WorkshopMaterialCountPage)),
    );
    final draft = container.read(formDraftsProvider).single;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    repo.countById = {'c1': count(3)};
    await _pumpCount(
      tester,
      WorkshopMaterialCountPage(periodId: 'p1', resumeDraftId: draft.id),
      repo: repo,
      draftStorage: storage,
    );
    expect(tester.widget<TextField>(field).controller!.text, '1.0e');
    expect(tester.widget<TextField>(field).enabled, isFalse);
    expect(repo.savedLines, isEmpty);
  });

  testWidgets('500条原数合计与500次半输入不发业务请求，最后原文可硬恢复', (tester) async {
    final repo = _repo(machines: 0), storage = MemoryFormDraftStorage();
    final count = repo.countById['c1']!;
    repo.countById = {
      'c1': WmCount(
        id: count.id,
        periodId: count.periodId,
        status: count.status,
        materials: count.materials,
        allowedActions: count.allowedActions,
        lines: [
          for (var i = 0; i < 500; i++)
            WmCountLine(
              id: 'line$i',
              clientLineKey: 'W:$i',
              lineKind: WmLineKind.weighed,
              goodsId: 'pp',
              weighedQty: '0.000000000000000000000001',
              qtyBase: '0.000000000000000000000001',
              rowVersion: 0,
            ),
        ],
      ),
    };
    await _pumpCount(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
      draftStorage: storage,
      size: const Size(1400, 1200),
    );
    expect(find.text('合计 0.0000000000000000000005 公斤'), findsOneWidget);
    final field = find.byKey(const Key('wm-bag-count-pp-'));
    await tester.showKeyboard(field);
    for (var i = 0; i < 500; i++) {
      tester.testTextInput.enterText('1.${i}e');
      await tester.idle();
    }
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(repo.savedLines, isEmpty);
    expect(tester.takeException(), isNull);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WorkshopMaterialCountPage)),
    );
    final draft = container.read(formDraftsProvider).single;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _pumpCount(
      tester,
      WorkshopMaterialCountPage(periodId: 'p1', resumeDraftId: draft.id),
      repo: repo,
      draftStorage: storage,
      size: const Size(1400, 1200),
    );
    expect(tester.widget<TextField>(field).controller!.text, '1.499e');
    expect(repo.savedLines, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('半输入原文硬关闭后仍从私有盘点草稿恢复，不自动保存业务行', (tester) async {
    final storage = MemoryFormDraftStorage(), repo = _repo(machines: 0);
    await _pumpCount(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
      draftStorage: storage,
    );
    final field = find.byKey(const Key('wm-bag-count-pp-'));
    await tester.enterText(field, '1.0e');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WorkshopMaterialCountPage)),
    );
    final draft = container.read(formDraftsProvider).single;
    expect(draft.data['inputs'], contains('bags:pp|'));
    expect(repo.savedLines, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _pumpCount(
      tester,
      WorkshopMaterialCountPage(periodId: 'p1', resumeDraftId: draft.id),
      repo: repo,
      draftStorage: storage,
    );
    expect(tester.widget<TextField>(field).controller!.text, '1.0e');
    expect(repo.savedLines, isEmpty);
  });

  testWidgets('真实HTTP精度选择后已写响应丢失，硬恢复只重放原body和header，新输入另留草稿', (tester) async {
    final storage = MemoryFormDraftStorage(),
        server = _CountServer(),
        coordinator = BusinessPrecisionCoordinator();
    var prompts = 0;
    addTearDown(
      coordinator.register((requirement) async {
        prompts++;
        return const BusinessPrecisionChoice(24, 'DOWN');
      }),
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://warehouse.test/api'))
      ..httpClientAdapter = server;
    final repo = _CountWire(
      ApiClient(
        dio,
        precisionCoordinator: coordinator,
        reloadSafety: ApiMutationReloadSafety(
          registry: WebUpdateSafetyRegistry(),
        ),
      ),
    );
    final source = _repo(machines: 0);
    repo.periodById = source.periodById;
    repo.countById = source.countById;
    await _pumpCount(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
      draftStorage: storage,
    );
    const raw = '1.000000000000000000000001';
    await tester.enterText(find.byKey(const Key('wm-bag-net-pp-')), raw);
    await tester.enterText(find.byKey(const Key('wm-bag-count-pp-')), raw);
    await tester.tap(find.byKey(const Key('wm-bag-save-pp-')));
    await tester.pumpAndSettle();
    expect(server.writes, 1);
    expect(prompts, 1);
    expect(server.requests, hasLength(2));
    final body = Map<String, dynamic>.from(server.requests.last),
        header = server.headers.last;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(WorkshopMaterialCountPage)),
    );
    final draft = container.read(formDraftsProvider).single;
    expect(draft.hasUnknownSubmission, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _pumpCount(
      tester,
      WorkshopMaterialCountPage(periodId: 'p1', resumeDraftId: draft.id),
      repo: repo,
      draftStorage: storage,
    );
    await tester.enterText(find.byKey(const Key('wm-bag-count-pp-')), '2');
    await tester.tap(find.byKey(const Key('wm-count-retry-original-lines')));
    await tester.pumpAndSettle();
    expect(server.requests, hasLength(3));
    expect(server.requests.last, body);
    expect(server.headers.last, header);
    expect(prompts, 1);
    expect(server.writes, 1);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('wm-bag-count-pp-')))
          .controller!
          .text,
      '2',
    );
    expect(
      find.byKey(const Key('wm-count-retry-original-lines')),
      findsNothing,
    );
  });

  test('盘点原始十进制在读取和保存端口不经过 double', () {
    const value =
        '1234567890123456789012345678901234567890.123456789012345678901234';
    final line = WmCountLine.fromJson({
      'clientLineKey': 'EXACT',
      'lineKind': 'FULL_BAGS',
      'bagCount': value,
      'bagNetQty': '0.000000000000000000000001',
      'qtyBase': '1234567890123456.789012345678901234567890',
    });
    expect(line.bagCount, value);
    expect(line.toSaveJson()['bagCount'], value);
    expect(line.copyWith(rowVersion: 2).toSaveJson()['bagCount'], value);
    expect(line.bagNetQty, '0.000000000000000000000001');
  });

  testWidgets('袋数和每袋净重 24 位原文保存，有限乘积保全，超界不发请求且留输入', (tester) async {
    final repo = _repo(machines: 0);
    await _pumpCount(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
      size: const Size(1400, 1600),
    );
    final bags = find.byKey(const Key('wm-bag-count-pp-'));
    final net = find.byKey(const Key('wm-bag-net-pp-'));
    expect(bags, findsOneWidget);
    await tester.enterText(net, '2');
    await tester.enterText(bags, '1.000000000000000000000001');
    await tester.tap(find.byKey(const Key('wm-bag-save-pp-')));
    await tester.pumpAndSettle();
    final line = repo.savedLines.last;
    expect(line.toSaveJson()['bagCount'], '1.000000000000000000000001');
    expect(line.toSaveJson()['bagNetQty'], '2');
    expect(line.qtyBase, '2.000000000000000000000002');
    final saved = repo.savedLines.length;
    await tester.enterText(bags, '0.0000000000000000000000001');
    await tester.tap(find.byKey(const Key('wm-bag-save-pp-')));
    await tester.pumpAndSettle();
    expect(repo.savedLines, hasLength(saved));
    expect(
      tester.widget<TextField>(bags).controller!.text,
      '0.0000000000000000000000001',
    );
    final decoration =
        tester.widget<TextField>(bags).decoration as UtenInputDecoration;
    expect(decoration.base.error, isA<UtenFieldMessage>());
    final error = decoration.base.error! as UtenFieldMessage;
    expect(error.kind, UtenFieldMessageKind.error);
    expect(error.message, contains('最多 40 位整数、24 位小数'));
    final hint = find.descendant(
      of: bags,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is UtenFieldHintIcon && widget.errorMessage == error.message,
      ),
    );
    expect(hint, findsOneWidget);
    await tester.ensureVisible(hint);
    await tester.tap(hint.hitTestable());
    await tester.pump();
    expect(find.textContaining('最多 40 位整数、24 位小数'), findsOneWidget);
    expect(repo.savedLines, hasLength(saved));
  });

  testWidgets('周期盘点录入与审核按钮分权，审核者不能修改草稿行', (tester) async {
    final repo = _repo(machines: 1);
    final base = repo.countById['c1']!;
    repo.countById['c1'] = WmCount(
      id: base.id,
      periodId: base.periodId,
      status: 'DRAFT',
      machines: base.machines,
      materials: base.materials,
      allowedActions: const ['SUBMIT_COUNT'],
    );
    await _pumpCount(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
    );
    expect(find.text('审核盘点并过账'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byKey(const Key('wm-count-submit')),
        matching: find.byType(UtenFloatingActionGroup),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Scaffold>(find.byType(Scaffold).first)
          .floatingActionButtonLocation,
      FloatingActionButtonLocation.endFloat,
    );
    expect(find.byKey(const Key('wm-count-zero-rest')), findsNothing);
    expect(
      tester.widget<MachineCountCard>(find.byType(MachineCountCard)).enabled,
      isFalse,
    );
  });

  testWidgets('21 台机卡片都在, 每台点 2 下就录完', (tester) async {
    final repo = _repo();
    await _pumpCount(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
      // 两列卡片一屏放下全部 21 台 (ListView 只建可见的卡)。
      size: const Size(1400, 5000),
    );

    expect(find.byType(MachineCountCard), findsNWidgets(21));
    expect(find.text('已录 0 / 42 个容器, 0 / 1 种袋料'), findsOneWidget);

    for (var i = 1; i <= 21; i++) {
      await tester.tap(find.byKey(Key('wm-fill-m$i-hopper-FULL')));
      await tester.tap(find.byKey(Key('wm-fill-m$i-barrel-HALF')));
    }
    await tester.pumpAndSettle();

    // 在用料默认上次, 所以每台只点两下: 21 × 2 = 42 次逐行保存。
    expect(repo.savedLines, hasLength(42));
    expect(repo.savedLines.every((l) => l.goodsId == 'pp'), isTrue);
    expect(
      repo.savedLines.where((l) => l.fillLevel == WmFillLevel.full),
      hasLength(21),
    );
    expect(
      repo.savedLines.where((l) => l.fillLevel == WmFillLevel.half),
      hasLength(21),
    );
    expect(find.text('已录 42 / 42 个容器, 0 / 1 种袋料'), findsOneWidget);
    expect(_selected(tester, 'm7-barrel'), {WmFillLevel.half});
  });

  testWidgets('本机停机、全空一键记两个空容器; 其余料记 0', (tester) async {
    final repo = _repo(machines: 2);
    await _pumpCount(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
    );

    await tester.tap(find.byKey(const Key('wm-machine-idle-m1')));
    await tester.pumpAndSettle();
    expect(repo.savedLines, hasLength(2));
    expect(
      repo.savedLines.every(
        (l) => l.fillLevel == WmFillLevel.empty && l.machineId == 'm1',
      ),
      isTrue,
    );
    expect(_selected(tester, 'm1-hopper'), {WmFillLevel.empty});
    expect(_selected(tester, 'm1-barrel'), {WmFillLevel.empty});

    final zero = find.byKey(const Key('wm-count-zero-rest'));
    await tester.ensureVisible(zero);
    await tester.tap(zero);
    await tester.pumpAndSettle();
    expect(repo.zeroRestCalls, hasLength(1));
    expect(find.textContaining('1 / 1 种袋料'), findsOneWidget);
  });

  testWidgets('逐行保存撞上别人刚改过 (409): 重拉并显示最新的数', (tester) async {
    final repo = _repo(machines: 2);
    final base = repo.countById['c1']!;
    repo
      ..conflictOnce.add('m1-hopper')
      ..countAfterConflict = WmCount(
        id: 'c1',
        periodId: 'p1',
        status: 'DRAFT',
        machines: base.machines,
        materials: base.materials,
        allowedActions: base.allowedActions,
        lines: const [
          WmCountLine(
            id: 'l-other',
            clientLineKey: 'C:m1-hopper',
            lineKind: WmLineKind.container,
            goodsId: 'pp',
            machineId: 'm1',
            containerId: 'm1-hopper',
            capacityQtySnapshot: 50,
            fillLevel: WmFillLevel.half,
            qtyBase: 25,
            rowVersion: 3,
          ),
        ],
      );
    await _pumpCount(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
    );

    await tester.tap(find.byKey(const Key('wm-fill-m1-hopper-FULL')));
    await tester.pumpAndSettle();

    expect(repo.savedLines, hasLength(1));
    // 页面回显的是别人刚存的"半", 不是自己点的"满"。
    expect(_selected(tester, 'm1-hopper'), {WmFillLevel.half});
    expect(find.byKey(const Key('wm-container-qty-m1-hopper')), findsOneWidget);
    expect(find.text('≈ 25 公斤'), findsOneWidget);
    expect(
      find.byKey(const Key('wm-container-error-m1-hopper')),
      findsOneWidget,
    );
  });

  testWidgets('机桶估盘显示约数，直接填公斤保存称重来源和残料量', (tester) async {
    final repo = _repo(machines: 1);
    await _pumpCount(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
    );
    expect(find.textContaining('仅用于确实无料'), findsNothing);
    await tester.tap(find.byKey(const Key('wm-count-help')));
    await tester.pumpAndSettle();
    expect(find.textContaining('仅用于确实无料'), findsOneWidget);
    Tooltip.dismissAllToolTips();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wm-fill-m1-hopper-HALF')));
    await tester.pumpAndSettle();
    expect(find.text('≈ 25 公斤'), findsOneWidget);
    expect(find.text('容器估盘，按容量折算'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wm-fill-m1-hopper-weigh')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('wm-weigh-m1-hopper')), '8.25');
    await tester.tap(find.byKey(const Key('wm-weigh-save-m1-hopper')));
    await tester.pumpAndSettle();
    final saved = repo.savedLines.last;
    expect(saved.fillLevel, WmFillLevel.weighed);
    expect(saved.weighedQty, '8.25');
    expect(saved.qtyBase, '8.25');
    expect(find.text('8.25 公斤'), findsOneWidget);
    expect(find.text('称重/公斤录入'), findsOneWidget);
    expect(find.text('≈ 25 公斤'), findsNothing);
  });

  testWidgets('窄屏 375 + 大字体: 卡片不截断、不溢出', (tester) async {
    final repo = _repo(machines: 3);
    await _pumpCount(
      tester,
      const WorkshopMaterialCountPage(periodId: 'p1'),
      repo: repo,
      size: const Size(375, 812),
      textScale: 1.3,
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(MachineCountCard), findsWidgets);
    // 一路滚到底, 途经的每张卡与袋料卡都不能溢出。
    await tester.drag(
      find.byKey(const Key('wm-count-list')),
      const Offset(0, -2400),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('wm-count-submit')), findsOneWidget);
  });
}
