// 弹窗里显示的失败原因：优先服务端原话，让人知道具体哪里不对。
import '../../../core/network/api_error.dart';
import '../../../core/network/api_exception.dart';

/// 把一次失败转成弹窗内的红字。
///
/// 服务端报错(ApiException)显示服务端原话，并补上字段级原因里正文没有提到的句子
/// (只取原因，不带字段名)；只有服务端没给任何说明、或根本不是服务端报错时，
/// 才用 [fallback] 这种笼统说法。
String employeeDialogErrorText(Object error, String fallback) {
  if (error is! ApiException) return fallback;
  final parts = <String>[];
  final message = error.message.trim();
  if (message.isNotEmpty) parts.add(message);
  for (final field in error.fieldErrors ?? const <ApiFieldError>[]) {
    final text = field.message.trim();
    if (text.isEmpty || parts.any((part) => part.contains(text))) continue;
    parts.add(text);
  }
  return parts.isEmpty ? fallback : parts.join('\n');
}
