// 主档批量命令(ADR-111)的请求条目与逐条结果。
//
// 对应后端 MasterBatchRequests / MasterBatchResult：一次请求、一个事务、
// 逐条返回 {id, label, ok, reason}。失败条目的 reason 是给人看的中文原因
// (被哪些单据/货品引用、已被他人修改、没有权限……)，页面逐条展示，不吞掉。

/// 批量命令的一条目标：业务 id + 列表行读到的乐观锁版本(无版本的主档传 null)。
class MasterBatchItem {
  const MasterBatchItem(this.id, [this.version]);

  final String id;
  final int? version;

  Map<String, dynamic> toJson() => {'id': id, 'version': ?version};
}

/// 一条记录的处理结果。
class MasterBatchItemResult {
  const MasterBatchItemResult({
    required this.id,
    required this.ok,
    this.label,
    this.reason,
  });

  final String id;

  /// 服务端读到的「编号 名称」；记录不存在/无权限时为空。
  final String? label;
  final bool ok;
  final String? reason;

  factory MasterBatchItemResult.fromJson(Map<String, dynamic> json) =>
      MasterBatchItemResult(
        id: json['id'] as String,
        label: json['label'] as String?,
        ok: json['ok'] == true,
        reason: json['reason'] as String?,
      );
}

/// 一次批量命令的整体结果。
class MasterBatchResult {
  const MasterBatchResult({
    required this.succeeded,
    required this.failed,
    required this.results,
  });

  final int succeeded;
  final int failed;
  final List<MasterBatchItemResult> results;

  List<MasterBatchItemResult> get failures =>
      results.where((r) => !r.ok).toList(growable: false);

  factory MasterBatchResult.fromJson(Map<String, dynamic> json) =>
      MasterBatchResult(
        succeeded: (json['succeeded'] as num?)?.toInt() ?? 0,
        failed: (json['failed'] as num?)?.toInt() ?? 0,
        results: [
          for (final r in (json['results'] as List? ?? const []))
            MasterBatchItemResult.fromJson(Map<String, dynamic>.from(r as Map)),
        ],
      );
}
