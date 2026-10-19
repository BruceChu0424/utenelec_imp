import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/mould_picker_field.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

typedef _Binding = ({String? id, String? label, String? labelId});

class _Moulds extends Fake implements MouldRepository {
  final requests = <({String id, Completer<MouldDetail> response})>[];
  @override
  Future<MouldDetail> detail(String id) {
    final response = Completer<MouldDetail>();
    requests.add((id: id, response: response));
    return response.future;
  }
}

SensitiveReadBoundary _boundary({bool canRead = true}) => SensitiveReadBoundary(
  identity: const AuthenticatedScope(userId: 'editor'),
  api: ApiClient(Dio()),
  permissions: canRead ? {Perm.mouldView} : {},
  superAdmin: false,
);

Future<ProviderContainer> _host(
  WidgetTester tester,
  ValueNotifier<_Binding> binding,
  _Moulds repo,
  List<dynamic> changes, {
  StateProvider<SensitiveReadBoundary>? owner,
}) async {
  final container = ProviderContainer(
    overrides: [
      mouldRepositoryProvider.overrideWithValue(repo),
      if (owner != null)
        sensitiveReadBoundaryProvider.overrideWith((ref) => ref.watch(owner)),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(binding.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              final boundary = owner == null
                  ? null
                  : ref.watch(sensitiveReadBoundaryProvider);
              return ValueListenableBuilder<_Binding>(
                valueListenable: binding,
                builder: (_, value, _) => MouldPickerField(
                  initialValue: value.id,
                  initialDisplay: value.label,
                  initialDisplayId: value.labelId,
                  readBoundary: boundary,
                  onChanged: changes.add,
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

String _shown(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  testWidgets(
    'a failed or mismatched name read retains the bound UUID without displaying another mould',
    (tester) async {
      final binding = ValueNotifier<_Binding>((
        id: 'A',
        label: null,
        labelId: null,
      ));
      final repo = _Moulds();
      final changes = <dynamic>[];
      await _host(tester, binding, repo, changes);
      repo.requests.single.response.completeError(
        StateError('restricted or missing'),
      );
      await tester.pumpAndSettle();
      expect(_shown(tester), '已关联模具（名称暂不可用）');
      expect(binding.value.id, 'A');
      binding.value = (id: 'B', label: null, labelId: null);
      await tester.pump();
      repo.requests.last.response.complete(
        const MouldDetail(id: 'unrelated', code: 'WRONG', name: '其他模具'),
      );
      await tester.pumpAndSettle();
      expect(_shown(tester), '已关联模具（名称暂不可用）');
      expect(binding.value.id, 'B');
      expect(changes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a restored or changed UUID resolves its own name and clearing/cancelling text never changes the bound value',
    (tester) async {
      final binding = ValueNotifier<_Binding>((
        id: 'new',
        label: 'OLD 原模具',
        labelId: 'old',
      ));
      final repo = _Moulds();
      final changes = <dynamic>[];
      await _host(tester, binding, repo, changes);
      expect(_shown(tester), '已关联模具（名称待加载）');
      expect(repo.requests.single.id, 'new');
      repo.requests.single.response.complete(
        const MouldDetail(id: 'new', code: 'NEW', name: '恢复模具'),
      );
      await tester.pumpAndSettle();
      expect(_shown(tester), 'NEW 恢复模具');
      expect(changes, isEmpty);
      binding.value = (id: 'other', label: 'OLD 原模具', labelId: 'old');
      await tester.pump();
      expect(_shown(tester), '已关联模具（名称待加载）');
      repo.requests.last.response.complete(
        const MouldDetail(id: 'other', code: 'OTHER', name: '新关联'),
      );
      await tester.pumpAndSettle();
      expect(_shown(tester), 'OTHER 新关联');
      await tester.enterText(find.byType(TextField), '未确认的查找');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(_shown(tester), 'OTHER 新关联');
      expect(changes, isEmpty);
      await tester.tap(find.byTooltip('清除模具'));
      await tester.pumpAndSettle();
      expect(changes, [null]);
      expect(_shown(tester), isEmpty);
    },
  );

  testWidgets(
    'UUID ABA, failures and late success cannot overwrite the current binding or typed query',
    (tester) async {
      final binding = ValueNotifier<_Binding>((
        id: 'A',
        label: null,
        labelId: null,
      ));
      final repo = _Moulds();
      final changes = <dynamic>[];
      await _host(tester, binding, repo, changes);
      binding.value = (id: 'B', label: null, labelId: null);
      await tester.pump();
      binding.value = (id: 'A', label: null, labelId: null);
      await tester.pump();
      expect(repo.requests.map((r) => r.id), ['A', 'B', 'A']);
      repo.requests[0].response.complete(
        const MouldDetail(id: 'A', code: 'STALE', name: '旧响应'),
      );
      repo.requests[1].response.completeError(StateError('stale error'));
      await tester.pump();
      expect(_shown(tester), '已关联模具（名称待加载）');
      await tester.enterText(find.byType(TextField), '正在查找');
      repo.requests[2].response.complete(
        const MouldDetail(id: 'A', code: 'FRESH', name: '当前模具'),
      );
      await tester.pump();
      expect(_shown(tester), '正在查找');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(_shown(tester), 'FRESH 当前模具');
      expect(changes, isEmpty);
    },
  );

  testWidgets(
    'a paired goods summary remains readable without mould permission; a mismatched summary never impersonates the restored UUID',
    (tester) async {
      final binding = ValueNotifier<_Binding>((
        id: 'A',
        label: 'A 合法摘要',
        labelId: 'A',
      ));
      final repo = _Moulds();
      final changes = <dynamic>[];
      final owner = StateProvider<SensitiveReadBoundary>(
        (ref) => _boundary(canRead: false),
      );
      await _host(tester, binding, repo, changes, owner: owner);
      expect(_shown(tester), 'A 合法摘要');
      expect(repo.requests, isEmpty);
      binding.value = (id: 'B', label: 'A 合法摘要', labelId: 'A');
      await tester.pumpAndSettle();
      expect(_shown(tester), '已关联模具（名称暂不可用）');
      expect(repo.requests, isEmpty);
      expect(changes, isEmpty);
    },
  );

  testWidgets(
    'permission ABA and revocation reject late display reads and never rewrite the form UUID',
    (tester) async {
      final initial = _boundary();
      final owner = StateProvider<SensitiveReadBoundary>((ref) => initial);
      final binding = ValueNotifier<_Binding>((
        id: 'A',
        label: null,
        labelId: null,
      ));
      final repo = _Moulds();
      final changes = <dynamic>[];
      final container = await _host(
        tester,
        binding,
        repo,
        changes,
        owner: owner,
      );
      container.read(owner.notifier).state = _boundary(canRead: false);
      container.read(sensitiveReadBoundaryProvider);
      container.read(owner.notifier).state = initial;
      container.read(sensitiveReadBoundaryProvider);
      repo.requests[0].response.complete(
        const MouldDetail(id: 'A', code: 'OLD', name: '旧权限响应'),
      );
      await tester.pumpAndSettle();
      expect(_shown(tester), '已关联模具（名称待加载）');
      expect(repo.requests.length, 2);
      repo.requests[1].response.complete(
        const MouldDetail(id: 'A', code: 'NOW', name: '当前权限响应'),
      );
      await tester.pumpAndSettle();
      expect(_shown(tester), 'NOW 当前权限响应');
      container.read(owner.notifier).state = _boundary(canRead: false);
      container.read(sensitiveReadBoundaryProvider);
      await tester.pumpAndSettle();
      expect(_shown(tester), '已关联模具（名称暂不可用）');
      expect(binding.value.id, 'A');
      expect(changes, isEmpty);
    },
  );
}
