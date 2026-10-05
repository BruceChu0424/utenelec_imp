// 车间内料仓页面 widget 测试共用的假仓储与挂载夹具 (ADR-131, 包 C2)。
//
// 假仓储继承真仓储 (`super(ApiClient(Dio()))`) 并覆写全部用到的方法: 返回预置数据、
// 记录每次调用 (含幂等键), 可按需抛错; 不发任何网络请求。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_material_models.dart';
import 'package:uten_imp/features/warehouse/materialbin/models/workshop_source_warehouse_option.dart';
import 'package:uten_imp/features/warehouse/materialbin/repositories/workshop_material_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

class FakeWorkshopMaterialRepository extends WorkshopMaterialRepository {
  FakeWorkshopMaterialRepository() : super(ApiClient(Dio()));

  // ------------------------------------------------------------ 预置数据
  List<WmSetting> settingsResult = const [];
  List<WmSourceWarehouse> sourceWarehousesResult = wmTestSourceWarehouses;
  Map<String, List<WmPendingProductChoice>> inProgressPendingByWorkshop =
      const {};
  Map<String, List<WmMaterialOption>> materialsByWorkshop = const {};
  Map<String, WmDirectIssueDefaults> defaultsByWorkshop = const {};
  Map<String, List<WmPeriod>> periodsByBin = const {};
  Map<String, WmPosition> positionByBin = const {};
  Map<String, WmCloseStatus> closeStatusByPeriod = const {};
  Map<String, WmPeriod> periodById = const {};
  Map<String, WmCount> countById = const {};
  Map<String, List<WmMachine>> machinesByWorkshop = const {};
  Map<String, WmPreparation> preparationByWorkshop = const {};
  Map<String, WmRequisition> requisitionById = const {};

  // ------------------------------------------------------------ 可注入的失败
  /// 批量开通/撤销先回这一个错误 (如 409 被别人改过), 回完即清掉。
  Object? batchFailureOnce;
  Object? directIssueFailure;
  int directIssueFailuresLeft = 0;

  /// 上线准备保存时先回这一个错误 (如 422 要人确认), 回完即清掉。
  Object? preparationFailureOnce;

  /// 逐行保存时对这些行键 (或容器 id) 回 409; 回完即清掉。
  final Set<String> conflictOnce = {};

  /// 409 之后 count() 返回的最新盘点单 (模拟别人刚改过)。
  WmCount? countAfterConflict;

  // ------------------------------------------------------------ 调用记录
  final directIssues =
      <
        ({
          String workshopId,
          String receiverId,
          List<Map<String, dynamic>> lines,
          WmSupplement? supplement,
          String key,
        })
      >[];

  /// 批量开通 / 开启整批领料 / 改来源仓的每次调用 (含请求号)。
  final batchEnables =
      <
        ({
          List<WmBinItem> items,
          String? sourceWarehouseId,
          bool clearSource,
          bool periodic,
          String? goLiveDate,
          List<WmProductChoiceInput> choices,
          String key,
        })
      >[];

  /// 批量撤销的每次调用。
  final batchDisables = <({List<WmBinItem> items, String key})>[];

  /// 读在产认料时传的车间。
  final pendingRequests = <List<String>>[];
  final savedLines = <WmCountLine>[];
  final zeroRestCalls = <String>[];
  final createMachineCalls =
      <
        ({
          String workshopId,
          int count,
          String prefix,
          int startNo,
          List<({String name, double capacityQty})> containers,
        })
      >[];
  final machineUpdates = <List<Map<String, dynamic>>>[];
  final containerUpdates = <List<Map<String, dynamic>>>[];
  final preparationSaves =
      <({String workshopId, List<Map<String, dynamic>> rows})>[];
  int _version = 100;

  @override
  Future<List<WmSetting>> settings() async => settingsResult;

  @override
  Future<List<WmSourceWarehouse>> sourceWarehouses() async =>
      sourceWarehousesResult;

  /// 多车间按产品去重 (与服务端同一口径), 并带上在产车间名。
  @override
  Future<List<WmPendingProductChoice>> inProgressPending(
    List<String> workshopIds,
  ) async {
    pendingRequests.add(List.of(workshopIds));
    final byProduct = <String, WmPendingProductChoice>{};
    final names = <String, List<String>>{};
    for (final id in workshopIds) {
      final name =
          settingsResult
              .where((s) => s.workshopDepartmentId == id)
              .map((s) => s.workshopName)
              .firstOrNull ??
          id;
      for (final p
          in inProgressPendingByWorkshop[id] ??
              const <WmPendingProductChoice>[]) {
        byProduct.putIfAbsent(p.productGoodsId, () => p);
        names.putIfAbsent(p.productGoodsId, () => []).add(name);
      }
    }
    return [
      for (final p in byProduct.values)
        WmPendingProductChoice(
          productGoodsId: p.productGoodsId,
          productCode: p.productCode,
          productName: p.productName,
          productColorName: p.productColorName,
          taskCount: p.taskCount,
          prefillMaterials: p.prefillMaterials,
          prefillSource: p.prefillSource,
          materialOptions: p.materialOptions,
          unitWeightGrams: p.unitWeightGrams,
          canAlsoOrderMaterials: p.canAlsoOrderMaterials,
          workshopNames: names[p.productGoodsId] ?? const [],
        ),
    ];
  }

  @override
  Future<List<WmSetting>> batchEnable({
    required List<WmBinItem> items,
    String? sourceWarehouseId,
    bool clearSource = false,
    required bool periodic,
    String? goLiveDate,
    List<WmProductChoiceInput> inProgressChoices = const [],
    required String idempotencyKey,
  }) async {
    batchEnables.add((
      items: items,
      sourceWarehouseId: sourceWarehouseId,
      clearSource: clearSource,
      periodic: periodic,
      goLiveDate: goLiveDate,
      choices: inProgressChoices,
      key: idempotencyKey,
    ));
    final failure = batchFailureOnce;
    if (failure != null) {
      batchFailureOnce = null;
      throw failure;
    }
    return [
      for (final item in items)
        WmSetting(
          workshopDepartmentId: item.workshopId,
          workshopName: item.workshopId,
          status: periodic ? WmBinStatus.periodic : WmBinStatus.open,
          periodicEnabled: periodic,
          binWarehouseId: 'bin-${item.workshopId}',
          sourceWarehouseId: sourceWarehouseId,
          rowVersion: item.expectedVersion + 1,
        ),
    ];
  }

  @override
  Future<List<WmSetting>> batchDisable({
    required List<WmBinItem> items,
    required String idempotencyKey,
  }) async {
    batchDisables.add((items: items, key: idempotencyKey));
    final failure = batchFailureOnce;
    if (failure != null) {
      batchFailureOnce = null;
      throw failure;
    }
    return [
      for (final item in items)
        WmSetting(
          workshopDepartmentId: item.workshopId,
          workshopName: item.workshopId,
          status: item.expectedStatus == WmBinStatus.periodic
              ? WmBinStatus.open
              : WmBinStatus.notOpen,
        ),
    ];
  }

  @override
  Future<List<WmMaterialOption>> materials(String workshopId) async =>
      materialsByWorkshop[workshopId] ?? const [];

  @override
  Future<PagedResult<WmMaterialOption>> requestMaterials(
    String workshopId, {
    String keyword = '',
    List<String> goodsIds = const [],
    int page = 1,
    int size = 50,
  }) async {
    final matches =
        (materialsByWorkshop[workshopId] ?? const <WmMaterialOption>[])
            .where(
              (material) =>
                  (goodsIds.isEmpty || goodsIds.contains(material.goodsId)) &&
                  '${material.goodsCode} ${material.displayName}'
                      .toLowerCase()
                      .contains(keyword.toLowerCase()),
            )
            .toList();
    return PagedResult(
      items: matches.skip((page - 1) * size).take(size).toList(),
      page: page,
      size: size,
      total: matches.length,
      totalPages: (matches.length / size).ceil(),
    );
  }

  @override
  Future<WmDirectIssueDefaults> directIssueDefaults(String workshopId) async =>
      defaultsByWorkshop[workshopId] ?? const WmDirectIssueDefaults();

  @override
  Future<List<WmPeriod>> periods(String binId) async =>
      periodsByBin[binId] ?? const [];

  @override
  Future<WmPosition> position(String binId) async =>
      positionByBin[binId] ?? const WmPosition(rows: []);

  @override
  Future<WmCloseStatus> closeStatus(String periodId) async =>
      closeStatusByPeriod[periodId] ??
      const WmCloseStatus(status: 'OPEN', closeState: 'NONE');

  @override
  Future<WmPeriod> period(String periodId) async => periodById[periodId]!;

  @override
  Future<WmCount> count(String countId) async {
    final after = countAfterConflict;
    if (after != null && after.id == countId) return after;
    return countById[countId]!;
  }

  @override
  Future<WmRequisition> requisition(String id) async => requisitionById[id]!;

  @override
  Future<PagedResult<WmRequisition>> requisitions({
    String? status,
    String? kind,
    String? workshopId,
    String? keyword,
    int page = 1,
    int size = 20,
    Map<String, String> scope = const {},
  }) async =>
      const PagedResult(items: [], page: 1, size: 20, total: 0, totalPages: 1);

  @override
  Future<WmIssueResult> directIssue({
    required String workshopDepartmentId,
    required String receiverEmployeeId,
    required List<Map<String, dynamic>> lines,
    WmSupplement? supplement,
    required String idempotencyKey,
  }) async {
    directIssues.add((
      workshopId: workshopDepartmentId,
      receiverId: receiverEmployeeId,
      lines: lines,
      supplement: supplement,
      key: idempotencyKey,
    ));
    if (directIssueFailuresLeft > 0 && directIssueFailure != null) {
      directIssueFailuresLeft--;
      throw directIssueFailure!;
    }
    return const WmIssueResult(
      requestNo: 'ZL20260928000001',
      documents: [WmIssuedDocument(docNo: 'DB001')],
    );
  }

  @override
  Future<WmCountLine> saveCountLine(String countId, WmCountLine line) async {
    savedLines.add(line);
    final containerId = line.containerId;
    if (conflictOnce.remove(line.clientLineKey) ||
        (containerId != null && conflictOnce.remove(containerId))) {
      throw ApiException('CONFLICT', '这一行已被修改', httpStatus: 409);
    }
    return line.copyWith(
      id: line.id ?? 'line-${line.clientLineKey}',
      rowVersion: ++_version,
    );
  }

  @override
  Future<List<WmCountLine>> zeroRest(
    String countId, {
    required String idempotencyKey,
  }) async {
    zeroRestCalls.add(idempotencyKey);
    final count = countById[countId]!;
    return [
      for (final m in count.materials)
        WmCountLine(
          id: 'zero-${m.goodsId}',
          clientLineKey: 'Z:${m.goodsId}',
          lineKind: WmLineKind.weighed,
          goodsId: m.goodsId,
          colorId: m.colorId,
          weighedQty: 0,
          qtyBase: 0,
          rowVersion: 0,
        ),
    ];
  }

  @override
  Future<List<WmMachine>> machines(String workshopId) async =>
      machinesByWorkshop[workshopId] ?? const [];

  @override
  Future<List<WmMachine>> createMachines({
    required String workshopDepartmentId,
    required int count,
    required String codePrefix,
    required int startNo,
    required List<({String name, double capacityQty})> containers,
    required String idempotencyKey,
  }) async {
    createMachineCalls.add((
      workshopId: workshopDepartmentId,
      count: count,
      prefix: codePrefix,
      startNo: startNo,
      containers: containers,
    ));
    return const [];
  }

  @override
  Future<List<WmMachine>> updateMachines(
    List<Map<String, dynamic>> items, {
    required String idempotencyKey,
  }) async {
    machineUpdates.add(items);
    return const [];
  }

  @override
  Future<List<WmMachine>> updateContainers(
    List<Map<String, dynamic>> items, {
    required String idempotencyKey,
  }) async {
    containerUpdates.add(items);
    return const [];
  }

  @override
  Future<WmPreparation> preparation(String workshopId) async =>
      preparationByWorkshop[workshopId] ?? const WmPreparation(rows: []);

  @override
  Future<List<String>> savePreparation(
    String workshopDepartmentId,
    List<Map<String, dynamic>> rows, {
    required String idempotencyKey,
  }) async {
    final failure = preparationFailureOnce;
    if (failure != null) {
      preparationFailureOnce = null;
      throw failure;
    }
    preparationSaves.add((
      workshopId: workshopDepartmentId,
      rows: [for (final r in rows) Map<String, dynamic>.of(r)],
    ));
    return const [];
  }
}

/// 挂载一个内料仓页面: 中文本地化、固定徽章汇总 (不发请求)、假仓储。
Future<void> pumpWorkshopMaterialPage(
  WidgetTester tester,
  Widget page, {
  required FakeWorkshopMaterialRepository repo,
  Size size = const Size(1400, 900),
  double textScale = 1,
  Set<String> permissions = const {Perm.workshopMaterialView},
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
        workshopMaterialRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: page,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------- 数据构造

const wmTestWorkshop = WmSetting(
  workshopDepartmentId: 'w1',
  workshopName: '注塑车间',
  status: WmBinStatus.periodic,
  periodicEnabled: true,
  binWarehouseId: 'bin1',
  binWarehouseName: '注塑车间内料仓',
  mainWarehouseId: 'main1',
  goLiveDate: '2026-09-01',
  rowVersion: 1,
  currentPeriod: WmPeriod(
    id: 'p2',
    periodNo: 2,
    startDate: '2026-09-28',
    status: 'OPEN',
  ),
  allowedActions: ['SETUP'],
);

/// 发料来源仓/出库仓库滑窗的仓库层级 (只有元数据; ADR-147)。
const wmTestSourceWarehouses = [
  WmSourceWarehouse(id: 'main', code: '001', name: '仓库(14年版)'),
  WmSourceWarehouse(
    id: 'leafA',
    code: 'A',
    name: '原料仓 A',
    parentId: 'main',
    selectable: true,
  ),
  WmSourceWarehouse(
    id: 'leafB',
    code: 'B',
    name: '原料仓 B',
    parentId: 'main',
    selectable: true,
  ),
];

const wmTestPp = WmMaterialOption(
  goodsId: 'pp',
  goodsName: 'PP 颗粒',
  goodsCode: 'PP-01',
  unitName: '公斤',
  bulkPackageQty: 25,
  costBasis: 'OWN',
  defaultLeafWarehouseId: 'leafA',
  defaultLeafWarehouseName: '原料仓 A',
  warehouseAvailableQty: 800,
  leafWarehouses: [
    WmLeafStock(
      warehouseId: 'leafA',
      warehouseName: '原料仓 A',
      availableQty: 500,
    ),
    WmLeafStock(
      warehouseId: 'leafB',
      warehouseName: '原料仓 B',
      availableQty: 300,
    ),
  ],
);
