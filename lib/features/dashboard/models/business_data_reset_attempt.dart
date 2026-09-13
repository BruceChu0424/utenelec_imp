/// A local receipt for an explicitly submitted reset, never an authorization or
/// a command to replay. It survives token expiry so the original operator can
/// reconcile the server's completion record after signing in again.
class BusinessDataResetAttempt {
  const BusinessDataResetAttempt({
    required this.id,
    required this.server,
    required this.operatorId,
    required this.startedAt,
  });

  final String id;
  final String server;
  final String operatorId;
  final DateTime startedAt;

  factory BusinessDataResetAttempt.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final server = json['server'];
    final operatorId = json['operatorId'];
    final startedAt = DateTime.tryParse(json['startedAt']?.toString() ?? '');
    if (json['version'] != 1 ||
        id is! String ||
        id.isEmpty ||
        server is! String ||
        server.isEmpty ||
        operatorId is! String ||
        operatorId.isEmpty ||
        startedAt == null) {
      throw const FormatException('清空请求的本地待确认记录不完整');
    }
    return BusinessDataResetAttempt(
      id: id,
      server: server,
      operatorId: operatorId,
      startedAt: startedAt.toUtc(),
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'server': server,
    'operatorId': operatorId,
    'startedAt': startedAt.toUtc().toIso8601String(),
  };

  bool matchesCompletion({
    required String currentServer,
    required String currentOperatorId,
    required String? completedBy,
    required String? completedAttemptId,
    required DateTime? finishedAt,
  }) {
    // Time is context for the operator, never a substitute for the exact
    // receipt ID: another tab can reset the same server with the same account.
    return server == currentServer &&
        operatorId == currentOperatorId &&
        completedBy == operatorId &&
        completedAttemptId == id &&
        finishedAt != null;
  }
}
