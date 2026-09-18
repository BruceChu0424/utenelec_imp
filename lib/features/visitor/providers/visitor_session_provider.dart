// 访客会话 Provider（visitor 主体，独立于员工 sessionProvider）。
// 状态：guest 未登录 / active 已登录。令牌存 SecureStorage(visitor.*)；启动凭 token
// 恢复——先调 /visitor/me 服务端校验（令牌过期时拦截器自动刷新，刷新被拒则触发
// 会话失效），网络不可用等临时失败降级为本地解码 JWT，不打断离线访客。

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
  @override
  VisitorSessionState build() {
    Future.microtask(_restore);
    VisitorSessionEventBus.instance.onSessionExpired.listen((_) {
      state = const VisitorSessionState();
    });
    return const VisitorSessionState();
  }

  VisitorRepository get _repo => ref.read(visitorRepositoryProvider);
  SecureStorage get _storage => ref.read(secureStorageProvider);

  Future<void> _restore() async {
    final token = await _storage.getVisitorAccessToken();
    if (token == null || token.isEmpty) return;
    try {
      // 服务端校验：令牌过期先走拦截器刷新，刷新被拒会清存储并广播过期；
      // 成功则用服务器资料激活会话（姓名等可能已在别处更新）。
      final me = await _repo.me();
      state = VisitorSessionState(
        status: VisitorAuthStatus.active,
        visitor: me,
      );
      return;
    } on ApiException catch (e) {
      // 401/403/404：令牌或账号已失效（拦截器已处理过期广播），结束恢复。
      final definitive =
          e.httpStatus == 401 ||
          e.httpStatus == 403 ||
          e.code == 'UNAUTHORIZED' ||
          e.code == 'FORBIDDEN';
      if (definitive) {
        await _storage.clearVisitorTokens();
        return;
      }
      // 其它业务错误按临时失败处理，降级本地解码。
    } catch (_) {
      // 网络不可用等：降级本地解码，离线访客不被误登出。
    }
    final v = _decodeVisitor(token);
    if (v != null) {
      state = VisitorSessionState(status: VisitorAuthStatus.active, visitor: v);
    } else {
      // 本地令牌已损坏：清掉避免每次冷启动都走无效恢复。
      await _storage.clearVisitorTokens();
    }
  }

  Future<String?> sendCode(String phone) => _repo.sendCode(phone);

  Future<void> login(String phone, String code) async {
    final res = await _repo.login(phone, code);
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
    await _repo.logout();
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
