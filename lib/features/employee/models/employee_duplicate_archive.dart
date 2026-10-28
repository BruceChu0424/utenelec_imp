class EmployeeDuplicateArchivePreview {
  const EmployeeDuplicateArchivePreview({
    required this.sourceId,
    required this.sourceCode,
    required this.sourceName,
    required this.sourceVersion,
    required this.retainedId,
    required this.retainedCode,
    required this.retainedName,
    required this.retainedVersion,
    this.blockers = const [],
    this.documentConflict = false,
  });
  final String sourceId,
      sourceCode,
      sourceName,
      retainedId,
      retainedCode,
      retainedName;
  final int sourceVersion, retainedVersion;
  final List<String> blockers;
  final bool documentConflict;
  factory EmployeeDuplicateArchivePreview.fromJson(Map<String, dynamic> json) =>
      EmployeeDuplicateArchivePreview(
        sourceId: json['sourceId'] as String,
        sourceCode: json['sourceCode'] as String,
        sourceName: json['sourceName'] as String,
        sourceVersion: json['sourceVersion'] as int,
        retainedId: json['retainedId'] as String,
        retainedCode: json['retainedCode'] as String,
        retainedName: json['retainedName'] as String,
        retainedVersion: json['retainedVersion'] as int,
        blockers: (json['blockers'] as List).cast<String>(),
        documentConflict: json['documentConflict'] == true,
      );
}
