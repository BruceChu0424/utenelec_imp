/// Category locations for one authorized master-data search. Business rows
/// stay on their independent bounded result page.
class MasterSearchContext {
  const MasterSearchContext({
    required this.categoryIds,
    required this.totalMatches,
    required this.page,
    required this.totalPages,
    required this.totalCategories,
    this.readScopeVersion,
  });

  final List<String?> categoryIds;
  final int totalMatches;
  final int page;
  final int totalPages;
  final int totalCategories;
  final String? readScopeVersion;

  factory MasterSearchContext.fromJson(Map<String, dynamic> json) =>
      MasterSearchContext(
        categoryIds: [
          for (final entry in json['categories'] as List? ?? const [])
            (entry as Map)['categoryId'] as String?,
        ],
        totalMatches: (json['totalMatches'] as num?)?.toInt() ?? 0,
        page: (json['page'] as num?)?.toInt() ?? 1,
        totalPages: (json['totalPages'] as num?)?.toInt() ?? 0,
        totalCategories: (json['totalCategories'] as num?)?.toInt() ?? 0,
        readScopeVersion: json['readScopeVersion'] as String?,
      );
}
