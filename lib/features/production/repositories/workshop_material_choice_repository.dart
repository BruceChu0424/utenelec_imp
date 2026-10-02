// 车间内料仓: 认料、段级换料与工单库存提示 (ADR-131 §5.4、§5.5)。
//
// 开工确认表读待确认的产品并写认料，行菜单办理换料，详情读取库存提示。
// 整批补料仍复用 features/warehouse/materialbin 的申请面板和仓储。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/workshop_task_stock_readiness.dart';

/// 认料种类: 用内料仓里的料。
const workshopMaterialChoiceKindMaterial = 'MATERIAL';

/// 认料种类: 本产品不用车间内料仓的料 (按工单领料)。
const workshopMaterialChoiceKindNone = 'NONE';

/// 预填来源: 老库货品「材质」文字唯一对上某种料。
const workshopMaterialPrefillLegacyText = 'LEGACY_MATERIAL_TEXT';

/// 换料的单个重量口径: 沿用被换掉那种料的单个重量 (默认)。
const workshopMaterialWeightFromReplaced = 'FROM_REPLACED';

/// 换料的单个重量口径: 按新料在 BOM 里填的单个重量 (「加一种料」只能用它)。
const workshopMaterialWeightOwnBom = 'OWN_BOM';

double? _decimalOrNull(Object? raw) {
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}

String? _textOrNull(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

List<Map<String, dynamic>> _mapList(Object? raw) => raw is List
    ? raw.whereType<Map<String, dynamic>>().toList(growable: false)
    : const [];

/// 一种料 = 货品 + 颜色 (颜色可空)。
class WorkshopMaterialRef {
  const WorkshopMaterialRef({required this.goodsId, this.colorId});

  final String goodsId;
  final String? colorId;

  /// 比较与去重用的稳定键。
  String get key => '$goodsId|${colorId ?? ''}';

  factory WorkshopMaterialRef.fromJson(Map<String, dynamic> json) =>
      WorkshopMaterialRef(
        goodsId: json['goodsId'] as String? ?? '',
        colorId: _textOrNull(json['colorId']),
      );

  Map<String, dynamic> toJson() => {'goodsId': goodsId, 'colorId': colorId};

  @override
  bool operator ==(Object other) =>
      other is WorkshopMaterialRef &&
      other.goodsId == goodsId &&
      other.colorId == colorId;

  @override
  int get hashCode => Object.hash(goodsId, colorId);
}

/// 下拉里可选的一种料 (本车间内料仓收的主料)。
class WorkshopMaterialOption {
  const WorkshopMaterialOption({
    required this.goodsId,
    required this.goodsName,
    this.colorId,
    this.goodsCode,
    this.colorName,
  });

  final String goodsId;
  final String? colorId;
  final String? goodsCode;
  final String goodsName;
  final String? colorName;

  WorkshopMaterialRef get ref =>
      WorkshopMaterialRef(goodsId: goodsId, colorId: colorId);

  /// 给员工看的名字: 「料名 颜色」, 同名料再带编号区分由调用方决定。
  String get label => colorName == null || colorName!.isEmpty
      ? goodsName
      : '$goodsName $colorName';

  factory WorkshopMaterialOption.fromJson(Map<String, dynamic> json) =>
      WorkshopMaterialOption(
        goodsId: json['goodsId'] as String? ?? '',
        colorId: _textOrNull(json['colorId']),
        goodsCode: _textOrNull(json['goodsCode']),
        goodsName:
            _textOrNull(json['goodsName']) ??
            _textOrNull(json['goodsCode']) ??
            '未命名的料',
        colorName: _textOrNull(json['colorName']),
      );
}

/// 产品 BOM 里某种整批领料的单个重量 (克); 只读展示。
class WorkshopMaterialBomWeight {
  const WorkshopMaterialBomWeight({
    required this.goodsId,
    this.colorId,
    this.unitWeightGrams,
  });

  final String goodsId;
  final String? colorId;
  final double? unitWeightGrams;

  factory WorkshopMaterialBomWeight.fromJson(Map<String, dynamic> json) =>
      WorkshopMaterialBomWeight(
        goodsId: json['goodsId'] as String? ?? '',
        colorId: _textOrNull(json['colorId']),
        unitWeightGrams: _decimalOrNull(json['unitWeightGrams']),
      );
}

/// 开工确认表的一行 (服务端按车间 + 产品聚合本次勾选的任务)。
class WorkshopMaterialPendingChoice {
  const WorkshopMaterialPendingChoice({
    required this.workshopDepartmentId,
    required this.productGoodsId,
    required this.segmentIds,
    required this.taskCount,
    required this.choiceRequired,
    this.workshopName,
    this.productCode,
    this.productName,
    this.prefill = const [],
    this.prefillSource,
    this.options = const [],
    this.bomWeights = const [],
    this.alsoOrderMaterialsAllowed = false,
  });

  final String workshopDepartmentId;
  final String? workshopName;
  final String productGoodsId;
  final String? productCode;
  final String? productName;

  /// 本次勾选里属于这一行的任务段。
  final List<String> segmentIds;

  /// 本次任务数。
  final int taskCount;

  /// 必须认料 (待认料); 为假时只是生产路线未确认, 用料列只读。
  final bool choiceRequired;

  /// 预填料 (上次认料或老库材质唯一命中)。
  final List<WorkshopMaterialRef> prefill;

  /// 预填来源: LEGACY_MATERIAL_TEXT = 老库材质; 上次认料或没有预填为 null。
  final String? prefillSource;

  /// 本车间内料仓收的全部主料。
  final List<WorkshopMaterialOption> options;

  /// BOM 里已填的单个重量; 空 = 待补 (不影响开工)。
  final List<WorkshopMaterialBomWeight> bomWeights;

  /// 能否勾「还要按工单领别的料」(= 产品没有任何 BOM)。
  final bool alsoOrderMaterialsAllowed;

  factory WorkshopMaterialPendingChoice.fromJson(Map<String, dynamic> json) {
    final segmentIds = (json['segmentIds'] is List)
        ? (json['segmentIds'] as List).whereType<String>().toList(
            growable: false,
          )
        : const <String>[];
    return WorkshopMaterialPendingChoice(
      workshopDepartmentId: json['workshopDepartmentId'] as String? ?? '',
      workshopName: _textOrNull(json['workshopName']),
      productGoodsId: json['productGoodsId'] as String? ?? '',
      productCode: _textOrNull(json['productCode']),
      productName: _textOrNull(json['productName']),
      segmentIds: segmentIds,
      taskCount: (json['taskCount'] as num?)?.toInt() ?? segmentIds.length,
      choiceRequired: json['choiceRequired'] == true,
      prefill: _mapList(
        json['prefill'],
      ).map(WorkshopMaterialRef.fromJson).toList(growable: false),
      prefillSource: _textOrNull(json['prefillSource']),
      options: _mapList(
        json['options'],
      ).map(WorkshopMaterialOption.fromJson).toList(growable: false),
      bomWeights: _mapList(
        json['bomWeights'],
      ).map(WorkshopMaterialBomWeight.fromJson).toList(growable: false),
      alsoOrderMaterialsAllowed: json['alsoOrderMaterialsAllowed'] == true,
    );
  }
}

/// 一个产品的认料 (写入用)。
class WorkshopMaterialProductChoice {
  const WorkshopMaterialProductChoice({
    required this.productGoodsId,
    required this.kind,
    this.materials = const [],
    this.alsoOrderMaterials = false,
    this.prefillSource,
  });

  final String productGoodsId;

  /// MATERIAL 或 NONE。
  final String kind;

  /// MATERIAL 时至少一种; NONE 时为空。
  final List<WorkshopMaterialRef> materials;

  /// 只对 MATERIAL: 还要按工单领别的料 (例如嵌件)。
  final bool alsoOrderMaterials;

  /// 直接采用老库材质预填值时带 LEGACY_MATERIAL_TEXT。
  final String? prefillSource;

  Map<String, dynamic> toJson() => {
    'productGoodsId': productGoodsId,
    'kind': kind,
    'materials': [for (final material in materials) material.toJson()],
    'alsoOrderMaterials': alsoOrderMaterials,
    'prefillSource': prefillSource,
  };

  /// 幂等键的规范化内容 (同一内容重试用同一个键)。
  String get canonical => [
    productGoodsId,
    kind,
    (materials.map((m) => m.key).toList()..sort()).join(','),
    alsoOrderMaterials ? '1' : '0',
    prefillSource ?? '',
  ].join('|');
}

/// 段的一条期间料行 (这张工单现在从内料仓用的一种料)。
class WorkshopMaterialSegmentRow {
  const WorkshopMaterialSegmentRow({
    required this.id,
    required this.materialGoodsId,
    required this.materialName,
    this.materialColorId,
    this.materialCode,
    this.materialColorName,
    this.effectiveFrom,
    this.effectiveTo,
    this.unitWeightGrams,
  });

  final String id;
  final String materialGoodsId;
  final String? materialColorId;
  final String? materialCode;
  final String materialName;
  final String? materialColorName;

  /// yyyy-MM-dd。
  final String? effectiveFrom;

  /// yyyy-MM-dd; 空 = 仍在用。
  final String? effectiveTo;

  /// 单个重量 (克); 空 = 待补。
  final double? unitWeightGrams;

  bool get active => effectiveTo == null;

  String get label => materialColorName == null || materialColorName!.isEmpty
      ? materialName
      : '$materialName $materialColorName';

  factory WorkshopMaterialSegmentRow.fromJson(Map<String, dynamic> json) =>
      WorkshopMaterialSegmentRow(
        id: json['id'] as String? ?? '',
        materialGoodsId: json['materialGoodsId'] as String? ?? '',
        materialColorId: _textOrNull(json['materialColorId']),
        materialCode: _textOrNull(json['materialCode']),
        materialName:
            _textOrNull(json['materialName']) ??
            _textOrNull(json['materialCode']) ??
            '未命名的料',
        materialColorName:
            _textOrNull(json['materialColorName']) ??
            _textOrNull(json['colorName']),
        effectiveFrom: _textOrNull(json['effectiveFrom']),
        effectiveTo: _textOrNull(json['effectiveTo']),
        unitWeightGrams: _decimalOrNull(json['unitWeightGrams']),
      );
}

/// 换料对话框的底稿: 这张工单现在用的料、可换的料、最早可以从哪天起改。
class WorkshopMaterialSegmentMaterials {
  const WorkshopMaterialSegmentMaterials({
    required this.rows,
    required this.options,
    this.lockVersion,
    this.earliestEffectiveFrom,
  });

  final List<WorkshopMaterialSegmentRow> rows;
  final List<WorkshopMaterialOption> options;

  /// 段的最新版本 (有就用它提交, 没有沿用任务列表里的版本)。
  final int? lockVersion;

  /// 最早可以从哪天起改用 (yyyy-MM-dd; = 内料仓已结算截止日的下一天)。
  final String? earliestEffectiveFrom;

  List<WorkshopMaterialSegmentRow> get activeRows =>
      rows.where((row) => row.active).toList(growable: false);

  factory WorkshopMaterialSegmentMaterials.fromJson(
    Map<String, dynamic> json,
  ) => WorkshopMaterialSegmentMaterials(
    rows: _mapList(
      json['rows'],
    ).map(WorkshopMaterialSegmentRow.fromJson).toList(growable: false),
    options: _mapList(
      json['options'],
    ).map(WorkshopMaterialOption.fromJson).toList(growable: false),
    lockVersion: (json['lockVersion'] as num?)?.toInt(),
    earliestEffectiveFrom: _textOrNull(json['earliestEffectiveFrom']),
  );
}

class WorkshopMaterialChoiceRepository {
  WorkshopMaterialChoiceRepository(this._api);

  final ApiClient _api;

  /// 库存足量是提示，不参与工单开工门；基本单位换算和未知状态由服务端给出。
  Future<WorkshopTaskStockReadiness> stockReadiness(
    String segmentId,
  ) async => WorkshopTaskStockReadiness.fromJson(
    await _api.get(
      '${ApiEndpoints.workshopMaterialBase}/segments/$segmentId/stock-readiness',
    ),
  );

  /// 开工确认表的行 (按车间 + 产品聚合); 不需要确认的段不出现。
  Future<List<WorkshopMaterialPendingChoice>> pending(
    List<String> segmentIds,
  ) async {
    if (segmentIds.isEmpty) return const [];
    final list = await _api.getList(
      ApiEndpoints.workshopMaterialChoicesPending,
      query: {'segmentIds': segmentIds.join(',')},
    );
    return list
        .map(WorkshopMaterialPendingChoice.fromJson)
        .toList(growable: false);
  }

  /// 一次写入一个车间里多个产品的认料 (一个原子请求, 同键重放不重复写)。
  Future<void> choose({
    required String workshopDepartmentId,
    required List<WorkshopMaterialProductChoice> choices,
    required String idempotencyKey,
  }) async {
    if (choices.isEmpty) return;
    await _api.post(
      ApiEndpoints.workshopMaterialChoices,
      body: {
        'workshopDepartmentId': workshopDepartmentId,
        'choices': [for (final choice in choices) choice.toJson()],
        'idempotencyKey': idempotencyKey,
      },
    );
  }

  /// 换料对话框的底稿 (这张工单现在用的料与可换的料)。
  Future<WorkshopMaterialSegmentMaterials> segmentMaterials(
    String segmentId,
  ) async => WorkshopMaterialSegmentMaterials.fromJson(
    await _api.get(ApiEndpoints.workshopMaterialSegmentChange(segmentId)),
  );

  /// 这张工单从 [effectiveFrom] 起改用别的料; [fromRowId] 为空 = 加一种料。
  /// 返回段最新的期间料行 (服务端回 {segmentId, binWarehouseId, rows:[...]})。
  Future<List<WorkshopMaterialSegmentRow>> changeMaterial(
    String segmentId, {
    required int expectedVersion,
    String? fromRowId,
    required WorkshopMaterialRef to,
    required String effectiveFrom,
    required String weightBasis,
    String? reason,
    required String idempotencyKey,
  }) async {
    final json = await _api.post(
      ApiEndpoints.workshopMaterialSegmentChange(segmentId),
      body: {
        'expectedVersion': expectedVersion,
        'fromRowId': fromRowId,
        'toMaterialGoodsId': to.goodsId,
        'toMaterialColorId': to.colorId,
        'effectiveFrom': effectiveFrom,
        'weightBasis': weightBasis,
        'reason': reason,
        'idempotencyKey': idempotencyKey,
      },
    );
    final rows = json['rows'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(WorkshopMaterialSegmentRow.fromJson)
        .toList(growable: false);
  }
}

final workshopMaterialChoiceRepositoryProvider =
    Provider<WorkshopMaterialChoiceRepository>(
      (ref) => WorkshopMaterialChoiceRepository(ref.watch(apiClientProvider)),
    );
