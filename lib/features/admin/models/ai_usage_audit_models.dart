// 使用记录与费用(usage-audit)的类型化模型: 与服务端 /api/admin/ai/usage-audit 的 wire 一一对应。
//
// 旧版 AiUsageAuditPanel 直接翻 Map 渲染; 独立页面(使用记录与费用页)改为强类型,
// 供汇总卡/按人员表/按记录表/详情面板共用。wire 字段缺失时按空值兜底, 不抛异常。
library;

/// 一行费用: basis=ACTUAL(按服务商账单核定) / ESTIMATED(按计费单价估算)。
class AiUsageAuditCost {
  const AiUsageAuditCost({
    required this.basis,
    required this.currency,
    required this.amount,
  });

  factory AiUsageAuditCost.fromJson(Map<String, dynamic> json) =>
      AiUsageAuditCost(
        basis: _text(json['basis']),
        currency: _text(json['currency']),
        amount: _text(json['amount']),
      );

  final String basis;
  final String currency;

  /// 金额原样字符串; 空=尚未核定(展示「费用尚未核定」)。
  final String amount;

  bool get pending => amount.isEmpty;
  bool get actual => basis == 'ACTUAL';
}

/// 汇总: 条数 / 模型调用次数 / 费用明细 / 未设单价无法计费的调用次数。
class AiUsageAuditMetrics {
  const AiUsageAuditMetrics({
    required this.uses,
    required this.calls,
    required this.unknownCostCalls,
    required this.costs,
  });

  factory AiUsageAuditMetrics.fromJson(Map<String, dynamic> json) =>
      AiUsageAuditMetrics(
        uses: _int(json['uses']),
        calls: _int(json['calls']),
        unknownCostCalls: _int(json['unknownCostCalls']),
        costs: [
          for (final row in _rows(json['costs']))
            AiUsageAuditCost.fromJson(row),
        ],
      );

  final int uses;
  final int calls;
  final int unknownCostCalls;
  final List<AiUsageAuditCost> costs;

  AiUsageAuditCost? costOf(bool actual) {
    for (final cost in costs) {
      if (cost.actual == actual) return cost;
    }
    return null;
  }
}

/// 按人员汇总一行(仅在不筛选使用人时服务端才下发)。
class AiUsageAuditUser {
  const AiUsageAuditUser({
    required this.userId,
    required this.name,
    required this.code,
    required this.metrics,
  });

  factory AiUsageAuditUser.fromJson(Map<String, dynamic> json) =>
      AiUsageAuditUser(
        userId: _text(json['userId']),
        name: _text(json['name']),
        code: _text(json['code']),
        metrics: AiUsageAuditMetrics.fromJson(json),
      );

  final String userId;
  final String name;
  final String code;
  final AiUsageAuditMetrics metrics;
}

/// 一条使用记录(问题可在服务端不保留, 费用与 token 可缺)。
class AiUsageAuditRecord {
  const AiUsageAuditRecord({
    required this.id,
    required this.userId,
    required this.name,
    required this.code,
    required this.question,
    required this.intent,
    required this.kind,
    required this.status,
    required this.createdAt,
    required this.providerNames,
    required this.models,
    required this.metrics,
    required this.inputTokens,
    required this.outputTokens,
  });

  factory AiUsageAuditRecord.fromJson(Map<String, dynamic> json) =>
      AiUsageAuditRecord(
        id: _text(json['id'], fallback: _text(json['jobId'])),
        userId: _text(json['userId']),
        name: _text(json['name']),
        code: _text(json['code']),
        question: _text(json['question']),
        intent: _text(json['intent']),
        kind: _text(json['kind']),
        status: _text(json['status']),
        createdAt: _text(json['createdAt']),
        providerNames: _texts(json['providerNames']),
        models: _texts(json['models']),
        metrics: AiUsageAuditMetrics.fromJson(json),
        inputTokens: _optionalInt(json['inputTokens']),
        outputTokens: _optionalInt(json['outputTokens']),
      );

  final String id;
  final String userId;
  final String name;
  final String code;

  /// 服务端可不留存问题原文(NON_WORK 拒答/未保留), 空串时展示占位。
  final String question;
  final String intent;
  final String kind;
  final String status;
  final String createdAt;
  final List<String> providerNames;
  final List<String> models;
  final AiUsageAuditMetrics metrics;

  /// null=模型未返回(与 0 区分, 展示「未返回」)。
  final int? inputTokens;
  final int? outputTokens;
}

/// GET /admin/ai/usage-audit 的一页结果。
class AiUsageAuditResult {
  const AiUsageAuditResult({
    required this.summary,
    required this.users,
    required this.records,
    required this.total,
  });

  factory AiUsageAuditResult.fromJson(Map<String, dynamic> json) =>
      AiUsageAuditResult(
        summary: AiUsageAuditMetrics.fromJson(
          json['summary'] is Map
              ? _rows([json['summary']]).first
              : const <String, dynamic>{},
        ),
        users: [
          for (final row in _rows(json['users']))
            AiUsageAuditUser.fromJson(row),
        ],
        records: [
          for (final row in _rows(json['records']))
            AiUsageAuditRecord.fromJson(row),
        ],
        total: _int(json['total']),
      );

  final AiUsageAuditMetrics summary;
  final List<AiUsageAuditUser> users;
  final List<AiUsageAuditRecord> records;

  /// 服务端总条数(分页用), 不是本页条数。
  final int total;
}

List<Map<String, dynamic>> _rows(Object? value) => value is List
    ? value
          .whereType<Map<dynamic, dynamic>>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList()
    : [];

List<String> _texts(Object? value) => value is List
    ? value.whereType<String>().where((text) => text.isNotEmpty).toList()
    : const [];

String _text(Object? value, {String fallback = ''}) =>
    value == null || value.toString().isEmpty ? fallback : value.toString();

int _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse(_text(value)) ?? 0;

int? _optionalInt(Object? value) => value == null
    ? null
    : (value is num ? value.toInt() : int.tryParse(value.toString()));
