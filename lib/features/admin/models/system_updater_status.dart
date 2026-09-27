/// Server-confirmed update schedule; reading it never contacts OSS.
class SystemUpdaterStatus {
  const SystemUpdaterStatus({
    required this.requestedIntervalDays,
    required this.available,
    required this.stale,
    required this.lastResult,
    this.requestedUpdatedAt,
    this.appliedIntervalDays,
    this.configUpdatedAt,
    this.checkedAt,
    this.nextCheckAt,
    this.lastAttemptAt,
    this.error,
  });

  final int requestedIntervalDays;
  final String? requestedUpdatedAt;
  final int? appliedIntervalDays;
  final String? configUpdatedAt;
  final String? checkedAt;
  final String? nextCheckAt;
  final String? lastAttemptAt;
  final String lastResult;
  final String? error;
  final bool available;
  final bool stale;

  /// Never infer activation from a successful save or from matching values alone.
  bool get confirmed =>
      available &&
      !stale &&
      (error == null || error!.isEmpty) &&
      appliedIntervalDays == requestedIntervalDays;

  factory SystemUpdaterStatus.fromJson(Map<String, dynamic> json) {
    final requested = json['requestedIntervalDays'];
    final applied = json['appliedIntervalDays'];
    final result = json['lastResult'];
    if (requested is! int ||
        (applied != null && applied is! int) ||
        json['available'] is! bool ||
        json['stale'] is! bool ||
        result is! String) {
      throw const FormatException('Invalid updater status response');
    }
    return SystemUpdaterStatus(
      requestedIntervalDays: requested,
      requestedUpdatedAt: json['requestedUpdatedAt'] as String?,
      appliedIntervalDays: applied as int?,
      configUpdatedAt: json['configUpdatedAt'] as String?,
      checkedAt: json['checkedAt'] as String?,
      nextCheckAt: json['nextCheckAt'] as String?,
      lastAttemptAt: json['lastAttemptAt'] as String?,
      lastResult: result,
      error: json['error'] as String?,
      available: json['available'] as bool,
      stale: json['stale'] as bool,
    );
  }
}
