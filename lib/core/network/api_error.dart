// 后端统一错误响应体（对应后端 ApiError）。
class ApiError {
  const ApiError({
    required this.code,
    required this.message,
    this.fieldErrors,
    this.hasCode = true,
  });

  final String code;
  final String message;
  final List<ApiFieldError>? fieldErrors;

  /// 响应体里是否真的带了错误码。为假表示 [code] 是本端补的 'UNKNOWN'
  /// (例如框架默认错误页的 JSON，不是后端统一错误格式)。
  final bool hasCode;

  factory ApiError.fromJson(Map<String, dynamic> json) => ApiError(
    code: json['code'] as String? ?? 'UNKNOWN',
    message: json['message'] as String? ?? '操作失败',
    fieldErrors: (json['fieldErrors'] as List<dynamic>?)
        ?.map((e) => ApiFieldError.fromJson(e as Map<String, dynamic>))
        .toList(),
    hasCode: json['code'] is String,
  );
}

class ApiFieldError {
  const ApiFieldError({required this.field, required this.message});

  final String field;
  final String message;

  factory ApiFieldError.fromJson(Map<String, dynamic> json) => ApiFieldError(
    field: json['field'] as String? ?? '',
    message: json['message'] as String? ?? '',
  );
}
