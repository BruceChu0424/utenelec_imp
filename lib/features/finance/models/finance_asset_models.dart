import '../../../shared/models/paged_result.dart';

enum FinanceAssetLedger { fixedAsset, deferredExpense }

extension FinanceAssetLedgerX on FinanceAssetLedger {
  String get basePath => switch (this) {
    FinanceAssetLedger.fixedAsset => '/finance/fixed-assets',
    FinanceAssetLedger.deferredExpense => '/finance/deferred-expenses',
  };

  String get apiValue => switch (this) {
    FinanceAssetLedger.fixedAsset => 'FIXED_ASSET',
    FinanceAssetLedger.deferredExpense => 'DEFERRED_EXPENSE',
  };

  String get label => switch (this) {
    FinanceAssetLedger.fixedAsset => '固定资产',
    FinanceAssetLedger.deferredExpense => '长期待摊',
  };

  String get amountLabel => switch (this) {
    FinanceAssetLedger.fixedAsset => '原值',
    FinanceAssetLedger.deferredExpense => '待摊总额',
  };
}

enum AssetPostingRunType { depreciation, amortization }

extension AssetPostingRunTypeX on AssetPostingRunType {
  String get apiValue => switch (this) {
    AssetPostingRunType.depreciation => 'DEPRECIATION',
    AssetPostingRunType.amortization => 'AMORTIZATION',
  };

  String get label => switch (this) {
    AssetPostingRunType.depreciation => '固定资产折旧',
    AssetPostingRunType.amortization => '长期待摊摊销',
  };

  FinanceAssetLedger get ledger => switch (this) {
    AssetPostingRunType.depreciation => FinanceAssetLedger.fixedAsset,
    AssetPostingRunType.amortization => FinanceAssetLedger.deferredExpense,
  };

  static AssetPostingRunType fromApi(Object? value) {
    return value?.toString().toUpperCase() == 'AMORTIZATION'
        ? AssetPostingRunType.amortization
        : AssetPostingRunType.depreciation;
  }
}

Map<String, dynamic> financeAssetPayload(Map<String, dynamic> response) {
  final data = response['data'];
  return data is Map<String, dynamic> ? data : response;
}

String _text(
  Map<String, dynamic> json,
  List<String> keys, [
  String fallback = '',
]) {
  for (final key in keys) {
    final value = json[key];
    if (value != null) return value.toString();
  }
  return fallback;
}

String? _nullableText(Map<String, dynamic> json, List<String> keys) {
  final value = _text(json, keys).trim();
  return value.isEmpty ? null : value;
}

int? _integer(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is num) return value.toInt();
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed;
  }
  return null;
}

bool _boolean(
  Map<String, dynamic> json,
  List<String> keys, [
  bool fallback = false,
]) {
  for (final key in keys) {
    final value = json[key];
    if (value is bool) return value;
    if (value != null) {
      final normalized = value.toString().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
  }
  return fallback;
}

String _decimal(
  Map<String, dynamic> json,
  List<String> keys, [
  String fallback = '0',
]) {
  // Deliberately never parses through double: BigDecimal strings remain exact.
  return _text(json, keys, fallback);
}

List<Map<String, dynamic>> _maps(Object? value) {
  if (value is! List<dynamic>) return const [];
  return value
      .whereType<Map<Object?, Object?>>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList(growable: false);
}

Set<String> _actions(Object? value) {
  if (value is! List) return const <String>{};
  return value
      .map((item) => item.toString().trim().toUpperCase())
      .where((item) => item.isNotEmpty)
      .toSet();
}

/// Thousands-separator formatting that keeps the source decimal string exact.
String formatFinanceDecimal(String? source, {int minimumFractionDigits = 2}) {
  final raw = (source ?? '').trim();
  if (raw.isEmpty) return '—';
  final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d+))?$').firstMatch(raw);
  if (match == null) return raw;
  final sign = match.group(1)!;
  final integer = match.group(2)!;
  var fraction = match.group(3) ?? '';
  if (fraction.length < minimumFractionDigits) {
    fraction = fraction.padRight(minimumFractionDigits, '0');
  }
  final grouped = integer.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return fraction.isEmpty ? '$sign$grouped' : '$sign$grouped.$fraction';
}

class FinanceAssetQuery {
  const FinanceAssetQuery({
    this.page = 1,
    this.size = 20,
    this.q,
    this.status,
    this.categoryId,
    this.departmentId,
  });

  final int page;
  final int size;
  final String? q;
  final String? status;
  final String? categoryId;
  final String? departmentId;

  Map<String, dynamic> toQuery() => <String, dynamic>{
    'page': page,
    'size': size,
    if (q?.trim().isNotEmpty ?? false) 'q': q!.trim(),
    if (status?.trim().isNotEmpty ?? false) 'status': status!.trim(),
    if (categoryId?.trim().isNotEmpty ?? false)
      'categoryId': categoryId!.trim(),
    if (departmentId?.trim().isNotEmpty ?? false)
      'departmentId': departmentId!.trim(),
  };

  FinanceAssetQuery copyWith({
    int? page,
    int? size,
    String? q,
    bool clearQ = false,
    String? status,
    bool clearStatus = false,
    String? categoryId,
    bool clearCategoryId = false,
    String? departmentId,
    bool clearDepartmentId = false,
  }) {
    return FinanceAssetQuery(
      page: page ?? this.page,
      size: size ?? this.size,
      q: clearQ ? null : (q ?? this.q),
      status: clearStatus ? null : (status ?? this.status),
      categoryId: clearCategoryId ? null : (categoryId ?? this.categoryId),
      departmentId: clearDepartmentId
          ? null
          : (departmentId ?? this.departmentId),
    );
  }
}

class FinanceAssetOverview {
  const FinanceAssetOverview({
    required this.originalValue,
    required this.netBookValue,
    required this.deferredBalance,
    required this.pendingOrExceptionCount,
    this.pendingCount = 0,
    this.exceptionCount = 0,
    this.asOf,
  });

  final String originalValue;
  final String netBookValue;
  final String deferredBalance;
  final int pendingOrExceptionCount;
  final int pendingCount;
  final int exceptionCount;
  final String? asOf;

  factory FinanceAssetOverview.fromJson(Map<String, dynamic> source) {
    final json = financeAssetPayload(source);
    final pending =
        _integer(json, const [
          'pendingCount',
          'pendingApprovalCount',
          'monthPendingCount',
        ]) ??
        0;
    final exceptions =
        _integer(json, const [
          'exceptionCount',
          'monthExceptionCount',
          'blockingExceptionCount',
        ]) ??
        0;
    return FinanceAssetOverview(
      originalValue: _decimal(json, const [
        'originalValue',
        'originalValueTotal',
        'totalOriginalValue',
        'fixedAssetOriginalValue',
      ]),
      netBookValue: _decimal(json, const [
        'netBookValue',
        'bookValue',
        'fixedAssetNetValue',
        'totalNetBookValue',
      ]),
      deferredBalance: _decimal(json, const [
        'deferredBalance',
        'remainingDeferredAmount',
        'deferredExpenseBalance',
      ]),
      pendingOrExceptionCount:
          _integer(json, const [
            'pendingOrExceptionCount',
            'attentionCount',
            'monthAttentionCount',
          ]) ??
          pending + exceptions,
      pendingCount: pending,
      exceptionCount: exceptions,
      asOf: _nullableText(json, const ['asOf', 'generatedAt', 'period']),
    );
  }
}

class FinanceAssetSummary {
  const FinanceAssetSummary({
    required this.id,
    required this.ledger,
    required this.code,
    required this.name,
    required this.status,
    required this.originalValue,
    required this.totalAmount,
    required this.netBookValue,
    required this.remainingAmount,
    required this.allowedActions,
    this.categoryId,
    this.categoryName,
    this.departmentId,
    this.departmentName,
    this.approvalStatus,
    this.usefulMonths,
    this.salvageRate,
    this.startPeriod,
    this.acquisitionDate,
    this.acceptanceDate,
    this.readyForUseDate,
    this.serialNumber,
    this.assetTag,
    this.costCenterCode,
    this.benefitStartDate,
    this.benefitEndDate,
    this.location,
    this.custodianId,
    this.custodianName,
    this.sourceType,
    this.sourceRef,
    this.sourceId,
    this.sourceLineRef,
    this.sourceDocumentDate,
    this.remark,
    this.version,
  });

  final String id;
  final FinanceAssetLedger ledger;
  final String code;
  final String name;
  final String status;
  final String originalValue;
  final String totalAmount;
  final String netBookValue;
  final String remainingAmount;
  final Set<String> allowedActions;
  final String? categoryId;
  final String? categoryName;
  final String? departmentId;
  final String? departmentName;
  final String? approvalStatus;
  final int? usefulMonths;
  final String? salvageRate;
  final String? startPeriod;
  final String? acquisitionDate;
  final String? acceptanceDate;
  final String? readyForUseDate;
  final String? serialNumber;
  final String? assetTag;
  final String? costCenterCode;
  final String? benefitStartDate;
  final String? benefitEndDate;
  final String? location;
  final String? custodianId;
  final String? custodianName;
  final String? sourceType;
  final String? sourceRef;
  final String? sourceId;
  final String? sourceLineRef;
  final String? sourceDocumentDate;
  final String? remark;
  final int? version;

  String get displayedBalance =>
      ledger == FinanceAssetLedger.fixedAsset ? netBookValue : remainingAmount;

  factory FinanceAssetSummary.fromJson(
    Map<String, dynamic> json,
    FinanceAssetLedger ledger,
  ) {
    final category = json['category'];
    final department = json['department'];
    final custodian = json['custodian'];
    return FinanceAssetSummary(
      id: _text(json, const ['id', 'assetId', 'expenseId']),
      ledger: ledger,
      code: _text(json, const ['code', 'assetCode', 'expenseCode']),
      name: _text(json, const ['name', 'assetName', 'expenseName']),
      status: _text(json, const ['status', 'lifecycleStatus'], 'DRAFT'),
      originalValue: _decimal(json, const ['originalValue', 'original_value']),
      totalAmount: _decimal(json, const ['totalAmount', 'total_amount']),
      netBookValue: _decimal(json, const [
        'netBookValue',
        'bookValue',
        'net_value',
      ]),
      remainingAmount: _decimal(json, const [
        'remainingAmount',
        'remainingBalance',
        'unamortizedAmount',
      ]),
      allowedActions: _actions(json['allowedActions']),
      categoryId:
          _nullableText(json, const ['categoryId']) ??
          (category is Map ? category['id']?.toString() : null),
      categoryName:
          _nullableText(json, const ['categoryName']) ??
          (category is Map ? category['name']?.toString() : null),
      departmentId:
          _nullableText(json, const ['departmentId']) ??
          (department is Map ? department['id']?.toString() : null),
      departmentName:
          _nullableText(json, const ['departmentName']) ??
          (department is Map ? department['name']?.toString() : null),
      approvalStatus: _nullableText(json, const [
        'approvalStatus',
        'reviewStatus',
      ]),
      usefulMonths: _integer(json, const [
        'usefulMonths',
        'amortizationMonths',
        'useful_months',
      ]),
      salvageRate: _nullableText(json, const ['salvageRate', 'salvage_rate']),
      startPeriod: _nullableText(json, const ['startPeriod', 'start_period']),
      acquisitionDate: _nullableText(json, const ['acquisitionDate']),
      acceptanceDate: _nullableText(json, const ['acceptanceDate']),
      readyForUseDate: _nullableText(json, const [
        'readyForUseDate',
        'ready_for_use_date',
      ]),
      serialNumber: _nullableText(json, const ['serialNumber']),
      assetTag: _nullableText(json, const ['assetTag']),
      costCenterCode: _nullableText(json, const ['costCenterCode']),
      benefitStartDate: _nullableText(json, const [
        'benefitStartDate',
        'benefitDate',
        'benefit_start_date',
      ]),
      benefitEndDate: _nullableText(json, const ['benefitEndDate']),
      location: _nullableText(json, const ['location', 'useLocation']),
      custodianId:
          _nullableText(json, const ['custodianId']) ??
          (custodian is Map ? custodian['id']?.toString() : null),
      custodianName:
          _nullableText(json, const ['custodianName']) ??
          (custodian is Map ? custodian['name']?.toString() : null),
      sourceType: _nullableText(json, const [
        'sourceType',
        'sourceDocumentType',
      ]),
      sourceRef: _nullableText(json, const [
        'sourceRef',
        'sourceDocumentNo',
        'sourceReference',
      ]),
      sourceId: _nullableText(json, const ['sourceId']),
      sourceLineRef: _nullableText(json, const ['sourceLineRef']),
      sourceDocumentDate: _nullableText(json, const ['sourceDocumentDate']),
      remark: _nullableText(json, const ['remark', 'notes']),
      version: _integer(json, const ['version', 'expectedVersion']),
    );
  }
}

class FinanceAssetBook {
  const FinanceAssetBook({
    required this.bookType,
    required this.originalValue,
    required this.accumulatedAmount,
    required this.netValue,
    this.monthlyAmount,
    this.startPeriod,
  });

  final String bookType;
  final String originalValue;
  final String accumulatedAmount;
  final String netValue;
  final String? monthlyAmount;
  final String? startPeriod;

  factory FinanceAssetBook.fromJson(Map<String, dynamic> json) =>
      FinanceAssetBook(
        bookType: _text(json, const ['bookType', 'bookName', 'type'], '企业账簿'),
        originalValue: _decimal(json, const ['originalValue', 'totalAmount']),
        accumulatedAmount: _decimal(json, const [
          'accumulatedAmount',
          'accumulatedDepreciation',
          'accumulatedAmortization',
        ]),
        netValue: _decimal(json, const [
          'netValue',
          'netBookValue',
          'remainingAmount',
        ]),
        monthlyAmount: _nullableText(json, const [
          'monthlyAmount',
          'monthlyDepreciation',
          'monthlyAmortization',
        ]),
        startPeriod: _nullableText(json, const ['startPeriod']),
      );
}

class FinanceAssetScheduleLine {
  const FinanceAssetScheduleLine({
    required this.period,
    required this.openingBalance,
    required this.amount,
    required this.accumulatedAmount,
    required this.closingBalance,
    required this.status,
    this.voucherNo,
  });

  final String period;
  final String openingBalance;
  final String amount;
  final String accumulatedAmount;
  final String closingBalance;
  final String status;
  final String? voucherNo;

  factory FinanceAssetScheduleLine.fromJson(Map<String, dynamic> json) =>
      FinanceAssetScheduleLine(
        period: _text(json, const ['period', 'postingPeriod']),
        openingBalance: _decimal(json, const [
          'openingBalance',
          'openingAmount',
        ]),
        amount: _decimal(json, const [
          'amount',
          'depreciationAmount',
          'amortizationAmount',
        ]),
        accumulatedAmount: _decimal(json, const ['accumulatedAmount']),
        closingBalance: _decimal(json, const [
          'closingBalance',
          'remainingAmount',
          'netBookValue',
        ]),
        status: _text(json, const ['status'], 'PLANNED'),
        voucherNo: _nullableText(json, const ['voucherNo', 'voucherNumber']),
      );
}

class FinanceAssetTrailStep {
  const FinanceAssetTrailStep({
    required this.action,
    required this.status,
    this.actorName,
    this.comment,
    this.at,
  });
  final String action;
  final String status;
  final String? actorName;
  final String? comment;
  final String? at;

  factory FinanceAssetTrailStep.fromJson(Map<String, dynamic> json) =>
      FinanceAssetTrailStep(
        action: _text(json, const ['action', 'stepName', 'title']),
        status: _text(json, const ['status'], 'COMPLETED'),
        actorName: _nullableText(json, const [
          'actorName',
          'operatorName',
          'approverName',
        ]),
        comment: _nullableText(json, const ['comment', 'reason', 'remark']),
        at: _nullableText(json, const ['at', 'actedAt', 'createdAt']),
      );
}

class FinanceAssetEvent {
  const FinanceAssetEvent({
    required this.title,
    this.type,
    this.description,
    this.operatorName,
    this.at,
  });
  final String title;
  final String? type;
  final String? description;
  final String? operatorName;
  final String? at;

  factory FinanceAssetEvent.fromJson(Map<String, dynamic> json) =>
      FinanceAssetEvent(
        title: _text(json, const ['title', 'action', 'eventType'], '资产事件'),
        type: _nullableText(json, const ['type', 'eventType']),
        description: _nullableText(json, const [
          'description',
          'reason',
          'remark',
        ]),
        operatorName: _nullableText(json, const ['operatorName', 'actorName']),
        at: _nullableText(json, const ['at', 'occurredAt', 'createdAt']),
      );
}

class FinanceAssetDetail {
  const FinanceAssetDetail({
    required this.summary,
    required this.books,
    required this.schedule,
    required this.approvalSteps,
    required this.events,
    required this.voucherNumbers,
    required this.documentReferences,
  });

  final FinanceAssetSummary summary;
  final List<FinanceAssetBook> books;
  final List<FinanceAssetScheduleLine> schedule;
  final List<FinanceAssetTrailStep> approvalSteps;
  final List<FinanceAssetEvent> events;
  final List<String> voucherNumbers;
  final List<String> documentReferences;

  factory FinanceAssetDetail.fromJson(
    Map<String, dynamic> source,
    FinanceAssetLedger ledger,
  ) {
    final json = financeAssetPayload(source);
    final summarySource = json['summary'] is Map
        ? Map<String, dynamic>.from(json['summary'] as Map)
        : Map<String, dynamic>.from(json);
    if (summarySource['allowedActions'] == null &&
        json['allowedActions'] != null) {
      summarySource['allowedActions'] = json['allowedActions'];
    }
    var bookMaps = _maps(json['books']);
    if (bookMaps.isEmpty) bookMaps = _maps(json['balances']);
    final voucherValues = <Object?>[
      ...?json['voucherNumbers'] is List
          ? json['voucherNumbers'] as List
          : null,
      ..._maps(
        json['vouchers'],
      ).map((item) => item['voucherNo'] ?? item['number']),
    ];
    final documentValues = <Object?>[
      ...?json['documentReferences'] is List
          ? json['documentReferences'] as List
          : null,
      ..._maps(
        json['documents'],
      ).map((item) => item['reference'] ?? item['name']),
    ];
    return FinanceAssetDetail(
      summary: FinanceAssetSummary.fromJson(summarySource, ledger),
      books: bookMaps.map(FinanceAssetBook.fromJson).toList(growable: false),
      schedule: _maps(
        json['schedule'],
      ).map(FinanceAssetScheduleLine.fromJson).toList(growable: false),
      approvalSteps: _maps(
        json['approvalSteps'],
      ).map(FinanceAssetTrailStep.fromJson).toList(growable: false),
      events: _maps(
        json['events'],
      ).map(FinanceAssetEvent.fromJson).toList(growable: false),
      voucherNumbers: voucherValues
          .map((item) => item?.toString().trim() ?? '')
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList(growable: false),
      documentReferences: documentValues
          .map((item) => item?.toString().trim() ?? '')
          .where((item) => item.isNotEmpty)
          .toSet()
          .toList(growable: false),
    );
  }
}

class FinanceAssetDraftInput {
  const FinanceAssetDraftInput({
    required this.ledger,
    required this.categoryId,
    required this.name,
    required this.amount,
    required this.usefulMonths,
    required this.departmentId,
    this.code,
    this.startPeriod,
    this.salvageRate,
    this.acquisitionDate,
    this.acceptanceDate,
    this.readyForUseDate,
    this.serialNumber,
    this.assetTag,
    this.costCenterCode,
    this.benefitStartDate,
    this.benefitEndDate,
    this.location,
    this.custodianId,
    this.responsibleEmployeeId,
    this.sourceType,
    this.sourceId,
    this.sourceRef,
    this.sourceLineRef,
    this.sourceDocumentDate,
    this.remark,
    this.expectedVersion,
  });

  final FinanceAssetLedger ledger;
  final String? code;
  final String? categoryId;
  final String name;
  final String amount;
  final int usefulMonths;
  final String? salvageRate;
  final String? startPeriod;
  final String? acquisitionDate;
  final String? acceptanceDate;
  final String? readyForUseDate;
  final String? serialNumber;
  final String? assetTag;
  final String? costCenterCode;
  final String? benefitStartDate;
  final String? benefitEndDate;
  final String departmentId;
  final String? location;
  final String? custodianId;
  final String? responsibleEmployeeId;
  final String? sourceType;
  final String? sourceId;
  final String? sourceRef;
  final String? sourceLineRef;
  final String? sourceDocumentDate;
  final String? remark;
  final int? expectedVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (code?.trim().isNotEmpty == true) 'code': code!.trim(),
    if (categoryId?.trim().isNotEmpty == true) 'categoryId': categoryId!.trim(),
    'name': name.trim(),
    if (ledger == FinanceAssetLedger.fixedAsset) 'originalValue': amount.trim(),
    if (ledger == FinanceAssetLedger.deferredExpense)
      'totalAmount': amount.trim(),
    'usefulMonths': usefulMonths,
    if (ledger == FinanceAssetLedger.fixedAsset &&
        salvageRate?.trim().isNotEmpty == true)
      'salvageRate': salvageRate!.trim(),
    if (startPeriod?.trim().isNotEmpty == true)
      'startPeriod': startPeriod!.trim(),
    if (ledger == FinanceAssetLedger.fixedAsset &&
        acquisitionDate?.trim().isNotEmpty == true)
      'acquisitionDate': acquisitionDate!.trim(),
    if (ledger == FinanceAssetLedger.fixedAsset &&
        acceptanceDate?.trim().isNotEmpty == true)
      'acceptanceDate': acceptanceDate!.trim(),
    if (ledger == FinanceAssetLedger.fixedAsset &&
        readyForUseDate?.trim().isNotEmpty == true)
      'readyForUseDate': readyForUseDate!.trim(),
    if (ledger == FinanceAssetLedger.fixedAsset &&
        serialNumber?.trim().isNotEmpty == true)
      'serialNumber': serialNumber!.trim(),
    if (ledger == FinanceAssetLedger.fixedAsset &&
        assetTag?.trim().isNotEmpty == true)
      'assetTag': assetTag!.trim(),
    if (costCenterCode?.trim().isNotEmpty == true)
      'costCenterCode': costCenterCode!.trim(),
    if (ledger == FinanceAssetLedger.deferredExpense &&
        benefitStartDate?.trim().isNotEmpty == true)
      'benefitStartDate': benefitStartDate!.trim(),
    if (ledger == FinanceAssetLedger.deferredExpense &&
        benefitEndDate?.trim().isNotEmpty == true)
      'benefitEndDate': benefitEndDate!.trim(),
    'departmentId': departmentId.trim(),
    if (location?.trim().isNotEmpty == true) 'location': location!.trim(),
    if (ledger == FinanceAssetLedger.fixedAsset &&
        custodianId?.trim().isNotEmpty == true)
      'custodianId': custodianId!.trim(),
    if (ledger == FinanceAssetLedger.deferredExpense &&
        responsibleEmployeeId?.trim().isNotEmpty == true)
      'responsibleEmployeeId': responsibleEmployeeId!.trim(),
    if (sourceType?.trim().isNotEmpty == true) 'sourceType': sourceType!.trim(),
    if (sourceId?.trim().isNotEmpty == true) 'sourceId': sourceId!.trim(),
    if (sourceRef?.trim().isNotEmpty == true) 'sourceRef': sourceRef!.trim(),
    if (sourceLineRef?.trim().isNotEmpty == true)
      'sourceLineRef': sourceLineRef!.trim(),
    if (sourceDocumentDate?.trim().isNotEmpty == true)
      'sourceDocumentDate': sourceDocumentDate!.trim(),
    if (remark?.trim().isNotEmpty == true) 'remark': remark!.trim(),
    if (expectedVersion != null) 'expectedVersion': expectedVersion,
  };
}

class FinanceAssetWorkflowRequest {
  const FinanceAssetWorkflowRequest({
    this.reason,
    this.expectedVersion,
    this.targetDepartmentId,
    this.location,
    this.custodianId,
    this.effectiveDate,
    this.operatingStatus,
    this.proceedsAmount,
    this.evidenceReference,
  });

  final String? reason;
  final int? expectedVersion;
  final String? targetDepartmentId;
  final String? location;
  final String? custodianId;
  final String? effectiveDate;
  final String? operatingStatus;
  final String? proceedsAmount;
  final String? evidenceReference;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (reason?.trim().isNotEmpty == true) 'reason': reason!.trim(),
    if (expectedVersion != null) 'expectedVersion': expectedVersion,
    if (targetDepartmentId?.trim().isNotEmpty == true)
      'targetDepartmentId': targetDepartmentId!.trim(),
    if (location?.trim().isNotEmpty == true) 'location': location!.trim(),
    if (custodianId?.trim().isNotEmpty == true)
      'custodianId': custodianId!.trim(),
    if (effectiveDate?.trim().isNotEmpty == true)
      'effectiveDate': effectiveDate!.trim(),
    if (operatingStatus?.trim().isNotEmpty == true)
      'operatingStatus': operatingStatus!.trim(),
    if (proceedsAmount?.trim().isNotEmpty == true)
      'proceedsAmount': proceedsAmount!.trim(),
    if (evidenceReference?.trim().isNotEmpty == true)
      'evidenceReference': evidenceReference!.trim(),
  };
}

class FinanceAssetWorkflowResponse {
  const FinanceAssetWorkflowResponse({
    required this.id,
    required this.status,
    required this.allowedActions,
    this.message,
    this.version,
  });
  final String id;
  final String status;
  final Set<String> allowedActions;
  final String? message;
  final int? version;

  factory FinanceAssetWorkflowResponse.fromJson(Map<String, dynamic> source) {
    final json = financeAssetPayload(source);
    return FinanceAssetWorkflowResponse(
      id: _text(json, const ['id', 'assetId', 'expenseId']),
      status: _text(json, const ['status', 'lifecycleStatus']),
      allowedActions: _actions(json['allowedActions']),
      message: _nullableText(json, const ['message']),
      version: _integer(json, const ['version']),
    );
  }
}

class AssetPostingMessage {
  const AssetPostingMessage({
    required this.message,
    this.code,
    this.severity = 'ERROR',
    this.assetId,
  });
  final String message;
  final String? code;
  final String severity;
  final String? assetId;

  bool get isBlocking => severity.toUpperCase() != 'WARNING';

  factory AssetPostingMessage.fromJson(Map<String, dynamic> json) =>
      AssetPostingMessage(
        message: _text(json, const ['message', 'description', 'reason']),
        code: _nullableText(json, const ['code', 'exceptionCode']),
        severity: _text(json, const ['severity', 'level'], 'ERROR'),
        assetId: _nullableText(json, const ['objectId', 'assetId', 'itemId']),
      );
}

class AssetPostingLine {
  const AssetPostingLine({
    required this.assetId,
    required this.code,
    required this.name,
    required this.amount,
    required this.status,
    this.message,
  });
  final String assetId;
  final String code;
  final String name;
  final String amount;
  final String status;
  final String? message;

  factory AssetPostingLine.fromJson(Map<String, dynamic> json) =>
      AssetPostingLine(
        assetId: _text(json, const ['objectId', 'assetId', 'itemId', 'id']),
        code: _text(json, const ['code', 'assetCode', 'expenseCode']),
        name: _text(json, const ['name', 'assetName', 'expenseName']),
        amount: _decimal(json, const ['amount', 'postingAmount']),
        status: _text(json, const ['status'], 'READY'),
        message: _nullableText(json, const ['message', 'exceptionMessage']),
      );
}

class AssetPostingPreview {
  const AssetPostingPreview({
    required this.runId,
    required this.status,
    required this.token,
    required this.count,
    required this.totalAmount,
    required this.warnings,
    required this.errors,
    required this.lines,
    this.allowedActions = const <String>{},
    this.version,
  });

  final String runId;
  final String status;
  final String token;
  final int count;
  final String totalAmount;
  final List<AssetPostingMessage> warnings;
  final List<AssetPostingMessage> errors;
  final List<AssetPostingLine> lines;
  final Set<String> allowedActions;
  final int? version;

  bool get canSubmit => runId.isNotEmpty && token.isNotEmpty && errors.isEmpty;

  factory AssetPostingPreview.fromJson(Map<String, dynamic> source) {
    final json = financeAssetPayload(source);
    final warningItems = _maps(
      json['warnings'],
    ).map(AssetPostingMessage.fromJson).toList();
    final errorItems = _maps(
      json['errors'],
    ).map(AssetPostingMessage.fromJson).toList();
    for (final item in _maps(
      json['exceptions'],
    ).map(AssetPostingMessage.fromJson)) {
      (item.isBlocking ? errorItems : warningItems).add(item);
    }
    return AssetPostingPreview(
      runId: _text(json, const ['runId', 'id']),
      status: _text(json, const ['status'], 'PREVIEWED'),
      token: _text(json, const ['token', 'previewToken']),
      count: _integer(json, const ['count', 'itemCount', 'lineCount']) ?? 0,
      totalAmount: _decimal(json, const ['totalAmount']),
      warnings: List.unmodifiable(warningItems),
      errors: List.unmodifiable(errorItems),
      lines: _maps(
        json['lines'],
      ).map(AssetPostingLine.fromJson).toList(growable: false),
      allowedActions: _actions(json['allowedActions']),
      version: _integer(json, const ['version']),
    );
  }
}

class AssetPostingRun {
  const AssetPostingRun({
    required this.id,
    required this.runType,
    required this.period,
    required this.status,
    required this.itemCount,
    required this.totalAmount,
    required this.allowedActions,
    this.token,
    this.version,
    this.voucherNo,
    this.createdAt,
  });
  final String id;
  final AssetPostingRunType runType;
  final String period;
  final String status;
  final int itemCount;
  final String totalAmount;
  final Set<String> allowedActions;
  final String? token;
  final int? version;
  final String? voucherNo;
  final String? createdAt;

  factory AssetPostingRun.fromJson(Map<String, dynamic> json) =>
      AssetPostingRun(
        id: _text(json, const ['id', 'runId']),
        runType: AssetPostingRunTypeX.fromApi(json['runType']),
        period: _text(json, const ['period']),
        status: _text(json, const ['status']),
        itemCount: _integer(json, const ['itemCount', 'count']) ?? 0,
        totalAmount: _decimal(json, const ['totalAmount']),
        allowedActions: _actions(json['allowedActions']),
        token: _nullableText(json, const ['token', 'previewToken']),
        version: _integer(json, const ['version']),
        voucherNo: _nullableText(json, const ['voucherNo', 'voucherNumber']),
        createdAt: _nullableText(json, const ['createdAt']),
      );
}

class AssetPeriod {
  const AssetPeriod({
    required this.period,
    required this.status,
    required this.closed,
    required this.allowedActions,
    this.closedAt,
    this.reason,
    this.version,
  });
  final String period;
  final String status;
  final bool closed;
  final Set<String> allowedActions;
  final String? closedAt;
  final String? reason;
  final int? version;

  factory AssetPeriod.fromJson(Map<String, dynamic> json) {
    final status = _text(json, const ['status'], 'OPEN');
    return AssetPeriod(
      period: _text(json, const ['period']),
      status: status,
      closed: _boolean(json, const [
        'closed',
        'isClosed',
      ], status.toUpperCase() == 'CLOSED'),
      allowedActions: _actions(json['allowedActions']),
      closedAt: _nullableText(json, const ['closedAt']),
      reason: _nullableText(json, const ['reason', 'closeReason']),
      version: _integer(json, const ['version']),
    );
  }
}

PagedResult<T> financePagedResult<T>(
  Map<String, dynamic> source,
  T Function(Map<String, dynamic>) fromJson, {
  String? fallbackItemsKey,
}) {
  final json = financeAssetPayload(source);
  if (json['items'] is List) return PagedResult<T>.fromJson(json, fromJson);
  final items = fallbackItemsKey == null ? null : json[fallbackItemsKey];
  return PagedResult<T>.fromJson(<String, dynamic>{
    ...json,
    'items': items is List<dynamic> ? items : const <Object?>[],
  }, fromJson);
}
