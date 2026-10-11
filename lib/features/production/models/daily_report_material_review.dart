import '../../../shared/formatters/exact_decimal.dart';
import 'production_exact_quantity.dart';

enum DailyReportMaterialAction {
  keep('KEEP', '留在车间'),
  returnToWarehouse('RETURN', '退回仓库');

  const DailyReportMaterialAction(this.wire, this.label);
  final String wire;
  final String label;

  static DailyReportMaterialAction parse(Object? value) => switch (value) {
    'KEEP' => keep,
    'RETURN' => returnToWarehouse,
    _ => throw const FormatException('余料处理方式无法识别，请重新核对'),
  };
}

class DailyReportMaterialDecision {
  const DailyReportMaterialDecision(this.demandId, this.action);
  final String demandId;
  final DailyReportMaterialAction action;

  Map<String, dynamic> toJson() => {
    'demandId': demandId,
    'action': action.wire,
  };

  factory DailyReportMaterialDecision.fromJson(Map<String, dynamic> json) {
    final id = json['demandId'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('余料处理缺少来源需求');
    }
    return DailyReportMaterialDecision(
      id,
      DailyReportMaterialAction.parse(json['action']),
    );
  }
}

/// All balances are provided by the server for this saved report and ledger
/// snapshot. The client never derives returnability from cumulative issues.
class DailyReportMaterialReview {
  const DailyReportMaterialReview({
    required this.reportId,
    required this.reportVersion,
    required this.fingerprint,
    required this.rows,
  });
  final String reportId;
  final int reportVersion;
  final String fingerprint;
  final List<DailyReportMaterialReviewRow> rows;

  Map<String, dynamic> toJson() => {
    'reportId': reportId,
    'reportVersion': reportVersion,
    'fingerprint': fingerprint,
    'rows': rows.map((row) => row.toJson()).toList(),
  };

  factory DailyReportMaterialReview.fromJson(Map<String, dynamic> json) {
    final id = json['reportId'];
    final version = json['reportVersion'];
    final fingerprint = json['fingerprint'];
    final rawRows = json['rows'];
    if (id is! String ||
        id.isEmpty ||
        version is! int ||
        version < 0 ||
        fingerprint is! String ||
        fingerprint.trim().isEmpty ||
        rawRows is! List) {
      throw const FormatException('余料核对资料不完整，请刷新后重新核对');
    }
    final rows = rawRows
        .map((raw) {
          if (raw is! Map) throw const FormatException('余料核对明细不完整');
          return DailyReportMaterialReviewRow.fromJson(
            Map<String, dynamic>.from(raw),
          );
        })
        .toList(growable: false);
    if (rows.map((row) => row.demandId).toSet().length != rows.length) {
      throw const FormatException('余料核对包含重复需求，请重新读取');
    }
    return DailyReportMaterialReview(
      reportId: id,
      reportVersion: version,
      fingerprint: fingerprint,
      rows: List.unmodifiable(rows),
    );
  }

  List<DailyReportMaterialDecision> freezeDecisions(
    Map<String, DailyReportMaterialAction> selected,
  ) => List.unmodifiable([
    for (final row in rows)
      DailyReportMaterialDecision(
        row.demandId,
        row.requiresDecision
            ? (selected[row.demandId] ?? (throw StateError('请逐料选择退回仓库或留在车间')))
            : DailyReportMaterialAction.keep,
      ),
  ]);
}

class DailyReportMaterialReviewRow {
  const DailyReportMaterialReviewRow({
    required this.demandId,
    required this.planId,
    required this.materialExecutionSegmentId,
    required this.availableQty,
    required this.usageQty,
    required this.remainingIssuedQty,
    required this.undrawnDirectQty,
    required this.returnableIssuedQty,
    required this.returnableDirectQty,
    required this.canReturn,
    this.materialExecutionSegmentCode,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.returnBlockedReason,
  });
  final String demandId, planId, materialExecutionSegmentId;
  final String? materialExecutionSegmentCode,
      goodsCode,
      goodsName,
      colorName,
      unitName,
      returnBlockedReason;
  final String availableQty,
      usageQty,
      remainingIssuedQty,
      undrawnDirectQty,
      returnableIssuedQty,
      returnableDirectQty;
  final bool canReturn;

  Map<String, dynamic> toJson() => {
    'demandId': demandId,
    'planId': planId,
    'materialExecutionSegmentId': materialExecutionSegmentId,
    'materialExecutionSegmentCode': ?materialExecutionSegmentCode,
    'goodsCode': ?goodsCode,
    'goodsName': ?goodsName,
    'colorName': ?colorName,
    'unitName': ?unitName,
    'availableQtyExact': availableQty,
    'usageQtyExact': usageQty,
    'remainingIssuedQtyExact': remainingIssuedQty,
    'undrawnDirectQtyExact': undrawnDirectQty,
    'returnableIssuedQtyExact': returnableIssuedQty,
    'returnableDirectQtyExact': returnableDirectQty,
    'canReturn': canReturn,
    'returnBlockedReason': ?returnBlockedReason,
  };

  bool get hasBalance =>
      financeExactDecimalUnits(remainingIssuedQty)! > BigInt.zero ||
      financeExactDecimalUnits(undrawnDirectQty)! > BigInt.zero;
  bool get requiresDecision => canReturn && hasBalance;
  String get returnableQty => productionExactQuantityText(
    financeExactDecimalFromUnits(
      financeExactDecimalUnits(returnableIssuedQty)! +
          financeExactDecimalUnits(returnableDirectQty)!,
    ),
  )!;

  factory DailyReportMaterialReviewRow.fromJson(Map<String, dynamic> json) {
    String requiredId(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('余料核对缺少来源身份');
      }
      return value;
    }

    String quantity(String key) {
      final text = productionExactQuantityText(
        json['${key}Exact'] ?? json[key],
      );
      if (text == null) throw const FormatException('余料数量缺少精确原文，请重新读取');
      return text;
    }

    if (json['canReturn'] is! bool) {
      throw const FormatException('余料退仓资格尚未核对');
    }
    return DailyReportMaterialReviewRow(
      demandId: requiredId('demandId'),
      planId: requiredId('planId'),
      materialExecutionSegmentId: requiredId('materialExecutionSegmentId'),
      materialExecutionSegmentCode:
          json['materialExecutionSegmentCode'] as String?,
      goodsCode: json['goodsCode'] as String?,
      goodsName: json['goodsName'] as String?,
      colorName: json['colorName'] as String?,
      unitName: json['unitName'] as String?,
      availableQty: quantity('availableQty'),
      usageQty: quantity('usageQty'),
      remainingIssuedQty: quantity('remainingIssuedQty'),
      undrawnDirectQty: quantity('undrawnDirectQty'),
      returnableIssuedQty: quantity('returnableIssuedQty'),
      returnableDirectQty: quantity('returnableDirectQty'),
      canReturn: json['canReturn'] as bool,
      returnBlockedReason: json['returnBlockedReason'] as String?,
    );
  }
}
