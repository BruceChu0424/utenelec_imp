// 后端统一错误响应体（对应后端 ApiError）。
class ApiError {
  const ApiError({required this.code, required this.message, this.fieldErrors});

  final String code;
  final String message;
  final List<ApiFieldError>? fieldErrors;

  factory ApiError.fromJson(Map<String, dynamic> json) => ApiError(
    code: json['code'] as String? ?? 'UNKNOWN',
    message: json['message'] as String? ?? '请求失败',
    fieldErrors: (json['fieldErrors'] as List<dynamic>?)
        ?.map((e) => ApiFieldError.fromJson(e as Map<String, dynamic>))
        .toList(),
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
