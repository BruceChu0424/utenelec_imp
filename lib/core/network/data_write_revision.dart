// 本端写操作修订号 —— 「返回即刷新」判断「数据变没变」的全局兜底(ADR-108)。
//
// 每个成功的写请求(非 GET/HEAD/OPTIONS、非自动类写如心跳/自动已读/偏好保存)都让修订号 +1。
// 页面「返回」时只在修订号前进过(期间本端改过数据)或数据超过 30 秒才重拉;
// 纯查看后返回不再整页重拉。写操作漏了 bumpListRefresh 也不会显示旧数据——修订号不看
// 调用方记没记得通知, 只看网络层有没有成功写过。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 单调递增的本端写修订号。
final dataWriteRevisionProvider = StateProvider<int>((ref) => 0);

/// 最近一次成功的本端写请求(序号 + 路径)。主档字典仓库据路径作废对应字典,
/// 网络层不必认识任何业务模块。
final lastDataWriteProvider = StateProvider<({int seq, String path})?>(
  (ref) => null,
);

/// 不代表业务数据变化的自动写请求(心跳、自动已读、偏好保存、令牌刷新、只算不存的预览)。
final List<RegExp> _automaticWritePaths = [
  RegExp(r'/task-claims/[^/]+/[^/]+/heartbeat$'),
  RegExp(r'/notices/read-by-(route|source)$'),
  RegExp(r'/notices/[^/]+/(read|popup-ack|snooze)$'),
  RegExp(r'/user/preferences/'),
  RegExp(r'/auth/'),
  RegExp(r'/preview$'),
  RegExp(r'/resolve-batch$'),
];

/// 该请求成功后是否算一次本端写操作。
bool isBusinessWrite(RequestOptions options) {
  final method = options.method.toUpperCase();
  if (method == 'GET' || method == 'HEAD' || method == 'OPTIONS') return false;
  final path = options.uri.path;
  return !_automaticWritePaths.any((pattern) => pattern.hasMatch(path));
}

/// 写请求成功后推进修订号。挂在全局 Dio 上, 业务调用方无需感知。
class DataWriteRevisionInterceptor extends Interceptor {
  DataWriteRevisionInterceptor(this._onWrite);

  final void Function(RequestOptions options) _onWrite;

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final status = response.statusCode ?? 0;
    if (status >= 200 &&
        status < 300 &&
        isBusinessWrite(response.requestOptions)) {
      _onWrite(response.requestOptions);
    }
    handler.next(response);
  }
}

/// [DataWriteRevisionInterceptor] 的标准回调: 推进修订号并记下这次写的路径。
void recordDataWrite(Ref ref, RequestOptions options) {
  final revision = ++ref.read(dataWriteRevisionProvider.notifier).state;
  ref.read(lastDataWriteProvider.notifier).state = (
    seq: revision,
    path: options.uri.path,
  );
}
