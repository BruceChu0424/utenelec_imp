// 会话内的敏感操作再认证：连续操作复用凭证，空闲五分钟后重新验证。
// 仅保存随机凭证于内存；密码、凭证均不写持久存储。服务端负责最终过期判断。
import 'user_activity.dart';

typedef StepUpPrompter = Future<String?> Function();

class StepUpCoordinator {
  StepUpCoordinator({DateTime Function()? clock})
    : _clock = clock ?? (() => UserActivity.clock());

  static final StepUpCoordinator instance = StepUpCoordinator();
  static const idleTimeout = Duration(minutes: 5);
  static const activityInterval = Duration(seconds: 30);

  final DateTime Function() _clock;
  StepUpPrompter? _prompter;
  Future<String?>? _pending;
  String? _token;
  Object? _identity;
  DateTime? _expiresAt;
  DateTime? _lastActivityAt;
  DateTime? _syncedActivityAt;
  DateTime? _lastActivityRequestAt;
  bool _activityRequestInFlight = false;
  int _generation = 0;

  /// 网络请求的服务器与登录身份变化时，旧凭证和迟到弹框结果立即失效。
  void bindIdentity(Object identity) {
    if (_identity == identity) return;
    clear();
    _identity = identity;
  }

  void clear() {
    _generation++;
    _token = null;
    _expiresAt = null;
    _lastActivityAt = null;
    _syncedActivityAt = null;
    _lastActivityRequestAt = null;
    _pending = null;
  }

  void invalidate(String? token) {
    if (token != null && token == _token) clear();
  }

  /// 每次真实输入同步检测间隔，避免离开五分钟后首次输入复活旧凭证。
  void recordActivity() {
    final now = _clock();
    final previous = _lastActivityAt;
    if (_token != null &&
        previous != null &&
        now.difference(previous) >= idleTimeout) {
      clear();
    }
    _lastActivityAt = now;
  }

  String? get cachedToken {
    if (_token == null) return null;
    final now = _clock();
    if (_expiresAt == null ||
        !now.isBefore(_expiresAt!) ||
        _lastActivityAt == null ||
        now.difference(_lastActivityAt!) >= idleTimeout) {
      clear();
    }
    return _token;
  }

  /// 普通成功请求不续期，只有服务端明确确认续期后才更新有效期。
  void confirm(String token, {DateTime? requestStartedAt}) {
    if (_token != token) return;
    _expiresAt = (requestStartedAt ?? _clock()).add(idleTimeout);
  }

  void Function() register(StepUpPrompter prompter) {
    clear();
    _prompter = prompter;
    return () {
      if (identical(_prompter, prompter)) {
        _prompter = null;
        clear();
      }
    };
  }

  /// 同一身份的并发写操作共用一次验证；取消不会留下授权。
  Future<String?> obtain() {
    final cached = cachedToken;
    if (cached != null) return Future.value(cached);
    final pending = _pending;
    if (pending != null) return pending;
    final prompter = _prompter;
    if (prompter == null) return Future.value();
    final generation = _generation;
    late final Future<String?> next;
    next = Future<String?>.sync(prompter)
        .then((value) {
          if (generation != _generation ||
              !identical(_prompter, prompter) ||
              value == null ||
              value.isEmpty) {
            return null;
          }
          _token = value;
          _lastActivityAt = _clock();
          _syncedActivityAt = _lastActivityAt;
          _expiresAt = _lastActivityAt!.add(idleTimeout);
          return value;
        })
        .whenComplete(() {
          if (identical(_pending, next)) _pending = null;
        });
    _pending = next;
    return next;
  }

  /// 只在新增输入后发送有界活动请求；定时器、后台轮询本身不续期。
  Future<void> keepAliveIfActive(
    Future<void> Function(String token) renew,
  ) async {
    final token = cachedToken;
    final activity = _lastActivityAt;
    final now = _clock();
    if (token == null ||
        activity == null ||
        _activityRequestInFlight ||
        now.difference(activity) >= UserActivity.idleAfter ||
        (_syncedActivityAt != null && !activity.isAfter(_syncedActivityAt!)) ||
        (_lastActivityRequestAt != null &&
            now.difference(_lastActivityRequestAt!) < activityInterval)) {
      return;
    }
    _activityRequestInFlight = true;
    _lastActivityRequestAt = now;
    final generation = _generation;
    try {
      await renew(token);
      if (generation == _generation && _token == token) {
        confirm(token, requestStartedAt: now);
        _syncedActivityAt = activity;
      }
    } catch (_) {
      // 网络故障不假装续期，仍以此前服务端确认的截止时间为准。
    } finally {
      _activityRequestInFlight = false;
    }
  }
}
