// 访客会话 Provider（visitor 主体，独立于员工 sessionProvider）。
// 状态：guest 未登录 / active 已登录。令牌存 SecureStorage(visitor.*)；启动凭 token 恢复（解码 JWT 拿 visitorNo）。

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/visitor_session_event_bus.dart';
import '../../../core/security/secure_storage.dart';
import '../models/visitor.dart';
import '../repositories/visitor_repository.dart';

enum VisitorAuthStatus { guest, active }

class VisitorSessionState {
  const VisitorSessionState({this.status = VisitorAuthStatus.guest, this.visitor});

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
    final v = _decodeVisitor(token);
    if (v != null) {
      state = VisitorSessionState(status: VisitorAuthStatus.active, visitor: v);
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
      final phone = (j['acc'] ?? '').toString();
      final tail = phone.length >= 4 ? phone.substring(phone.length - 4) : '0000';
      return Visitor(id: id, visitorNo: vno, name: vno, avatarSeed: tail);
    } catch (_) {
      return null;
    }
  }
}

final visitorSessionProvider =
    NotifierProvider<VisitorSessionNotifier, VisitorSessionState>(VisitorSessionNotifier.new);
