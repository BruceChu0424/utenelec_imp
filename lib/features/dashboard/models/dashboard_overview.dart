class DashboardOverview {
  const DashboardOverview({
    required this.departmentCode,
    required this.departmentName,
    required this.generatedAt,
    required this.metrics,
    required this.todos,
  });

  factory DashboardOverview.fromJson(Map<String, dynamic> json) {
    return DashboardOverview(
      departmentCode: json['departmentCode'] as String? ?? '',
      departmentName: json['departmentName'] as String? ?? '',
      generatedAt:
          DateTime.tryParse(json['generatedAt'] as String? ?? '') ??
          DateTime.now(),
      metrics: [
        for (final item in json['metrics'] as List<dynamic>? ?? const [])
          DashboardMetric.fromJson(item as Map<String, dynamic>),
      ],
      todos: [
        for (final item in json['todos'] as List<dynamic>? ?? const [])
          DashboardTodo.fromJson(item as Map<String, dynamic>),
      ],
    );
  }

  final String departmentCode;
  final String departmentName;
  final DateTime generatedAt;
  final List<DashboardMetric> metrics;
  final List<DashboardTodo> todos;
}

class DashboardMetric {
  const DashboardMetric({
    required this.id,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.tone,
    required this.route,
    required this.sensitive,
  });

  factory DashboardMetric.fromJson(Map<String, dynamic> json) {
    return DashboardMetric(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      value: json['value'] as String? ?? '',
      subtitle: json['subtitle'] as String? ?? '',
      tone: json['tone'] as String? ?? 'neutral',
      route: json['route'] as String?,
      sensitive: json['sensitive'] as bool? ?? false,
    );
  }

  final String id;
  final String title;
  final String value;
  final String subtitle;
  final String tone;
  final String? route;
  final bool sensitive;
}

class DashboardTodo {
  const DashboardTodo({
    required this.id,
    required this.title,
    required this.summary,
    required this.count,
    required this.urgentCount,
    required this.tone,
    required this.route,
    required this.sourceType,
    required this.sourceId,
    required this.dueAt,
    required this.completable,
  });

  factory DashboardTodo.fromJson(Map<String, dynamic> json) {
    return DashboardTodo(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
      urgentCount: (json['urgentCount'] as num?)?.toInt() ?? 0,
      tone: json['tone'] as String? ?? 'neutral',
      route: json['route'] as String?,
      sourceType: json['sourceType'] as String? ?? '',
      sourceId: json['sourceId'] as String?,
      dueAt: DateTime.tryParse(json['dueAt'] as String? ?? ''),
      completable: json['completable'] as bool? ?? false,
    );
  }

  final String id;
  final String title;
  final String summary;
  final int count;
  final int urgentCount;
  final String tone;
  final String? route;
  final String sourceType;
  final String? sourceId;
  final DateTime? dueAt;
  final bool completable;
}
