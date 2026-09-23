// 登录会话重建门测试：未登录→已登录时推进 sessionEpoch，全站徽章汇总从零重建并
// 「恰好拉一次」(不是在旧实例上再 refresh 一次)，归到新会话的值。
// 背景：清空业务数据后重登「要再刷新一次才彻底清空」（ADR-067 §7 / 审计 C14 H1-2）。
// ADR-108 起全部徽章与通知未读数由一个汇总请求带回: 未登录时 0 请求(此前未读数轮询
// 不看登录状态, 登出后照样按 60s 打出 401)。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/shared/auth/session_epoch_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/session_rehydrate_gate.dart';

class _SummaryApi extends ApiClient {
  _SummaryApi() : super(Dio());

  int calls = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path != ApiEndpoints.workbenchBadges) {
      throw StateError('unexpected GET $path');
    }
    calls++;
    return {
      'entries': {
        'hrTaskCenter': {'todo': 3, 'inProgress': 0},
        'purchaseTaskCenter': {'todo': 5, 'inProgress': 1},
      },
      'modules': {
        'people': {'todo': 3, 'inProgress': 0},
        'purchase': {'todo': 5, 'inProgress': 1},
      },
      'total': {'todo': 8, 'inProgress': 1},
      'facts': {'notices.unread': 10},
      'staleEntries': <String>[],
    };
  }
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();

  void signIn() {
    state = const SessionState(
      status: AuthStatus.authenticated,
      user: AppUser(id: 'u-1', code: 'ADMIN', name: '超管', superAdmin: true),
    );
  }
}

/// 像工作台一样 watch 徽章，让汇总存活并把值渲染出来供断言。
class _BadgeWatcher extends ConsumerWidget {
  const _BadgeWatcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final epoch = ref.watch(sessionEpochProvider);
    final hr = ref.watch(badgeEntryTodoProvider(BadgeEntry.hrTaskCenter));
    final purchase = ref.watch(badgeModuleTodoProvider(BadgeModule.purchase));
    final total = ref.watch(badgeTotalTodoProvider);
    final unread = ref.watch(unreadNoticeCountProvider);
    return Text(
      key: const Key('badges'),
      'epoch=$epoch hr=$hr purchase=$purchase total=$total unread=$unread',
    );
  }
}

String _badges(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('badges'))).data!;

Future<(_SummaryApi, _TestSessionNotifier)> _pump(WidgetTester tester) async {
  final api = _SummaryApi();
  final session = _TestSessionNotifier();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(() => session),
        apiClientProvider.overrideWithValue(api),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Column(children: [SessionRehydrateGate(), _BadgeWatcher()]),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (api, session);
}

void main() {
  testWidgets('未登录 0 请求; 登录后推进 sessionEpoch, 汇总恰好拉一次并归到新会话值', (tester) async {
    final (api, session) = await _pump(tester);

    expect(_badges(tester), 'epoch=0 hr=0 purchase=0 total=0 unread=0');
    await tester.pump(const Duration(minutes: 5));
    expect(api.calls, 0, reason: '未登录不应发任何计数请求');

    session.signIn();
    await tester.pumpAndSettle();

    expect(_badges(tester), 'epoch=1 hr=3 purchase=5 total=8 unread=10');
    expect(api.calls, 1, reason: '登录后应恰好拉一次汇总');

    // 释放 ProviderScope：汇总的 60s 轮询定时器随 onDispose 取消。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('已登录状态内的会话变化(同一用户)不推进 sessionEpoch、不重拉', (tester) async {
    final (api, session) = await _pump(tester);
    session.signIn();
    await tester.pumpAndSettle();
    expect(api.calls, 1);

    // 同一用户再次 login（如 token 刷新后的会话快照更新）：不是未登录→已登录跃迁。
    session.signIn();
    await tester.pumpAndSettle();
    expect(_badges(tester), startsWith('epoch=1 '));
    expect(api.calls, 1, reason: '同会话内不应重建/重拉');

    await tester.pumpWidget(const SizedBox());
  });
}
