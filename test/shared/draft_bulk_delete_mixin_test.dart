import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/mixins/draft_bulk_delete_mixin.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../helpers/badge_summary_fixture.dart';

const _signedIn = AuthenticatedScope(userId: 'user-1');
final _scope = StateProvider<AuthenticatedScope?>((_) => _signedIn);

class _Operations {
  final deleted = <String>[];
  int reloads = 0;
  Future<void> Function(String) deleteHandler = (_) async {};
  Future<void> Function() reloadHandler = () async {};

  Future<void> delete(String id) async {
    deleted.add(id);
    await deleteHandler(id);
  }

  Future<void> reload() async {
    reloads++;
    await reloadHandler();
  }
}

class _Host extends StatefulWidget {
  const _Host({required this.operations, super.key});
  final _Operations operations;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with DraftBulkDeleteMixin<_Host> {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: buildDraftDeleteButton(
        documentLabel: '测试单',
        delete: widget.operations.delete,
        reload: widget.operations.reload,
      ),
    ),
  );
}

class _Fixture {
  const _Fixture(this.container, this.key, this.operations, this.badges);

  final ProviderContainer container;
  final GlobalKey<_HostState> key;
  final _Operations operations;
  final FixedBadgeSummaryNotifier badges;

  _HostState get state => key.currentState!;
  List<AppNotification> get notifications =>
      container.read(appNotificationProvider);

  void changeIdentity() {
    container.read(_scope.notifier).state = const AuthenticatedScope(
      userId: 'user-2',
    );
  }
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  AuthenticatedScope? scope = _signedIn,
}) async {
  final operations = _Operations();
  final badges = FixedBadgeSummaryNotifier(badgeSummaryFixture());
  final container = ProviderContainer(
    overrides: [
      _scope.overrideWith((_) => scope),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      badgeSummaryProvider.overrideWith(() => badges),
    ],
  );
  final key = GlobalKey<_HostState>();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: _Host(key: key, operations: operations),
      ),
    ),
  );
  key.currentState!.selectDraftIds({'a', 'b', 'c'});
  await tester.pumpAndSettle();
  return _Fixture(container, key, operations, badges);
}

Future<void> _openConfirmation(WidgetTester tester) async {
  await tester.tap(find.text('删除所选草稿 (3)'));
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.text('确认删除'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('取消确认不删除、不刷新并保留选择', (tester) async {
    final fixture = await _mount(tester);
    await _openConfirmation(tester);
    expect(fixture.operations.deleted, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(fixture.operations.deleted, isEmpty);
    expect(fixture.operations.reloads, 0);
    expect(fixture.badges.refreshCalls, 0);
    expect(fixture.state.selectedDraftIds, {'a', 'b', 'c'});
    expect(fixture.state.draftDeleteBusy, isFalse);
    expect(fixture.notifications, isEmpty);
  });

  testWidgets('明确部分失败继续后续，成功移出选择、失败保留', (tester) async {
    final fixture = await _mount(tester);
    fixture.operations.deleteHandler = (id) async {
      if (id == 'b') throw ApiException('CONFLICT', '单据已提交财务');
    };
    await _openConfirmation(tester);
    await _confirm(tester);

    expect(fixture.operations.deleted, ['a', 'b', 'c']);
    expect(fixture.state.selectedDraftIds, {'b'});
    expect(fixture.operations.reloads, 1);
    expect(fixture.badges.refreshCalls, 1);
    expect(fixture.notifications.single.kind, AppNotificationKind.warning);
    expect(fixture.notifications.single.message, contains('已删除 2 张'));
    expect(fixture.notifications.single.message, contains('1 张未删除：单据已提交财务'));
    expect(fixture.state.draftDeleteBusy, isFalse);
  });

  for (final error in <Object>[
    NetworkException(),
    NetworkTimeoutException(),
    ApiException('UPSTREAM', '网关错误', httpStatus: 503),
    StateError('无法确定请求结果'),
  ]) {
    testWidgets('${error.runtimeType} 不确定结果停止后续且不宣称失败未生效', (tester) async {
      final fixture = await _mount(tester);
      fixture.operations.deleteHandler = (id) async {
        if (id == 'b') throw error;
      };
      await _openConfirmation(tester);
      await _confirm(tester);

      expect(fixture.operations.deleted, ['a', 'b']);
      expect(fixture.state.selectedDraftIds, {'b', 'c'});
      expect(fixture.operations.reloads, 1);
      expect(fixture.badges.refreshCalls, 1);
      final notice = fixture.notifications.single;
      expect(notice.kind, AppNotificationKind.warning);
      expect(notice.message, contains('已删除 1 张'));
      expect(notice.message, contains('删除结果尚未确认'));
      expect(notice.message, contains('已停止后续删除'));
      expect(notice.message, isNot(contains('未删除')));
      expect(notice.message, isNot(contains('删除失败')));
    });
  }

  testWidgets('确认期间清除选择后不发任何删除', (tester) async {
    final fixture = await _mount(tester);
    await _openConfirmation(tester);
    fixture.state.clearDraftSelection();
    await tester.pump();
    await _confirm(tester);

    expect(fixture.operations.deleted, isEmpty);
    expect(fixture.operations.reloads, 0);
    expect(fixture.notifications, isEmpty);
    expect(fixture.state.selectedDraftIds, isEmpty);
    expect(fixture.state.draftDeleteBusy, isFalse);
  });

  testWidgets('空闲时切换身份立即清理旧选择并禁用删除', (tester) async {
    final fixture = await _mount(tester);
    fixture.changeIdentity();
    await tester.pumpAndSettle();

    expect(fixture.state.selectedDraftIds, isEmpty);
    expect(
      tester.widget<UtenButton>(find.byType(UtenButton)).onPressed,
      isNull,
    );
    expect(fixture.operations.deleted, isEmpty);
    expect(fixture.operations.reloads, 0);
  });

  testWidgets('确认期间切换身份后不删除且清理旧身份选择', (tester) async {
    final fixture = await _mount(tester);
    await _openConfirmation(tester);
    fixture.changeIdentity();
    await tester.pump();
    await _confirm(tester);

    expect(fixture.operations.deleted, isEmpty);
    expect(fixture.operations.reloads, 0);
    expect(fixture.notifications, isEmpty);
    expect(
      fixture.state.selectedDraftIds,
      isEmpty,
      reason: '新身份不能再次点击删除旧身份的选择',
    );
    expect(fixture.state.draftDeleteBusy, isFalse);
  });

  testWidgets('执行中选择范围变化停止后续，保留已经完成的成功结果', (tester) async {
    final fixture = await _mount(tester);
    final first = Completer<void>();
    fixture.operations.deleteHandler = (_) => first.future;
    await _openConfirmation(tester);
    await _confirm(tester);
    expect(fixture.operations.deleted, ['a']);

    fixture.state.clearDraftSelection();
    first.complete();
    await tester.pumpAndSettle();

    expect(fixture.operations.deleted, ['a']);
    expect(fixture.operations.reloads, 1);
    expect(fixture.state.selectedDraftIds, isEmpty);
    expect(fixture.notifications.single.message, contains('已删除 1 张'));
    expect(fixture.notifications.single.message, contains('选择范围已变化'));
    expect(fixture.state.draftDeleteBusy, isFalse);
  });

  testWidgets('执行中切换身份停止后续且不向新身份发布旧操作结果', (tester) async {
    final fixture = await _mount(tester);
    final first = Completer<void>();
    fixture.operations.deleteHandler = (_) => first.future;
    await _openConfirmation(tester);
    await _confirm(tester);
    expect(fixture.operations.deleted, ['a']);

    fixture.changeIdentity();
    first.complete();
    await tester.pumpAndSettle();

    expect(fixture.operations.deleted, ['a']);
    expect(fixture.operations.reloads, 0);
    expect(fixture.badges.refreshCalls, 0);
    expect(fixture.notifications, isEmpty);
    expect(fixture.state.selectedDraftIds, isEmpty);
    expect(fixture.state.draftDeleteBusy, isFalse);
  });

  testWidgets('同帧重复触发及请求进行中重触发均不并发执行', (tester) async {
    final fixture = await _mount(tester);
    final first = Completer<void>();
    var active = 0;
    var maxActive = 0;
    fixture.operations.deleteHandler = (id) async {
      active++;
      if (active > maxActive) maxActive = active;
      if (id == 'a') await first.future;
      active--;
    };
    final start = tester.widget<UtenButton>(find.byType(UtenButton)).onPressed!;
    start();
    start();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await _confirm(tester);
    start();
    await tester.pump();
    expect(fixture.operations.deleted, ['a']);
    expect(maxActive, 1);

    first.complete();
    await tester.pumpAndSettle();
    expect(fixture.operations.deleted, ['a', 'b', 'c']);
    expect(maxActive, 1);
    expect(fixture.operations.reloads, 1);
    expect(fixture.badges.refreshCalls, 1);
    expect(fixture.state.selectedDraftIds, isEmpty);
  });

  testWidgets('列表刷新失败仍明确报告已删除成功，不把成功说成删除失败', (tester) async {
    final fixture = await _mount(tester);
    fixture.operations.reloadHandler = () async => throw StateError('刷新失败');
    await _openConfirmation(tester);
    await _confirm(tester);

    expect(fixture.operations.deleted, ['a', 'b', 'c']);
    expect(fixture.state.selectedDraftIds, isEmpty);
    expect(fixture.badges.refreshCalls, 1);
    final notice = fixture.notifications.single;
    expect(notice.kind, AppNotificationKind.warning);
    expect(notice.message, contains('已删除 3 张'));
    expect(notice.message, contains('列表刷新未完成'));
    expect(notice.message, isNot(contains('删除失败')));
  });

  for (final scope in <AuthenticatedScope?>[
    null,
    const AuthenticatedScope(userId: 'user-1', readOnly: true),
  ]) {
    testWidgets('${scope == null ? '未登录' : '只读代操作'}不提供执行删除机会', (tester) async {
      final fixture = await _mount(tester, scope: scope);
      await _openConfirmation(tester);
      if (find.text('确认删除').evaluate().isNotEmpty) {
        await _confirm(tester);
      }
      expect(fixture.operations.deleted, isEmpty);
      expect(fixture.operations.reloads, 0);
      expect(fixture.notifications, isEmpty);
    });
  }
}
