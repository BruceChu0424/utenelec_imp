// 非服务端异常里「写给人看」的那句话(ADR-151 §2: 提交失败如实报因)。
//
// 页面的 catch-all 分支拿到的可能是: 草稿保护 / 本机存储 / 页面自己抛的中文 StateError、
// FormatException(自带「下一步怎么办」, 必须原样给人看); 也可能是 Dart 或框架内部的英文异常
// ('No element'、'Invalid date format'), 那是程序问题, 不给人看代号, 由调用方用兜底文案并记日志。
// 判定只有一条: 消息里有中文才放行。服务端拒绝(ApiException)直接用服务端文案。
import 'dart:async';

import '../network/api_exception.dart';

final _han = RegExp(r'[\u4e00-\u9fff]');
const _maxLength = 300;

/// 这个异常能直接给人看的原因; 不能给人看(英文内部异常、空消息)返回 null。
String? humanErrorMessage(Object error) {
  if (error is ApiException) {
    final message = error.message.trim();
    return message.isEmpty ? null : message;
  }
  final String? raw = switch (error) {
    StateError(:final message) => message,
    FormatException(:final message) => message,
    TimeoutException(:final message) => message,
    ArgumentError(:final message) => message?.toString(),
    _ => error.toString(),
  };
  if (raw == null) return null;
  var text = raw.trim();
  for (final prefix in const [
    'Exception: ',
    'Bad state: ',
    'FormatException: ',
  ]) {
    if (text.startsWith(prefix)) text = text.substring(prefix.length).trim();
  }
  if (text.isEmpty || !_han.hasMatch(text)) return null;
  return text.length > _maxLength ? text.substring(0, _maxLength) : text;
}
