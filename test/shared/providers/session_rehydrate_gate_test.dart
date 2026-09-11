// 登录会话重建门测试：未登录→已登录时推进 sessionEpoch，接入的全局角标 Notifier
// 各自从零重建并「恰好重拉一次」（不是在旧实例上再 refresh 一次），归到新会话的值。
// 背景：清空业务数据后重登「要再刷新一次才彻底清空」（ADR-067 §7 / 审计 C14 H1-2）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:uten_imp/features/hr_task/providers/hr_task_count_provider.dart';
import 'package:uten_imp/features/hr_task/repositories/hr_task_repository.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/production/providers/production_pending_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/profile/repositories/profile_change_repository.dart';
import 'package:uten_imp/features/purchase/providers/purchase_task_count_provider.dart';
import 'package:uten_imp/features/rd_task/providers/rd_task_count_provider.dart';
import 'package:uten_imp/features/rd_task/repositories/rd_task_repository.dart';
import 'package:uten_imp/features/subcontract/providers/subcontract_task_count_provider.dart';
import 'package:uten_imp/features/visitor/repositories/visitor_staff_repository.dart';
import 'package:uten_imp/features/visitor_approval/providers/visitor_pending_count_provider.dart';
import 'package:uten_imp/shared/auth/pending_review_provider.dart';
import 'package:uten_imp/shared/auth/session_epoch_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/session_rehydrate_gate.dart';

/// 各计数接口的调用次数（按名字）。
class _Calls {
  final Map<String, int> _byName = {};
  int of(String name) => _byName[name] ?? 0;
  void hit(String name) => _byName[name] = of(name) + 1;
}

// 只实现角标用到的计数方法；其它成员走 noSuchMethod 直接抛错，误调用即失败。
class _FakeHrTaskRepository implements HrTaskRepository {
  _FakeHrTaskRepository(this.calls);
  final _Calls calls;
  @override
  Future<int> count() async {
    calls.hit('hr');
    return 3;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeRdTaskRepository implements RdTaskRepository {
  _FakeRdTaskRepository(this.calls);
  final _Calls calls;
  @override
  Future<int> count() async {
    calls.hit('rd');
    return 4;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeOperationsWorkbenchRepository
    implements OperationsWorkbenchRepository {
  _FakeOperationsWorkbenchRepository(this.calls);
  final _Calls calls;
  @override
  Future<int> purchaseTaskCount() async {
    calls.hit('purchase');
    return 5;
  }

  @override
  Future<int> subcontractTaskCount() async {
    calls.hit('subcontract');
    return 6;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeVisitorStaffRepository implements VisitorStaffRepository {
  _FakeVisitorStaffRepository(this.calls);
  final _Calls calls;
  @override
  Future<int> pendingCount() async {
    calls.hit('visitor');
    return 7;
  }

  @override
  Future<int> hostPendingCount() async {
    calls.hit('host');
    return 8;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeProfileChangeRepository implements ProfileChangeRepository {
  _FakeProfileChangeRepository(this.calls);
  final _Calls calls;
  @override
  Future<int> hrPendingCount() async {
    calls.hit('review');
    return 9;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeNoticeRepository implements NoticeRepository {
  _FakeNoticeRepository(this.calls);
  final _Calls calls;
  @override
  Future<int> unreadCount() async {
    calls.hit('unread');
    return 10;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeProductionPlanRepository implements ProductionPlanRepository {
  _FakeProductionPlanRepository(this.calls);
  final _Calls calls;
  @override
  Future<Map<String, int>> schedulePendingCount() async {
    calls.hit('production');
    return const {'count': 11, 'urgent': 2, 'overdue': 1};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _TestSessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();

  void signIn() {
    state = const SessionState(
      status: AuthStatus.authenticated,
      user: AppUser(
        id: 'u-1',
        code: 'ADMIN',
        name: '超管',
        roles: [],
        superAdmin: true,
      ),
    );
  }
}

/// 像工作台一样 watch 全部全局角标，让它们存活并把值渲染出来供断言。
class _BadgeWatcher extends ConsumerWidget {
  const _BadgeWatcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final epoch = ref.watch(sessionEpochProvider);
    final hr = ref.watch(hrTaskCountProvider);
    final rd = ref.watch(rdTaskCountProvider);
    final purchase = ref.watch(purchaseTaskCountProvider);
    final subcontract = ref.watch(subcontractTaskCountProvider);
    final visitor = ref.watch(visitorPendingCountProvider);
    final host = ref.watch(visitorHostPendingCountProvider);
    final review = ref.watch(pendingReviewCountProvider);
    final unread = ref.watch(unreadNoticeCountProvider);
    final production = ref.watch(productionPendingCountProvider).count;
    return Text(
      key: const Key('badges'),
      'epoch=$epoch hr=$hr rd=$rd purchase=$purchase '
      'subcontract=$subcontract visitor=$visitor host=$host '
      'review=$review unread=$unread production=$production',
    );
  }
}

/// 当前渲染出的角标快照（断言失败时同时打印实际值与期望值）。
String _badges(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('badges'))).data!;

void main() {
  testWidgets('未登录→已登录：推进 sessionEpoch，各全局角标恰好重拉一次并归到新会话值', (tester) async {
    final calls = _Calls();
    final session = _TestSessionNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(() => session),
          hrTaskRepositoryProvider.overrideWithValue(
            _FakeHrTaskRepository(calls),
          ),
          rdTaskRepositoryProvider.overrideWithValue(
            _FakeRdTaskRepository(calls),
          ),
          operationsWorkbenchRepositoryProvider.overrideWithValue(
            _FakeOperationsWorkbenchRepository(calls),
          ),
          visitorStaffRepositoryProvider.overrideWithValue(
            _FakeVisitorStaffRepository(calls),
          ),
          profileChangeRepositoryProvider.overrideWithValue(
            _FakeProfileChangeRepository(calls),
          ),
          noticeRepositoryProvider.overrideWithValue(
            _FakeNoticeRepository(calls),
          ),
          productionPlanRepositoryProvider.overrideWithValue(
            _FakeProductionPlanRepository(calls),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(children: [SessionRehydrateGate(), _BadgeWatcher()]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 未登录：权限自卫，除通知未读（人人可见、不按权限短路）外不发请求，全部为 0。
    expect(
      _badges(tester),
      'epoch=0 hr=0 rd=0 purchase=0 subcontract=0 visitor=0 host=0 '
      'review=0 unread=10 production=0',
    );
    for (final name in const [
      'hr',
      'rd',
      'purchase',
      'subcontract',
      'visitor',
      'host',
      'review',
      'production',
    ]) {
      expect(calls.of(name), 0, reason: '$name 未登录不应发请求');
    }
    final unreadBeforeLogin = calls.of('unread');

    session.signIn();
    await tester.pumpAndSettle();

    expect(
      _badges(tester),
      'epoch=1 hr=3 rd=4 purchase=5 subcontract=6 visitor=7 host=8 '
      'review=9 unread=10 production=11',
    );
    for (final name in const [
      'hr',
      'rd',
      'purchase',
      'subcontract',
      'visitor',
      'host',
      'review',
      'production',
    ]) {
      expect(calls.of(name), 1, reason: '$name 登录后应恰好重拉一次');
    }
    expect(calls.of('unread') - unreadBeforeLogin, 1, reason: '通知未读登录后应恰好重拉一次');

    // 释放 ProviderScope：各角标的 60s 轮询定时器随 onDispose 取消。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('已登录状态内的会话变化（同一用户）不推进 sessionEpoch', (tester) async {
    final calls = _Calls();
    final session = _TestSessionNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(() => session),
          hrTaskRepositoryProvider.overrideWithValue(
            _FakeHrTaskRepository(calls),
          ),
          rdTaskRepositoryProvider.overrideWithValue(
            _FakeRdTaskRepository(calls),
          ),
          operationsWorkbenchRepositoryProvider.overrideWithValue(
            _FakeOperationsWorkbenchRepository(calls),
          ),
          visitorStaffRepositoryProvider.overrideWithValue(
            _FakeVisitorStaffRepository(calls),
          ),
          profileChangeRepositoryProvider.overrideWithValue(
            _FakeProfileChangeRepository(calls),
          ),
          noticeRepositoryProvider.overrideWithValue(
            _FakeNoticeRepository(calls),
          ),
          productionPlanRepositoryProvider.overrideWithValue(
            _FakeProductionPlanRepository(calls),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(children: [SessionRehydrateGate(), _BadgeWatcher()]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    session.signIn();
    await tester.pumpAndSettle();
    expect(calls.of('hr'), 1);

    // 同一用户再次 login（如 token 刷新后的会话快照更新）：不是未登录→已登录跃迁。
    session.signIn();
    await tester.pumpAndSettle();
    expect(_badges(tester), startsWith('epoch=1 '));
    expect(calls.of('hr'), 1, reason: '同会话内不应重建/重拉');

    await tester.pumpWidget(const SizedBox());
  });
}
