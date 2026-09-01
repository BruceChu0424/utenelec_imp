/// Context in which a goods measurement preference was learned.
///
/// A goods can be purchased by weight and sold by pieces, so profiles must not
/// be shared across operation families.
enum OperationFamily { purchase, warehouse, sales, subcontract, production }

enum Status { unknown, provisional, confirmed, conflict, manualOverride }

/// Supported data capture modes.
///
/// There is intentionally no weight-only value: business quantity, unit UUID
/// and unit rate remain authoritative even when actual weight is also captured.
enum PrimaryInput { businessQuantity, businessQuantityAndActualWeight }

/// How the optional actual-weight input is disclosed while quantity remains.
enum SecondaryPolicy { hidden, offered, visible }

class MeasurementCaptureProfile {
  MeasurementCaptureProfile({
    required this.goodsId,
    required this.operationFamily,
    required this.status,
    required this.primaryInput,
    required this.secondaryPolicy,
    required this.businessUnitId,
    this.businessUnitName,
    this.actualWeightUnitId,
    this.actualWeightUnitName,
    this.profileId,
    this.version = 0,
    this.evidenceCount = 0,
    this.confidence = 0,
    this.evidenceSummary,
  }) {
    _requireUuid(goodsId, 'goodsId');
    _requireUuid(businessUnitId, 'businessUnitId');
    if (profileId != null) _requireUuid(profileId!, 'profileId');
    if (actualWeightUnitId != null) {
      _requireUuid(actualWeightUnitId!, 'actualWeightUnitId');
    }
    if (actualWeightUnitName != null && actualWeightUnitId == null) {
      throw ArgumentError.value(
        actualWeightUnitName,
        'actualWeightUnitName',
        'cannot be authoritative without actualWeightUnitId',
      );
    }
    if ((capturesActualWeight || secondaryPolicy == SecondaryPolicy.visible) &&
        actualWeightUnitId == null) {
      throw ArgumentError.value(
        actualWeightUnitId,
        'actualWeightUnitId',
        'must be an explicit UUID before actual weight input is visible',
      );
    }
    if (primaryInput == PrimaryInput.businessQuantityAndActualWeight &&
        secondaryPolicy != SecondaryPolicy.visible) {
      throw ArgumentError.value(
        secondaryPolicy,
        'secondaryPolicy',
        'quantity + actual weight mode must expose the actual-weight input',
      );
    }
    if (version < 0) {
      throw ArgumentError.value(version, 'version', 'must not be negative');
    }
    if (evidenceCount < 0) {
      throw ArgumentError.value(
        evidenceCount,
        'evidenceCount',
        'must not be negative',
      );
    }
    if (!confidence.isFinite || confidence < 0 || confidence > 1) {
      throw ArgumentError.value(
        confidence,
        'confidence',
        'must be finite and between 0 and 1',
      );
    }
  }

  final String? profileId;
  final String goodsId;
  final OperationFamily operationFamily;
  final Status status;
  final PrimaryInput primaryInput;
  final SecondaryPolicy secondaryPolicy;
  final String businessUnitId;
  final String? businessUnitName;
  final String? actualWeightUnitId;
  final String? actualWeightUnitName;
  final int version;
  final int evidenceCount;
  final double confidence;
  final String? evidenceSummary;

  bool get capturesActualWeight =>
      primaryInput == PrimaryInput.businessQuantityAndActualWeight;

  bool get canSupplementActualWeight =>
      capturesActualWeight || secondaryPolicy != SecondaryPolicy.hidden;

  bool get initiallyShowsActualWeight =>
      capturesActualWeight || secondaryPolicy == SecondaryPolicy.visible;

  bool get isManual => status == Status.manualOverride;

  String get identityKey => '${operationFamily.code}|$goodsId';

  String get statusLabel => switch (status) {
    Status.unknown => '未学习',
    Status.provisional => '暂定',
    Status.confirmed => '已确定',
    Status.conflict => '计量习惯冲突',
    Status.manualOverride => '人工设置',
  };

  factory MeasurementCaptureProfile.fromJson(Map<String, dynamic> json) {
    return MeasurementCaptureProfile(
      profileId: _text(json['profileId'] ?? json['id']),
      goodsId: _requiredText(json['goodsId'], 'goodsId'),
      operationFamily: OperationFamilyCode.parse(json['operationFamily']),
      status: StatusCode.parse(json['status']),
      primaryInput: PrimaryInputCode.parse(json['primaryInput']),
      secondaryPolicy: SecondaryPolicyCode.parse(json['secondaryPolicy']),
      businessUnitId: _requiredText(json['businessUnitId'], 'businessUnitId'),
      businessUnitName: _text(json['businessUnitName']),
      actualWeightUnitId: _text(json['actualWeightUnitId']),
      actualWeightUnitName: _text(json['actualWeightUnitName']),
      version: (json['version'] as num?)?.toInt() ?? 0,
      evidenceCount:
          (json['activeEvidenceCount'] as num?)?.toInt() ??
          (json['evidenceCount'] as num?)?.toInt() ??
          0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      evidenceSummary: _text(json['evidenceSummary']),
    );
  }

  Map<String, dynamic> toJson() => {
    if (profileId != null) 'profileId': profileId,
    'goodsId': goodsId,
    'operationFamily': operationFamily.code,
    'status': status.code,
    'primaryInput': primaryInput.code,
    'secondaryPolicy': secondaryPolicy.code,
    'businessUnitId': businessUnitId,
    if (businessUnitName != null) 'businessUnitName': businessUnitName,
    if (actualWeightUnitId != null) 'actualWeightUnitId': actualWeightUnitId,
    if (actualWeightUnitName != null)
      'actualWeightUnitName': actualWeightUnitName,
    'version': version,
    'evidenceCount': evidenceCount,
    'confidence': confidence,
    if (evidenceSummary != null) 'evidenceSummary': evidenceSummary,
  };

  static bool isUuid(String? value) =>
      value != null &&
      RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
      ).hasMatch(value.trim());

  static void _requireUuid(String value, String field) {
    if (!isUuid(value)) {
      throw ArgumentError.value(value, field, 'must be a valid UUID');
    }
  }

  static String? _text(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static String _requiredText(Object? value, String field) {
    final text = _text(value);
    if (text == null) {
      throw ArgumentError.value(value, field, 'is required');
    }
    return text;
  }
}

extension OperationFamilyCode on OperationFamily {
  String get code => name.toUpperCase();

  static OperationFamily parse(Object? value) => _enumByCode(
    OperationFamily.values,
    value,
    (item) => item.code,
    'operationFamily',
  );
}

extension StatusCode on Status {
  String get code => switch (this) {
    Status.unknown => 'UNCLASSIFIED',
    Status.manualOverride => 'MANUAL_OVERRIDE',
    _ => name.toUpperCase(),
  };

  static Status parse(Object? value) =>
      _enumByCode(Status.values, value, (item) => item.code, 'status');
}

extension PrimaryInputCode on PrimaryInput {
  String get code => switch (this) {
    PrimaryInput.businessQuantity => 'BUSINESS_QUANTITY',
    PrimaryInput.businessQuantityAndActualWeight =>
      'BUSINESS_QUANTITY_AND_ACTUAL_WEIGHT',
  };

  static PrimaryInput parse(Object? value) => _enumByCode(
    PrimaryInput.values,
    value,
    (item) => item.code,
    'primaryInput',
  );
}

extension SecondaryPolicyCode on SecondaryPolicy {
  String get code => name.toUpperCase();

  static SecondaryPolicy parse(Object? value) => _enumByCode(
    SecondaryPolicy.values,
    value,
    (item) => item.code,
    'secondaryPolicy',
  );
}

T _enumByCode<T>(
  Iterable<T> values,
  Object? raw,
  String Function(T value) codeOf,
  String field,
) {
  final code = raw?.toString().trim().toUpperCase();
  for (final value in values) {
    if (codeOf(value) == code) return value;
  }
  throw ArgumentError.value(raw, field, 'has an unsupported value');
}
