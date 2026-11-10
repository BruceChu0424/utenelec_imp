// 访客会话 Provider（visitor 主体，独立于员工 sessionProvider）。
// 状态：guest 未登录 / active 已登录。令牌存 SecureStorage(visitor.*)；启动凭 token
// 恢复——先调 /visitor/me 服务端校验（令牌过期时拦截器自动刷新，刷新被拒则触发
// 会话失效），网络不可用等临时失败降级为本地解码 JWT，不打断离线访客。

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/visitor_session_event_bus.dart';
import '../../../core/security/secure_storage.dart';
import '../models/visitor.dart';
import '../repositories/visitor_repository.dart';

enum VisitorAuthStatus { guest, active }

class VisitorSessionState {
  const VisitorSessionState({
    this.status = VisitorAuthStatus.guest,
    this.visitor,
  });

  final VisitorAuthStatus status;
  final Visitor? visitor;

  bool get isLoggedIn => status == VisitorAuthStatus.active;
}

class VisitorSessionNotifier extends Notifier<VisitorSessionState> {
  int _lifecycle = 0;
  int _intent = 0;
  String? _ownerLineage;
  int? _ownerIntent;

  @override
  VisitorSessionState build() {
    final lifecycle = ++_lifecycle;
    Future.microtask(() => _restore(lifecycle));
    final expiration = VisitorSessionEventBus.instance.onSessionExpired.listen((
      notice,
    ) {
      if (_current(lifecycle) &&
          notice.sessionLineage == _ownerLineage &&
          notice.intentGeneration == _ownerIntent) {
        _ownerLineage = null;
        _ownerIntent = null;
        state = const VisitorSessionState();
      }
    });
    ref.onDispose(() {
      _lifecycle++;
      unawaited(expiration.cancel());
    });
    return const VisitorSessionState();
  }

  bool _current(int lifecycle) => lifecycle == _lifecycle;

  VisitorRepository get _repo => ref.read(visitorRepositoryProvider);
  SecureStorage get _storage => ref.read(secureStorageProvider);

  Future<void> _restore(int lifecycle) async {
    if (!_current(lifecycle)) return;
    final intent = _intent;
    bool current() => _current(lifecycle) && intent == _intent;
    final storage = _storage;
    final VisitorTokenSnapshot owner;
    try {
      owner = await storage.getVisitorTokenSnapshot();
    } catch (_) {
      return;
    }
    if (!current() || !owner.hasAccessToken) return;
    final repo = _repo;
    try {
      // 服务端校验：令牌过期先走拦截器刷新，刷新被拒会清存储并广播过期；
      // 成功则用服务器资料激活会话（姓名等可能已在别处更新）。
      final me = await repo.me();
      if (!current()) return;
      final latest = await storage.getVisitorTokenSnapshot();
      if (!current() ||
          !owner.isSameSession(latest) ||
          !latest.hasAccessToken) {
        return;
      }
      _ownerLineage = latest.sessionLineage;
      _ownerIntent = latest.intentGeneration;
      state = VisitorSessionState(
        status: VisitorAuthStatus.active,
        visitor: me,
      );
      return;
    } on ApiException catch (e) {
      if (!current()) return;
      // 401/403/404：令牌或账号已失效（拦截器已处理过期广播），结束恢复。
      final definitive =
          e.hasResponseCode &&
          const {'UNAUTHORIZED', 'FORBIDDEN'}.contains(e.code) &&
          (e.httpStatus == 401 || e.httpStatus == 403);
      if (definitive) {
        try {
          if (current()) await storage.clearVisitorTokensIfUnchanged(owner);
        } catch (_) {
          /* Storage failure cannot retire another owner. */
        }
        return;
      }
      if (e.code == 'SESSION_CHANGED') return;
      // 其它业务错误按临时失败处理，降级本地解码。
    } catch (_) {
      // 网络不可用等：降级本地解码，离线访客不被误登出。
    }
    if (!current()) return;
    final VisitorTokenSnapshot latest;
    try {
      latest = await storage.getVisitorTokenSnapshot();
    } catch (_) {
      return;
    }
    if (!current() || !owner.isSameSession(latest) || !latest.hasAccessToken) {
      return;
    }
    final v = _decodeVisitor(latest.accessToken!);
    if (v != null) {
      _ownerLineage = latest.sessionLineage;
      _ownerIntent = latest.intentGeneration;
      state = VisitorSessionState(status: VisitorAuthStatus.active, visitor: v);
    } else {
      // 本地令牌已损坏：清掉避免每次冷启动都走无效恢复。
      await storage.clearVisitorTokensIfUnchanged(latest);
    }
  }

  Future<String?> sendCode(String phone) => _repo.sendCode(phone);

  Future<void> login(String phone, String code) async {
    final lifecycle = _lifecycle;
    final intent = ++_intent;
    final storage = _storage;
    // An explicit new login retires the old credential owner immediately.
    // A failed new login must not leave the old visitor displayed as active.
    _ownerLineage = null;
    _ownerIntent = null;
    state = const VisitorSessionState();
    final res = await _repo.login(phone, code);
    if (!_current(lifecycle) || intent != _intent) return;
    final owner = await storage.getVisitorTokenSnapshot();
    if (!_current(lifecycle) ||
        intent != _intent ||
        owner.accessToken != res.accessToken) {
      return;
    }
    _ownerLineage = owner.sessionLineage;
    _ownerIntent = owner.intentGeneration;
    state = VisitorSessionState(
      status: VisitorAuthStatus.active,
      visitor: Visitor(
        id: res.visitorId,
        visitorNo: res.visitorNo,
        name: res.name,
        avatarSeed: res.avatarSeed,
      ),
    );
  }

  Future<void> logout() async {
    final lifecycle = _lifecycle;
    final intent = ++_intent;
    final storage = _storage;
    final owner = await storage.getVisitorTokenSnapshot();
    if (!_current(lifecycle) || intent != _intent) return;
    await _repo.logout(owner: owner);
    if (!_current(lifecycle) || intent != _intent) return;
    final latest = await storage.getVisitorTokenSnapshot();
    if (!_current(lifecycle) ||
        intent != _intent ||
        latest.hasAccessToken && !owner.isSameSession(latest)) {
      return;
    }
    _ownerLineage = null;
    _ownerIntent = null;
    state = const VisitorSessionState();
  }

  Visitor? _decodeVisitor(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      var norm = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      final pad = norm.length % 4;
      if (pad != 0) norm += '=' * (4 - pad);
      final payload = utf8.decode(base64.decode(norm));
      final j = jsonDecode(payload) as Map<String, dynamic>;
      final id = (j['sub'] ?? '').toString();
      final vno = (j['vno'] ?? '').toString();
      final avatarSeed = (j['avs'] ?? '').toString();
      // Backward-compatible fallback for access tokens issued before raw phone PII
      // was removed from the `acc` claim. New tokens carry only visitorNo + avs.
      final legacyAccount = (j['acc'] ?? '').toString();
      final legacySeed = legacyAccount.length >= 4
          ? legacyAccount.substring(legacyAccount.length - 4)
          : vno;
      return Visitor(
        id: id,
        visitorNo: vno,
        name: vno,
        avatarSeed: avatarSeed.isNotEmpty ? avatarSeed : legacySeed,
      );
    } catch (_) {
      return null;
    }
  }
}

final visitorSessionProvider =
    NotifierProvider<VisitorSessionNotifier, VisitorSessionState>(
      VisitorSessionNotifier.new,
    );
