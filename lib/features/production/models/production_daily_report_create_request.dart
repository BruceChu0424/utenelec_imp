import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'production_daily_report.dart';

/// The exact body that crossed the CREATE boundary, not a later editor snapshot.
/// The private JSON string prevents callers from mutating nested extension cells.
class FrozenDailyReportCreate {
  FrozenDailyReportCreate._({
    required this.bodyJson,
    required this.server,
    required this.userId,
    required this.actorId,
  }) {
    final body = requestBody;
    final key = body['idempotencyKey'];
    if (key is! String ||
        key.trim() != key ||
        key.length < 8 ||
        key.length > 128) {
      throw const FormatException('原创建标识无效');
    }
    idempotencyKey = key;
    requestHash = dailyReportCreateRequestHash(body);
    fullPayloadHash = dailyReportCreateFullPayloadHash(body, requestHash);
    bodyHash = sha256.convert(utf8.encode(bodyJson)).toString();
  }

  factory FrozenDailyReportCreate.capture({
    required Map<String, dynamic> body,
    required String server,
    required String userId,
    required String? actorId,
  }) => FrozenDailyReportCreate._(
    bodyJson: jsonEncode(body),
    server: server,
    userId: userId,
    actorId: actorId,
  );

  factory FrozenDailyReportCreate.restore(Map<String, dynamic> json) {
    if (json['schema'] != 1 ||
        json['bodyJson'] is! String ||
        json['server'] is! String ||
        json['userId'] is! String) {
      throw const FormatException('原创建请求尚未完整保留');
    }
    final frozen = FrozenDailyReportCreate._(
      bodyJson: json['bodyJson'] as String,
      server: json['server'] as String,
      userId: json['userId'] as String,
      actorId: json['actorId'] as String?,
    );
    if (json['bodyHash'] != frozen.bodyHash ||
        json['requestHash'] != frozen.requestHash ||
        json['fullPayloadHash'] != frozen.fullPayloadHash ||
        json['idempotencyKey'] != frozen.idempotencyKey) {
      throw const FormatException('原创建请求的本机证明不一致，不能改用当前输入核对');
    }
    return frozen;
  }

  final String bodyJson, server, userId;
  final String? actorId;
  late final String idempotencyKey, requestHash, fullPayloadHash, bodyHash;
  Map<String, dynamic> get requestBody =>
      Map<String, dynamic>.from(jsonDecode(bodyJson) as Map);

  bool belongsTo({
    required String server,
    required String userId,
    required String? actorId,
  }) =>
      this.server == server && this.userId == userId && this.actorId == actorId;

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'bodyJson': bodyJson,
    'bodyHash': bodyHash,
    'server': server,
    'userId': userId,
    'actorId': actorId,
    'idempotencyKey': idempotencyKey,
    'requestHash': requestHash,
    'fullPayloadHash': fullPayloadHash,
  };
}

class DailyReportCreateResolution {
  DailyReportCreateResolution.fromJson(Map<String, dynamic> json)
    : deleted =
          json['detail'] is Map && (json['detail'] as Map)['deleted'] == true,
      status = json['status'] as String?,
      idempotencyKey = json['idempotencyKey'] as String?,
      requestHash = json['requestHash'] as String?,
      fullPayloadVersion = json['fullPayloadVersion'] is int
          ? json['fullPayloadVersion'] as int
          : null,
      fullPayloadHash = json['fullPayloadHash'] as String?,
      reportId = json['reportId'] as String?,
      detail = json['detail'] is Map
          ? ProductionDailyReportDetail.fromJson(
              Map<String, dynamic>.from(json['detail'] as Map),
            )
          : null;

  final String? status, idempotencyKey, requestHash, fullPayloadHash, reportId;
  final int? fullPayloadVersion;
  final bool deleted;
  final ProductionDailyReportDetail? detail;
  bool _verified = false;
  bool get committed => status == 'COMMITTED';

  void verify(FrozenDailyReportCreate command) {
    _verified = false;
    if (idempotencyKey != command.idempotencyKey ||
        requestHash != command.requestHash) {
      throw const FormatException('回执不属于原创建请求');
    }
    switch (status) {
      case 'COMMITTED':
        if (fullPayloadVersion != 1 ||
            fullPayloadHash != command.fullPayloadHash ||
            reportId == null ||
            reportId!.isEmpty ||
            detail?.id != reportId) {
          throw const FormatException('回执的完整字段证明或单据身份不一致');
        }
      case 'LEGACY_UNCONFIRMED':
        if (reportId == null || detail?.id != reportId) {
          throw const FormatException('旧版回执的单据身份不一致');
        }
      case 'UNKNOWN':
        if (reportId != null || detail != null) {
          throw const FormatException('未确认回执带有无法核实的单据');
        }
      default:
        throw const FormatException('回执状态尚不支持，原提交继续保留');
    }
    _verified = committed;
  }

  Map<String, dynamic> toCheckpoint() {
    if (!committed || !_verified) throw StateError('未确认的创建不能生成已保存检查点');
    return {
      'status': status,
      'idempotencyKey': idempotencyKey,
      'requestHash': requestHash,
      'fullPayloadVersion': fullPayloadVersion,
      'fullPayloadHash': fullPayloadHash,
      'reportId': reportId,
    };
  }
}

String _fingerprint(List<String> parts) {
  parts.sort(); // Both Java String and Dart String use UTF-16 lexical ordering.
  final bytes = <int>[];
  for (final part in parts) {
    final encoded = utf8.encode(part);
    bytes.addAll(ascii.encode('${encoded.length}:'));
    bytes.addAll(encoded);
    bytes.add(10);
  }
  return sha256.convert(bytes).toString();
}

String _decimal(Object? value) {
  final match = RegExp(
    r'^([+-]?)(\d+)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$',
  ).firstMatch(value.toString());
  if (match == null) throw const FormatException('原请求包含无法核对的数值');
  var digits = '${match.group(2)}${match.group(3) ?? ''}'.replaceFirst(
    RegExp(r'^0+'),
    '',
  );
  if (digits.isEmpty) return '0';
  final exponent = int.parse(match.group(4) ?? '0');
  if (exponent.abs() > 10000) throw const FormatException('原请求数值超出核对范围');
  var scale = (match.group(3) ?? '').length - exponent;
  while (digits.endsWith('0')) {
    digits = digits.substring(0, digits.length - 1);
    scale--;
  }
  final sign = match.group(1) == '-' ? '-' : '';
  if (scale <= 0) return '$sign$digits${'0' * -scale}';
  if (digits.length <= scale) {
    return '${sign}0.${'0' * (scale - digits.length)}$digits';
  }
  final split = digits.length - scale;
  return '$sign${digits.substring(0, split)}.${digits.substring(split)}';
}

void _add(
  List<String> parts,
  String path,
  Object? value, [
  String type = 'STRING',
]) {
  final canonical = value == null
      ? 'NULL'
      : switch (type) {
          'DECIMAL' => 'DECIMAL:${_decimal(value)}',
          'UUID' => 'UUID:${value.toString().toLowerCase()}',
          _ => '$type:$value',
        };
  parts.add('$path=$canonical');
}

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value as Map);

/// Matches ProductionDailyReportService.createRequestHash V3, including its
/// explicit compatibility equivalences. Unsubmitted raw editor values are not used.
String dailyReportCreateRequestHash(Map<String, dynamic> body) {
  final parts = <String>[];
  _add(parts, 'schema', 'PRODUCTION-DAILY-REPORT-CREATE-V3');
  _add(parts, 'header.billDate', body['billDate'], 'DATE');
  for (final field in ['warehouseId', 'departmentId']) {
    _add(parts, 'header.$field', body[field], 'UUID');
  }
  _add(parts, 'header.workshopName', body['workshopName']);
  final workers = body['workerIds'] is List
      ? (body['workerIds'] as List)
            .map((id) => id.toString().toLowerCase())
            .toSet()
            .toList()
      : [
          if (body['workerId'] != null)
            body['workerId'].toString().toLowerCase(),
        ];
  _add(parts, 'header.workerIds.count', workers.length, 'NUMBER');
  for (var i = 0; i < workers.length; i++) {
    _add(parts, 'header.workerIds[$i]', workers[i], 'UUID');
  }
  _add(parts, 'header.supplierId', body['supplierId'], 'UUID');
  for (final field in ['remark', 'sourceDocNo']) {
    _add(parts, 'header.$field', body[field]);
  }
  final lines = body['items'] as List? ?? const [];
  _add(parts, 'lines.count', lines.length, 'NUMBER');
  for (var i = 0; i < lines.length; i++) {
    final path = 'lines[$i]';
    if (lines[i] == null) {
      _add(parts, path, null);
      continue;
    }
    final line = _map(lines[i]);
    _add(parts, '$path.lineNo', line['lineNo'] ?? i + 1, 'NUMBER');
    for (final field in ['goodsId', 'colorId', 'unitId']) {
      _add(parts, '$path.$field', line[field], 'UUID');
    }
    for (final field in ['unitRate', 'qty']) {
      _add(parts, '$path.$field', line[field], 'DECIMAL');
    }
    if (line['defectQty'] != null && _decimal(line['defectQty']!) != '0') {
      _add(parts, '$path.defectQty', line['defectQty'], 'DECIMAL');
    }
    for (final field in ['price', 'total', 'stotal']) {
      _add(parts, '$path.$field', line[field], 'DECIMAL');
    }
    for (final field in [
      'salesOrderItemId',
      'planItemId',
      'executionSegmentId',
      'executionSegmentSalesAllocationId',
    ]) {
      _add(parts, '$path.$field', line[field], 'UUID');
    }
    for (final field in ['fqcRecoveryAuthorizationId', 'supplementProofId']) {
      if (line[field] != null) _add(parts, '$path.$field', line[field], 'UUID');
    }
    if ((line['overLimitReason'] as String?)?.trim().isNotEmpty == true) {
      _add(parts, '$path.overLimitReason', line['overLimitReason']);
    }
    _add(parts, '$path.isFinal', line['isFinal'] == true, 'BOOLEAN');
    _add(parts, '$path.outboundNo', line['outboundNo']);
    for (final field in ['outboundQty', 'orderQty']) {
      _add(parts, '$path.$field', line[field], 'DECIMAL');
    }
    _add(parts, '$path.stepLegacyId', line['stepLegacyId'], 'NUMBER');
    _add(parts, '$path.orderDate', line['orderDate'], 'DATE');
    for (final field in ['boxes', 'perBoxQty', 'weight']) {
      _add(parts, '$path.$field', line[field], 'DECIMAL');
    }
    for (final field in ['clientName', 'sourceDocNo', 'remark']) {
      _add(parts, '$path.$field', line[field]);
    }
    final allocations = line['allocations'] as List? ?? const [];
    final warehouseOnly =
        allocations.length == 1 &&
        allocations.single is Map &&
        _map(allocations.single)['directTransferDemandId'] == null &&
        _map(allocations.single)['qty'] != null &&
        _decimal(_map(allocations.single)['qty']!) ==
            _decimal(line['qty'] ?? 0);
    if (allocations.isNotEmpty && !warehouseOnly) {
      _add(parts, '$path.allocations.count', allocations.length, 'NUMBER');
      for (var a = 0; a < allocations.length; a++) {
        final allocation = allocations[a] == null
            ? const <String, dynamic>{}
            : _map(allocations[a]);
        _add(
          parts,
          '$path.allocations[$a].directTransferDemandId',
          allocation['directTransferDemandId'],
          'UUID',
        );
        _add(parts, '$path.allocations[$a].qty', allocation['qty'], 'DECIMAL');
      }
    }
  }
  final materials = body['materialLines'] as List? ?? const [];
  if (materials.isNotEmpty) {
    _add(parts, 'materialLines.count', materials.length, 'NUMBER');
    for (var i = 0; i < materials.length; i++) {
      final path = 'materialLines[$i]';
      if (materials[i] == null) {
        _add(parts, path, null);
        continue;
      }
      final line = _map(materials[i]);
      _add(parts, '$path.demandId', line['demandId'], 'UUID');
      _add(parts, '$path.qtyBase', line['qtyBase'], 'DECIMAL');
      if (line['countedLeftoverQty'] != null) {
        _add(
          parts,
          '$path.countedLeftoverQty',
          line['countedLeftoverQty'],
          'DECIMAL',
        );
      }
    }
  }
  if (body['surplusReturnRequested'] == true) {
    _add(parts, 'header.surplusReturnRequested', true, 'BOOLEAN');
  }
  return _fingerprint(parts);
}

bool _javaWhitespace(int value) =>
    (value >= 9 && value <= 13) ||
    (value >= 28 && value <= 32) ||
    value == 0x1680 ||
    (value >= 0x2000 && value <= 0x2006) ||
    (value >= 0x2008 && value <= 0x200a) ||
    value == 0x2028 ||
    value == 0x2029 ||
    value == 0x205f ||
    value == 0x3000;

String? _javaStrip(String? value) {
  if (value == null) return null;
  var begin = 0, end = value.length;
  while (begin < end && _javaWhitespace(value.codeUnitAt(begin))) {
    begin++;
  }
  while (end > begin && _javaWhitespace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return begin == end ? null : value.substring(begin, end);
}

String dailyReportCreateFullPayloadHash(
  Map<String, dynamic> body, [
  String? nativeHash,
]) {
  final parts = <String>[];
  _add(parts, 'schema', 'PRODUCTION-DAILY-REPORT-CREATE-FULL-V1');
  _add(parts, 'nativeV3', nativeHash ?? dailyReportCreateRequestHash(body));
  final lines = body['items'] as List? ?? const [];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i] == null ? const <String, dynamic>{} : _map(lines[i]);
    final rawFields = line['platformFields'];
    final fields = rawFields == null
        ? const <String, dynamic>{}
        : _map(rawFields);
    final path = 'lines[$i].platformFields';
    _add(parts, '$path.sourceRecordId', fields['sourceRecordId'], 'UUID');
    _add(
      parts,
      '$path.expectedVersion',
      fields['expectedVersion'] ?? 0,
      'NUMBER',
    );
    final cells = fields['cells'] as List? ?? const [];
    if (cells.length > 32) throw const FormatException('原扩展字段超过协议上限');
    final sorted = <String, String?>{};
    for (final raw in cells) {
      final cell = _map(raw);
      final id = (cell['columnId'] as String?)?.toLowerCase();
      if (id == null || sorted.containsKey(id)) {
        throw const FormatException('原扩展字段标识缺失或重复');
      }
      sorted[id] = _javaStrip(cell['value'] as String?);
    }
    _add(parts, '$path.cells.count', sorted.length, 'NUMBER');
    for (final id in sorted.keys.toList()..sort()) {
      _add(parts, '$path.cells[$id].value', sorted[id]);
    }
  }
  return _fingerprint(parts);
}
