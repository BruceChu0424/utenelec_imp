import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_reference_picker_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_category_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/mould_picker_field.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

const _candidate = MouldListItem(id: 'old-mould', code: 'M1', name: '边界模具');

SensitiveReadBoundary _boundary({String user = 'A', bool canRead = true}) =>
    SensitiveReadBoundary(
      identity: AuthenticatedScope(userId: user),
      api: ApiClient(Dio()),
      permissions: canRead ? {Perm.mouldView} : {},
      superAdmin: false,
    );

void main() {
  testWidgets('撤权与同帧A-B-A后旧候选回调均不可回填', (tester) async {
    final initial = _boundary();
    final source = StateProvider<SensitiveReadBoundary>((ref) => initial);
    final changes = <dynamic>[];
    final container = await _host(tester, source, _Moulds(), changes);
    await tester.enterText(find.byType(TextField), 'M');
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pumpAndSettle();
    expect(find.text('M1 边界模具'), findsOneWidget);
    final old = tester.widget<UtenReferencePickerField<MouldListItem>>(
      find.byType(UtenReferencePickerField<MouldListItem>),
    );
    container.read(source.notifier).state = _boundary(canRead: false);
    container.read(sensitiveReadBoundaryProvider);
    old.onSelected(_candidate);
    expect(changes, isEmpty);
    container.read(source.notifier).state = initial;
    container.read(sensitiveReadBoundaryProvider);
    expect(old.isCurrent!(), isFalse);
    old.onSelected(_candidate);
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(find.text('M1 边界模具'), findsNothing);
  });

  testWidgets('接口或身份变化后迟到模具候选不能展示或回填', (tester) async {
    final held = Completer<PagedResult<MouldListItem>>();
    final source = StateProvider<SensitiveReadBoundary>((ref) => _boundary());
    final changes = <dynamic>[];
    final container = await _host(
      tester,
      source,
      _Moulds(hints: held),
      changes,
    );
    await tester.enterText(find.byType(TextField), 'M');
    await tester.pump(const Duration(milliseconds: 301));
    container.read(source.notifier).state = _boundary(user: 'B');
    container.read(sensitiveReadBoundaryProvider);
    held.complete(_page());
    await tester.pumpAndSettle();
    expect(find.text('M1 边界模具'), findsNothing);
    expect(changes, isEmpty);
  });

  testWidgets('完整模具面板撤权关闭，旧行回调不能写入', (tester) async {
    final source = StateProvider<SensitiveReadBoundary>((ref) => _boundary());
    final changes = <dynamic>[];
    final container = await _host(tester, source, _Moulds(), changes);
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    final table = tester.widget<MasterDataTableView<MouldListItem>>(
      find.byKey(const Key('mould-picker-results')),
    );
    container.read(source.notifier).state = _boundary(canRead: false);
    container.read(sensitiveReadBoundaryProvider);
    table.onRowTap!(_candidate);
    await tester.pumpAndSettle();
    expect(find.text('选择模具'), findsNothing);
    expect(changes, isEmpty);
  });

  testWidgets('完整面板请求中的A-B-A不会保留面板或迟到结果', (tester) async {
    final initial = _boundary();
    final source = StateProvider<SensitiveReadBoundary>((ref) => initial);
    final held = Completer<PagedResult<MouldListItem>>();
    final changes = <dynamic>[];
    final container = await _host(tester, source, _Moulds(rows: held), changes);
    await tester.tap(find.text('选择'));
    await tester.pump(const Duration(milliseconds: 300));
    container.read(source.notifier).state = _boundary(user: 'B');
    container.read(sensitiveReadBoundaryProvider);
    container.read(source.notifier).state = initial;
    container.read(sensitiveReadBoundaryProvider);
    await tester.pumpAndSettle();
    held.complete(_page());
    await tester.pumpAndSettle();
    expect(find.text('选择模具'), findsNothing);
    expect(find.text('边界模具'), findsNothing);
    expect(changes, isEmpty);
  });
}

Future<ProviderContainer> _host(
  WidgetTester tester,
  StateProvider<SensitiveReadBoundary> source,
  _Moulds repository,
  List<dynamic> changes,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      sensitiveReadBoundaryProvider.overrideWith((ref) => ref.watch(source)),
      mouldRepositoryProvider.overrideWithValue(repository),
      mouldCategoryRepositoryProvider.overrideWithValue(_Categories()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => MouldPickerField(
              initialValue: null,
              initialDisplay: null,
              onChanged: changes.add,
              readBoundary: ref.watch(sensitiveReadBoundaryProvider),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

PagedResult<MouldListItem> _page() => const PagedResult(
  items: [_candidate],
  page: 1,
  size: 50,
  total: 1,
  totalPages: 1,
);

class _Moulds extends Fake implements MouldRepository {
  _Moulds({this.hints, this.rows});
  final Completer<PagedResult<MouldListItem>>? hints;
  final Completer<PagedResult<MouldListItem>>? rows;
  @override
  Future<PagedResult<MouldListItem>> search(
    String keyword, {
    int page = 1,
    int size = 20,
  }) async => hints?.future ?? _page();
  @override
  Future<PagedResult<MouldListItem>> listGlobal({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
    String? sort,
    String? order,
  }) async => rows?.future ?? _page();
  @override
  Future<MouldFacets> globalFacets() async =>
      const MouldFacets(fields: {}, nullCounts: {});
}

class _Categories extends Fake implements MouldCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [];
}
