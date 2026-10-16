import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/mould_picker_field.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets('新输入防抖期间旧成功响应不能展示无关模具', (tester) async {
    final repository = _Moulds();
    final old = repository.hold('', 1);
    final fresh = repository.hold('螺丝 M3', 1);
    await _open(tester, repository);
    await tester.enterText(_search(), '螺丝 M3');
    old.complete(_page('旧模具', page: 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('旧模具'), findsNothing);
    expect(repository.requests, [('', 1)]);
    await tester.pump(const Duration(milliseconds: 201));
    fresh.complete(_page('新模具', page: 1));
    await tester.pumpAndSettle();
    expect(repository.requests, [('', 1), ('螺丝 M3', 1)]);
    expect(find.text('新模具'), findsOneWidget);
    expect(find.text('旧模具'), findsNothing);
  });

  testWidgets('旧错误不会覆盖新结果或关闭新查询的加载状态', (tester) async {
    final repository = _Moulds();
    final old = repository.hold('', 1);
    final fresh = repository.hold('新词', 1);
    await _open(tester, repository);
    await tester.enterText(_search(), '新词');
    await tester.pump(const Duration(milliseconds: 301));
    old.completeError(StateError('old request failed'));
    await tester.pump();
    expect(find.text('模具搜索失败，请重试'), findsNothing);
    fresh.complete(_page('新模具', page: 1));
    await tester.pumpAndSettle();
    expect(find.text('新模具'), findsOneWidget);
    expect(find.text('模具搜索失败，请重试'), findsNothing);
  });

  testWidgets('模具可翻到首50条以后的页并回填稳定ID', (tester) async {
    final repository = _Moulds();
    String? picked;
    await _open(
      tester,
      repository,
      onChanged: (value) => picked = value as String?,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(repository.requests, [('', 1), ('', 2)]);
    await tester.tap(find.text('第2页模具'));
    await tester.pumpAndSettle();
    expect(picked, 'mould-2');
    expect(find.text('选择模具'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('后页失败可重试同一页', (tester) async {
    final repository = _Moulds();
    final failing = repository.hold('', 2);
    await _open(tester, repository);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一页'));
    await tester.pump();
    failing.completeError(StateError('temporary failure'));
    await tester.pumpAndSettle();
    repository.release('', 2);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(repository.requests, [('', 1), ('', 2), ('', 2)]);
    expect(find.text('第2页模具'), findsOneWidget);
  });
}

Finder _search() => find.descendant(
  of: find.byType(BottomSheet),
  matching: find.byType(EditableText),
);

Future<void> _open(
  WidgetTester tester,
  _Moulds repository, {
  ValueChanged<dynamic>? onChanged,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [mouldRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        home: Scaffold(
          body: MouldPickerField(
            initialValue: null,
            initialDisplay: null,
            onChanged: onChanged ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byType(TextField));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

class _Moulds extends Fake implements MouldRepository {
  final requests = <(String, int)>[];
  final _held = <(String, int), Completer<PagedResult<MouldListItem>>>{};

  Completer<PagedResult<MouldListItem>> hold(String query, int page) =>
      _held[(query, page)] = Completer<PagedResult<MouldListItem>>();

  void release(String query, int page) => _held.remove((query, page));

  @override
  Future<PagedResult<MouldListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
  }) async {
    requests.add((keyword, page));
    return _held[(keyword, page)]?.future ?? _page('第$page页模具', page: page);
  }
}

PagedResult<MouldListItem> _page(String name, {required int page}) =>
    PagedResult(
      items: [MouldListItem(id: 'mould-$page', code: 'M$page', name: name)],
      page: page,
      size: 50,
      total: 51,
      totalPages: 2,
    );
