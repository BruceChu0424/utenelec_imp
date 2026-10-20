class MaterialAnalysisBomFinding {
  const MaterialAnalysisBomFinding({
    required this.key,
    required this.rootLabel,
    required this.parentLabel,
    required this.componentLabel,
    required this.reason,
    required this.fix,
    this.taskNo,
  });

  final String key;
  final String rootLabel;
  final String parentLabel;
  final String componentLabel;
  final String reason;
  final String fix;
  final String? taskNo;

  factory MaterialAnalysisBomFinding.fromJson(Map<String, dynamic> json) =>
      MaterialAnalysisBomFinding(
        key: json['key'] as String,
        rootLabel: json['rootLabel'] as String,
        parentLabel: json['parentLabel'] as String,
        componentLabel: json['componentLabel'] as String,
        reason: json['reason'] as String,
        fix: json['fix'] as String,
        taskNo: json['taskNo'] as String?,
      );
}

class MaterialAnalysisBomDiagnostic {
  const MaterialAnalysisBomDiagnostic({
    required this.findings,
    required this.blockedSourceIndexes,
  });
  final List<MaterialAnalysisBomFinding> findings;
  final Set<int> blockedSourceIndexes;

  factory MaterialAnalysisBomDiagnostic.fromJson(Map<String, dynamic> json) =>
      MaterialAnalysisBomDiagnostic(
        findings: [
          for (final row in json['findings'] as List? ?? const [])
            MaterialAnalysisBomFinding.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
        ],
        blockedSourceIndexes: {
          for (final index in json['blockedSourceIndexes'] as List? ?? const [])
            (index as num).toInt(),
        },
      );
}
