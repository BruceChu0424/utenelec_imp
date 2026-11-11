import 'dart:convert';
import 'production_material_analysis.dart';

/// Immutable original request for the existing notify/issue-plans protocols.
/// The preparation draft owner holds one command, never a replacement queue.
class MaterialPreparationOriginalCommand {
  MaterialPreparationOriginalCommand._(
    this.analysisId,
    this.operation,
    this.bodyJson,
    this.rowLabels,
    this.lineIds,
  );
  final String analysisId, operation, bodyJson;
  final Map<String, String> rowLabels;
  final Set<String> lineIds;
  bool get issuesPlans => operation == 'issue-plans';
  Map<String, dynamic> toBody() =>
      Map<String, dynamic>.from(jsonDecode(bodyJson) as Map);
  String get idempotencyKey => toBody()['idempotencyKey'] as String;

  factory MaterialPreparationOriginalCommand.notify({
    required ProductionMaterialAnalysisView analysis,
    required String idempotencyKey,
    required MaterialSupplyRoute target,
    List<String> actionGroupKeys = const [],
    List<String> materialLineIds = const [],
    List<MaterialSupplyQuantityInput> quantities = const [],
    bool skipAutoClaim = false,
    Map<String, String> rowLabels = const {},
    Set<String> lineIds = const {},
  }) => MaterialPreparationOriginalCommand._(
    analysis.analysisId,
    'notify',
    jsonEncode({
      'version': analysis.version,
      'fingerprint': analysis.fingerprint,
      'idempotencyKey': idempotencyKey,
      'target': target.wireName,
      if (actionGroupKeys.isNotEmpty) 'actionGroupKeys': actionGroupKeys,
      if (materialLineIds.isNotEmpty) 'materialLineIds': materialLineIds,
      if (quantities.isNotEmpty)
        'quantities': [for (final item in quantities) item.toJson()],
      if (skipAutoClaim) 'skipAutoClaim': true,
    }),
    Map.unmodifiable(rowLabels),
    Set.unmodifiable(lineIds),
  );

  factory MaterialPreparationOriginalCommand.issuePlans({
    required ProductionMaterialAnalysisView analysis,
    required String warehouseId,
    required String idempotencyKey,
    required String billDate,
    required List<MaterialAnalysisIssueLine> lines,
    String? deliveryDate,
    bool approveNow = false,
    bool skipAutoClaim = false,
    Map<String, String> rowLabels = const {},
    Set<String> lineIds = const {},
  }) => MaterialPreparationOriginalCommand._(
    analysis.analysisId,
    'issue-plans',
    jsonEncode({
      'version': analysis.version,
      'fingerprint': analysis.fingerprint,
      'warehouseId': warehouseId,
      'idempotencyKey': idempotencyKey,
      'billDate': billDate,
      'deliveryDate': ?deliveryDate,
      'approveNow': approveNow,
      'lines': [for (final line in lines) line.toJson()],
      if (skipAutoClaim) 'skipAutoClaim': true,
    }),
    Map.unmodifiable(rowLabels),
    Set.unmodifiable(lineIds),
  );

  Map<String, dynamic> toDraft() => {
    'analysisId': analysisId,
    'operation': operation,
    'bodyJson': bodyJson,
    'rowLabels': rowLabels,
    'lineIds': lineIds.toList(),
  };
  factory MaterialPreparationOriginalCommand.fromDraft(
    Map<String, dynamic> data,
  ) {
    final operation = data['operation'] as String,
        analysisId = data['analysisId'] as String,
        encoded = data['bodyJson'] as String;
    final body = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
    if (analysisId.isEmpty ||
        !const {'notify', 'issue-plans'}.contains(operation) ||
        body['version'] is! int ||
        body['fingerprint'] is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(body['fingerprint'] as String) ||
        body['idempotencyKey'] is! String ||
        (body['idempotencyKey'] as String).isEmpty ||
        jsonEncode(body) != encoded) {
      throw const FormatException('原下单请求无法原样核对，请保留恢复票据');
    }
    final allowed = operation == 'notify'
        ? const {
            'version',
            'fingerprint',
            'idempotencyKey',
            'target',
            'actionGroupKeys',
            'materialLineIds',
            'quantities',
            'skipAutoClaim',
          }
        : const {
            'version',
            'fingerprint',
            'warehouseId',
            'idempotencyKey',
            'billDate',
            'deliveryDate',
            'approveNow',
            'lines',
            'skipAutoClaim',
          };
    if (body.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('原下单请求含当前版本无法核对的字段');
    }
    if (operation == 'notify' &&
        !const {'BUY', 'MAKE', 'SUBCONTRACT'}.contains(body['target'])) {
      throw const FormatException('原下单方向无法核对');
    }
    final rows = body[operation == 'notify' ? 'quantities' : 'lines'];
    if (rows != null) {
      if (rows is! List) throw const FormatException('原下单行无法核对');
      final keys = operation == 'notify'
          ? const {
              'actionGroupKey',
              'materialLineId',
              'qty',
              'safetyReplenishmentQty',
              'quantityMode',
              'orderMethod',
            }
          : const {
              'materialLineId',
              'analysisLineId',
              'qty',
              'allowedOverproductionRate',
              'departmentId',
              'workshopName',
              'workerId',
              'publicSurplusOnly',
              'quantityMode',
              'orderMethod',
            };
      for (final row in rows) {
        if (row is! Map || row.keys.any((key) => !keys.contains(key))) {
          throw const FormatException('原下单行含当前版本无法核对的字段');
        }
        if (row['quantityMode'] != null &&
            row['quantityMode'] != 'COVERAGE_TOTAL') {
          throw const FormatException('原数量口径无法核对');
        }
        if (row['orderMethod'] != null &&
            MaterialPreparationOrderMethod.fromWire(row['orderMethod']) ==
                null) {
          throw const FormatException('原下单方式无法核对');
        }
      }
    }
    return MaterialPreparationOriginalCommand._(
      analysisId,
      operation,
      encoded,
      Map.unmodifiable(Map<String, String>.from(data['rowLabels'] as Map)),
      Set.unmodifiable((data['lineIds'] as List).cast<String>()),
    );
  }
}
