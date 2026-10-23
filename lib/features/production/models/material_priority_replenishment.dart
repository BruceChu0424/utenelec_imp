import 'production_material_analysis.dart';
import 'material_transfer_quantity.dart';

class MaterialPriorityReplenishmentPreview {
  const MaterialPriorityReplenishmentPreview({
    required this.sourceAnalysis,
    required this.sourceMaterialLineId,
    required this.targetAnalysisId,
    required this.transferredQty,
    required this.priorityPendingQty,
    required this.remainingSupplementQty,
    required this.defaultQty,
    required this.allowedRoutes,
    required this.operation,
    this.route,
    this.canOverSupply = false,
    this.safetyReplenishmentQty = 0,
    this.blockedReason,
    this.existingChildAnalysisLineId,
    this.quantityFactsExact = const {},
  });

  final ProductionMaterialAnalysisView sourceAnalysis;
  final String sourceMaterialLineId;
  final String targetAnalysisId;
  final double transferredQty;
  final double priorityPendingQty;
  final double remainingSupplementQty;
  final double defaultQty;
  final MaterialSupplyRoute? route;
  final Set<MaterialSupplyRoute> allowedRoutes;
  final String operation;
  final bool canOverSupply;
  final double safetyReplenishmentQty;
  final String? blockedReason;
  final String? existingChildAnalysisLineId;
  final Map<String, String> quantityFactsExact;

  bool get createsProductionPlan => operation == 'ISSUE_WORKSHOP_PLANS';
  ProductionMaterialAnalysisMaterial? get material => sourceAnalysis.materials
      .where((row) => row.materialLineId == sourceMaterialLineId)
      .firstOrNull;

  factory MaterialPriorityReplenishmentPreview.fromJson(
    Map<String, dynamic> json,
  ) => _fromAnalysis(
    json,
    ProductionMaterialAnalysisView.fromJson(
      Map<String, dynamic>.from(json['sourceAnalysis'] as Map),
    ),
  );

  static Future<MaterialPriorityReplenishmentPreview> fromJsonResponsive(
    Map<String, dynamic> json,
  ) async => _fromAnalysis(
    json,
    await ProductionMaterialAnalysisView.fromJsonResponsive(
      Map<String, dynamic>.from(json['sourceAnalysis'] as Map),
    ),
  );

  static MaterialPriorityReplenishmentPreview _fromAnalysis(
    Map<String, dynamic> json,
    ProductionMaterialAnalysisView analysis,
  ) {
    double qty(String key) => (json[key] as num?)?.toDouble() ?? 0;
    return MaterialPriorityReplenishmentPreview(
      sourceAnalysis: analysis,
      sourceMaterialLineId: json['sourceMaterialLineId'] as String,
      targetAnalysisId: json['targetAnalysisId'] as String,
      transferredQty: qty('transferredQty'),
      priorityPendingQty: qty('priorityPendingQty'),
      remainingSupplementQty: qty('remainingSupplementQty'),
      defaultQty: qty('defaultQty'),
      route: MaterialSupplyRoute.fromWire(json['route']),
      allowedRoutes: (json['allowedRoutes'] as List? ?? const [])
          .map(MaterialSupplyRoute.fromWire)
          .whereType<MaterialSupplyRoute>()
          .toSet(),
      operation: json['operation'] as String? ?? '',
      canOverSupply: json['canOverSupply'] == true,
      safetyReplenishmentQty: qty('safetyReplenishmentQty'),
      blockedReason: json['blockedReason'] as String?,
      existingChildAnalysisLineId:
          json['existingChildAnalysisLineId'] as String?,
      quantityFactsExact: materialTransferExactFacts(
        json['quantityFactsExact'],
      ),
    );
  }
}
