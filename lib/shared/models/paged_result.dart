// 分页结果（对应后端 PageResponse：{items,page,size,total,totalPages}）。
class PagedResult<T> {
  const PagedResult({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<T> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory PagedResult.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final list = json['items'] as List<dynamic>? ?? const [];
    return PagedResult<T>(
      items: list.map((e) => fromJson(e as Map<String, dynamic>)).toList(),
      page: json['page'] as int? ?? 1,
      size: json['size'] as int? ?? list.length,
      total: (json['total'] as num?)?.toInt() ?? list.length,
      totalPages: json['totalPages'] as int? ?? 1,
    );
  }
}
