import 'dart:convert';

/// Atomic visitor credentials, isolated from the staff token/session record.
/// A refresh preserves lineage; login and logout create a new owner boundary.
class VisitorTokenSnapshot {
  const VisitorTokenSnapshot({
    required this.accessToken,
    required this.refreshToken,
    required this.generation,
    required this.sessionLineage,
    this.intentGeneration = 0,
  });
  const VisitorTokenSnapshot.empty()
    : accessToken = null,
      refreshToken = null,
      generation = 0,
      intentGeneration = 0,
      sessionLineage = null;
  final String? accessToken, refreshToken, sessionLineage;
  final int generation;
  final int intentGeneration;
  bool get hasAccessToken => accessToken?.isNotEmpty == true;
  bool get hasRefreshToken => refreshToken?.isNotEmpty == true;
  bool isSameSession(VisitorTokenSnapshot other) =>
      sessionLineage == other.sessionLineage &&
      intentGeneration == other.intentGeneration;
  bool isSameRecord(VisitorTokenSnapshot other) =>
      isSameSession(other) &&
      generation == other.generation &&
      accessToken == other.accessToken &&
      refreshToken == other.refreshToken;
  Map<String, Object?> toJson() => {
    'version': 1,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'generation': generation,
    'intentGeneration': intentGeneration,
    'sessionLineage': sessionLineage,
  };
  static VisitorTokenSnapshot? tryParse(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['version'] != 1 ||
          value['generation'] is! int ||
          (value['generation'] as int) < 1 ||
          value['sessionLineage'] is! String ||
          (value['sessionLineage'] as String).isEmpty) {
        return null;
      }
      for (final key in ['accessToken', 'refreshToken']) {
        if (value[key] != null &&
            (value[key] is! String || (value[key] as String).isEmpty)) {
          return null;
        }
      }
      final intent = value['intentGeneration'] ?? 0;
      if (intent is! int || intent < 0) return null;
      return VisitorTokenSnapshot(
        accessToken: value['accessToken'] as String?,
        refreshToken: value['refreshToken'] as String?,
        generation: value['generation'] as int,
        sessionLineage: value['sessionLineage'] as String,
        intentGeneration: intent,
      );
    } catch (_) {
      return null;
    }
  }
}
