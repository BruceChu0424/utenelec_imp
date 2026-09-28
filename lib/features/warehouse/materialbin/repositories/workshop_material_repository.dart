// 车间内料仓 (ADR-131) 仓储: 设置、机台与容器、领料 / 退回 / 其它耗用、
// 期间与盘点、自动结算状态、上线准备。
//
// 写接口都带 idempotencyKey (8-128 位, 由 [wmIdempotencyKey] 按"页面会话 + 请求内容"
// 派生: 失败后原样重试是同一个键, 服务端按键去重; 改了内容就是新键) 与 expectedVersion。
// 具体类 (非抽象接口): widget 测试以 `super(ApiClient(Dio()))` 继承后覆写各方法。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/utils/idempotency_key.dart';
import '../../../../shared/models/paged_result.dart';
import '../models/workshop_material_models.dart';

/// 一次用户动作的幂等键: `wm-<动作>-<16 位指纹>`; [nonce] 为页面 (或对话框) 会话随机串。
String wmIdempotencyKey(String action, String nonce, Object? payload) =>
    businessIdempotencyKey('wm-$action', '$nonce|${jsonEncode(payload)}');

/// 补录到上一期 (漏录的发料): 补到哪一期 + 原因。
class WmSupplement {
  const WmSupplement({required this.periodId, required this.reason});

  final String periodId;
  final String reason;

  Map<String, dynamic> toJson() => {'periodId': periodId, 'reason': reason};
}

class WorkshopMaterialRepository {
  WorkshopMaterialRepository(this.api);

  final ApiClient api;

  // ---------------------------------------------------------------- 设置

  /// 各车间的整批领料设置 (车间成员只看到本车间)。
  Future<List<WmSetting>> settings() async {
    final list = await api.getList(ApiEndpoints.workshopMaterialSettings);
    return list.map(WmSetting.fromJson).toList(growable: false);
  }

  /// 开启 / 停用整批领料 (一个原子命令; 开启时同一事务写在产产品的认料)。
  Future<WmSetting> saveSetting(
    String workshopId, {
    required int expectedVersion,
    required bool enabled,
    String? mainWarehouseId,
    String? goLiveDate,
    List<WmProductChoiceInput> inProgressChoices = const [],
    required String idempotencyKey,
  }) async {
    final json = await api.put(
      ApiEndpoints.workshopMaterialSetting(workshopId),
      body: {
        'expectedVersion': expectedVersion,
        'enabled': enabled,
        'mainWarehouseId': mainWarehouseId,
        'goLiveDate': goLiveDate,
        'inProgressChoices': [for (final c in inProgressChoices) c.toJson()],
        'idempotencyKey': idempotencyKey,
      },
    );
    return WmSetting.fromJson(json);
  }

  /// 开启前本车间在产、需要认料的产品 (含预填)。
  Future<List<WmPendingProductChoice>> inProgressPending(
    String workshopId,
  ) async {
    // 服务端回 {products:[...]}。
    final json = await api.get(
      ApiEndpoints.workshopMaterialSettingInProgressPending(workshopId),
    );
    return _listIn(
      json,
      'products',
    ).map(WmPendingProductChoice.fromJson).toList(growable: false);
  }

  // ---------------------------------------------------------------- 机台与容器

  Future<List<WmMachine>> machines(String workshopId) async {
    final json = await api.get(
      ApiEndpoints.workshopMaterialMachines,
      query: {'workshopId': workshopId},
    );
    return _machinesIn(json);
  }

  /// 批量新增机台 (如 21 台, 每台料斗 50 + 储料桶 100)。
  Future<List<WmMachine>> createMachines({
    required String workshopDepartmentId,
    required int count,
    required String codePrefix,
    required int startNo,
    required List<({String name, double capacityQty})> containers,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.workshopMaterialMachinesBatch,
      body: {
        'workshopDepartmentId': workshopDepartmentId,
        'count': count,
        'codePrefix': codePrefix,
        'startNo': startNo,
        'containers': [
          for (final c in containers)
            {'name': c.name, 'capacityQty': c.capacityQty},
        ],
        'idempotencyKey': idempotencyKey,
      },
    );
    return _machinesIn(json);
  }

  /// 批量改机台 (勾选多行改一格即批量生效后一次提交)。
  Future<List<WmMachine>> updateMachines(
    List<Map<String, dynamic>> items, {
    required String idempotencyKey,
  }) async {
    final json = await api.put(
      ApiEndpoints.workshopMaterialMachinesBatch,
      body: {'items': items, 'idempotencyKey': idempotencyKey},
    );
    return _machinesIn(json);
  }

  /// 批量改 / 补容器 (id 为空 = 给这台机新增一个容器)。
  Future<List<WmMachine>> updateContainers(
    List<Map<String, dynamic>> items, {
    required String idempotencyKey,
  }) async {
    final json = await api.put(
      ApiEndpoints.workshopMaterialContainersBatch,
      body: {'items': items, 'idempotencyKey': idempotencyKey},
    );
    return _machinesIn(json);
  }

  /// 删除机台; 盘点用过的服务端回 409 "只能停用"。
  Future<void> deleteMachine(String id, {required int expectedVersion}) =>
      api.delete(
        '${ApiEndpoints.workshopMaterialMachine(id)}'
        '?expectedVersion=$expectedVersion',
      );

  Future<void> deleteContainer(String id, {required int expectedVersion}) =>
      api.delete(
        '${ApiEndpoints.workshopMaterialContainer(id)}'
        '?expectedVersion=$expectedVersion',
      );

  // ---------------------------------------------------------------- 料与现存

  /// 可发到该车间内料仓的料 (只列整批领料的料; 含每袋净重、默认出库叶仓、各叶仓可发量)。
  Future<List<WmMaterialOption>> materials(String workshopId) async {
    final list = await api.getList(
      ApiEndpoints.workshopMaterialMaterials,
      query: {'workshopId': workshopId},
    );
    return list.map(WmMaterialOption.fromJson).toList(growable: false);
  }

  /// 内料仓页: 现存 + 顶部盘点 / 结算状态。
  Future<WmPosition> position(String binId) async {
    final json = await api.get(ApiEndpoints.workshopMaterialBinPosition(binId));
    return WmPosition.fromJson(json);
  }

  // ---------------------------------------------------------------- 领料单

  Future<PagedResult<WmRequisition>> requisitions({
    String? status,
    String? kind,
    String? workshopId,
    String? keyword,
    int page = 1,
    int size = 20,
    Map<String, String> scope = const {},
  }) async {
    final json = await api.get(
      ApiEndpoints.workshopMaterialRequisitions,
      query: {
        if (status != null && status.isNotEmpty) 'status': status,
        if (kind != null && kind.isNotEmpty) 'kind': kind,
        if (workshopId != null && workshopId.isNotEmpty)
          'workshopId': workshopId,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        'page': page < 1 ? 1 : page,
        'size': size.clamp(1, 100),
        ...scope,
      },
    );
    return PagedResult.fromJson(json, WmRequisition.fromJson);
  }

  /// 领料单详情 (按申请发料 / 收退回页)。
  Future<WmRequisition> requisition(String id) async {
    final json = await api.get(ApiEndpoints.workshopMaterialRequisition(id));
    return WmRequisition.fromJson(json);
  }

  /// 车间申请领料 / 退回 (lines: goodsId, colorId, qty, bags)。
  Future<WmRequisition> createRequisition({
    required String kind,
    required String workshopDepartmentId,
    required List<Map<String, dynamic>> lines,
    String? remark,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.workshopMaterialRequisitions,
      body: {
        'kind': kind,
        'workshopDepartmentId': workshopDepartmentId,
        'lines': lines,
        if (remark != null && remark.trim().isNotEmpty) 'remark': remark.trim(),
        'idempotencyKey': idempotencyKey,
      },
    );
    return WmRequisition.fromJson(json);
  }

  /// 按申请发料 / 收退回 (lines: lineId, leafWarehouseId, qty; 同一行可拆到两个叶仓)。
  Future<WmIssueResult> fulfil(
    String id, {
    required int expectedVersion,
    required List<Map<String, dynamic>> lines,
    WmSupplement? supplement,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.workshopMaterialRequisitionFulfil(id),
      body: {
        'expectedVersion': expectedVersion,
        'lines': lines,
        if (supplement != null) 'supplement': supplement.toJson(),
        'idempotencyKey': idempotencyKey,
      },
    );
    return WmIssueResult.fromJson(json);
  }

  Future<void> cancelRequisition(
    String id, {
    required int expectedVersion,
    required String reason,
    required String idempotencyKey,
  }) async {
    await api.post(
      ApiEndpoints.workshopMaterialRequisitionCancel(id),
      body: {
        'expectedVersion': expectedVersion,
        'reason': reason,
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  /// 仓库直接发料 (lines: goodsId, colorId, bags, qty, leafWarehouseId)。
  Future<WmIssueResult> directIssue({
    required String workshopDepartmentId,
    required String receiverEmployeeId,
    required List<Map<String, dynamic>> lines,
    WmSupplement? supplement,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.workshopMaterialDirectIssues,
      body: {
        'workshopDepartmentId': workshopDepartmentId,
        'receiverEmployeeId': receiverEmployeeId,
        'lines': lines,
        if (supplement != null) 'supplement': supplement.toJson(),
        'idempotencyKey': idempotencyKey,
      },
    );
    return WmIssueResult.fromJson(json);
  }

  /// 直接发料默认值: 该车间上一次的领料人。
  Future<WmDirectIssueDefaults> directIssueDefaults(String workshopId) async {
    final json = await api.get(
      ApiEndpoints.workshopMaterialDirectIssueDefaults,
      query: {'workshopId': workshopId},
    );
    return WmDirectIssueDefaults.fromJson(json);
  }

  /// 其它耗用 (试模、清机、报废料、其它)。
  Future<void> otherIssue({
    required String workshopDepartmentId,
    required String goodsId,
    String? colorId,
    required double qty,
    required String reason,
    String? reasonText,
    required String idempotencyKey,
  }) async {
    await api.post(
      ApiEndpoints.workshopMaterialOtherIssues,
      body: {
        'workshopDepartmentId': workshopDepartmentId,
        'goodsId': goodsId,
        'colorId': colorId,
        'qty': qty,
        'reason': reason,
        if (reasonText != null && reasonText.trim().isNotEmpty)
          'reasonText': reasonText.trim(),
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  // ---------------------------------------------------------------- 期间与盘点

  Future<List<WmPeriod>> periods(String binId) async {
    // 服务端回 {periods:[...]}。
    final json = await api.get(
      ApiEndpoints.workshopMaterialPeriods,
      query: {'binId': binId},
    );
    return _listIn(
      json,
      'periods',
    ).map(WmPeriod.fromJson).toList(growable: false);
  }

  /// 一期的详情 (含当前盘点单 id)。
  Future<WmPeriod> period(String periodId) async {
    final json = await api.get(ApiEndpoints.workshopMaterialPeriod(periodId));
    return WmPeriod.fromJson(json);
  }

  /// 开始盘点: 当场截止本期并开出下一期; 返回期间 + 新盘点单 (已预置行)。
  Future<WmStartCountResult> startCount(
    String periodId, {
    required int expectedVersion,
    required String cutoffDate,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.workshopMaterialStartCount(periodId),
      body: {
        'expectedVersion': expectedVersion,
        'cutoffDate': cutoffDate,
        'idempotencyKey': idempotencyKey,
      },
    );
    return WmStartCountResult.fromJson(json);
  }

  Future<void> withdrawCount(
    String periodId, {
    required int expectedVersion,
    required String idempotencyKey,
  }) async {
    await api.post(
      ApiEndpoints.workshopMaterialWithdrawCount(periodId),
      body: {
        'expectedVersion': expectedVersion,
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  Future<WmCount> count(String countId) async {
    final json = await api.get(ApiEndpoints.workshopMaterialCount(countId));
    return WmCount.fromJson(json);
  }

  /// 逐行保存 (每行点完即落库); 版本冲突服务端回 409。
  Future<WmCountLine> saveCountLine(String countId, WmCountLine line) async {
    final json = await api.put(
      ApiEndpoints.workshopMaterialCountLine(countId, line.clientLineKey),
      body: line.toSaveJson(),
    );
    return WmCountLine.fromJson(json);
  }

  Future<void> deleteCountLine(
    String countId,
    String clientLineKey, {
    required int expectedVersion,
  }) => api.delete(
    '${ApiEndpoints.workshopMaterialCountLine(countId, clientLineKey)}'
    '?expectedVersion=$expectedVersion',
  );

  /// "其余料都用完了, 记 0": 返回新增的 0 行。
  Future<List<WmCountLine>> zeroRest(
    String countId, {
    required String idempotencyKey,
  }) async {
    // 服务端回 {lines:[...]}。
    final json = await api.post(
      ApiEndpoints.workshopMaterialZeroRest(countId),
      body: {'idempotencyKey': idempotencyKey},
    );
    return _listIn(
      json,
      'lines',
    ).map(WmCountLine.fromJson).toList(growable: false);
  }

  /// 提交盘点: 返回期间 (已盘点, 排队自动结算); 缺容器 / 缺料服务端回 422 列出。
  Future<WmPeriod> submitCount(
    String countId, {
    required int expectedVersion,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.workshopMaterialSubmitCount(countId),
      body: {
        'expectedVersion': expectedVersion,
        'idempotencyKey': idempotencyKey,
      },
    );
    final period = json['period'];
    return WmPeriod.fromJson(
      period is Map ? period.cast<String, dynamic>() : json,
    );
  }

  /// 更正盘点: 出新版本草稿 (预置上一版全部行)。
  Future<WmCount> correctCount(
    String periodId, {
    required int expectedVersion,
    required String reason,
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.workshopMaterialCorrectCount(periodId),
      body: {
        'expectedVersion': expectedVersion,
        'reason': reason,
        'idempotencyKey': idempotencyKey,
      },
    );
    final count = json['count'];
    return WmCount.fromJson(
      count is Map ? count.cast<String, dynamic>() : json,
    );
  }

  Future<WmCloseStatus> closeStatus(String periodId) async {
    final json = await api.get(
      ApiEndpoints.workshopMaterialCloseStatus(periodId),
    );
    return WmCloseStatus.fromJson(json);
  }

  /// "立即重试" / "重新结算": 202 + 结算状态 (后台执行, 页面随后轮询)。
  Future<WmCloseStatus> closeRetry(
    String periodId, {
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.workshopMaterialCloseRetry(periodId),
      body: {'idempotencyKey': idempotencyKey},
    );
    return WmCloseStatus.fromJson(json);
  }

  // ---------------------------------------------------------------- 上线准备

  Future<WmPreparation> preparation(String workshopId) async {
    final json = await api.get(
      ApiEndpoints.goodsPeriodicBomPreparation,
      query: {'workshopId': workshopId},
    );
    return WmPreparation.fromJson(json);
  }

  /// 批量写 BOM 塑料单个重量 (克); 单重为空的行服务端改写认料 (记在 [workshopDepartmentId] 名下)。
  ///
  /// 每行 {productGoodsId, bomItemId?, materialGoodsId, colorId?, unitWeightGrams?,
  /// confirmUnusualWeight?, confirmSecondPeriodicMaterial?, prefillSource?}; 确认字段逐行带。
  /// 服务端要人确认 (异常单重 / 同一产品第二种料) 时回 422, fieldErrors 是确认字段名。
  /// 返回保存后的提醒 (不拦保存)。
  Future<List<String>> savePreparation(
    String workshopDepartmentId,
    List<Map<String, dynamic>> rows, {
    required String idempotencyKey,
  }) async {
    final json = await api.post(
      ApiEndpoints.goodsPeriodicBomBatch,
      body: {
        'workshopDepartmentId': workshopDepartmentId,
        'rows': rows,
        'idempotencyKey': idempotencyKey,
      },
    );
    final warnings = json['warnings'];
    return warnings is List
        ? [for (final w in warnings) w.toString()]
        : const <String>[];
  }
}

final workshopMaterialRepositoryProvider = Provider<WorkshopMaterialRepository>(
  (ref) => WorkshopMaterialRepository(ref.watch(apiClientProvider)),
);

/// 服务端列表多包在一个对象里 (如 {periods:[...]}、{machines:[...]})。
List<Map<String, dynamic>> _listIn(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is List
      ? value.whereType<Map<String, dynamic>>().toList(growable: false)
      : const [];
}

/// 机台接口 (列表、批量新增、批量改机台/容器) 都回 {machines:[...]}。
List<WmMachine> _machinesIn(Map<String, dynamic> json) =>
    _listIn(json, 'machines').map(WmMachine.fromJson).toList(growable: false);
