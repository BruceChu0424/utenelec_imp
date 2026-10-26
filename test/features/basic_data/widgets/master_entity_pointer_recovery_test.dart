import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

final _initialApi = ApiClient(Dio());
final _boundary = NotifierProvider<_Boundary, SensitiveReadBoundary>(
  _Boundary.new,
);

SensitiveReadBoundary _scope({
  String userId = 'pointer-recovery-test',
  ApiClient? api,
  bool editable = false,
}) => SensitiveReadBoundary(
  identity: AuthenticatedScope(userId: userId),
  api: api ?? _initialApi,
  permissions: {Perm.goodsView, if (editable) Perm.goodsEdit},
  superAdmin: false,
);

class _Boundary extends Notifier<SensitiveReadBoundary> {
  @override
  SensitiveReadBoundary build() => _scope();

  void replace(SensitiveReadBoundary value) => state = value;
}

PagedResult<String> _page(String row) => PagedResult<String>(
  items: [row],
  page: 1,
  size: 20,
  total: 1,
  totalPages: 1,
);

class _Read {
  _Read(this.query);

  final MasterPaneQuery query;
  final result = Completer<PagedResult<String>>();
}

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.categoryId = 'cat-1'});

  final String? categoryId;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String? keyword;
  bool pending = false;
  int openings = 0;
  int listCalls = 0;
  final reads = <_Read>[];

  void search({required String? keyword, required bool pending}) {
    setState(() {
      this.keyword = keyword;
      this.pending = pending;
    });
  }

  late final config = MasterEntityPaneConfig<String, String>(
    noun: '货品',
    icon: Icons.inventory_2_outlined,
    defaultCodePrefix: 'HP',
    columns: [
      MasterColumnDef<String>(
        key: 'name',
        label: '货品名称',
        width: 300,
        value: (row) => row,
      ),
    ],
    idOf: (row) => row,
    statusOf: (_) => '使用',
    labelOf: (row) => row,
    loadCategory: (id) async => ProductCategoryDetail(
      id: id,
      code: 'C1',
      name: '成品类',
      level: 0,
      path: '成品类',
      childCount: 0,
    ),
    loadPage: (query) {
      if (listCalls++ == 0) return Future.value(_page('原始货品'));
      final read = _Read(query);
      reads.add(read);
      return read.result.future;
    },
    loadFacets: (_) async => const MasterPaneFacets(fields: {}, nullCounts: {}),
    batchEntityPath: '/master/goods',
    statusResourceOf: (id) => '/master/goods/$id',
    canCreate: false,
    canEdit: false,
    canDelete: false,
    canStatus: false,
    onOpen: (_, _) async => openings++,
  );

  @override
  Widget build(BuildContext context) => MasterEntityDetailPane<String, String>(
    config: config,
    categoryId: widget.categoryId,
    externalKeyword: keyword,
    externalSearchPending: pending,
  );
}

Future<_HarnessState> _pumpHarness(
  WidgetTester tester, {
  String? categoryId = 'cat-1',
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1600, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final key = GlobalKey<_HarnessState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWith((ref) => ref.watch(_boundary).api),
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWith(
          (ref) => ref.watch(_boundary).identity,
        ),
        sensitiveReadBoundaryProvider.overrideWith(
          (ref) => ref.watch(_boundary),
        ),
        currentPermissionsProvider.overrideWithValue({Perm.goodsView}),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (_, child) => UtenContextMenuPolicy(child: child!),
        home: Scaffold(
          body: _Harness(key: key, categoryId: categoryId),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key.currentState!;
}

bool _queryBlocked(WidgetTester tester) => tester
    .widget<AbsorbPointer>(
      find
          .ancestor(
            of: find.byType(MasterDataTableView<String>),
            matching: find.byType(AbsorbPointer),
          )
          .first,
    )
    .absorbing;

Future<void> _doubleClick(WidgetTester tester, String row) async {
  final position = tester.getCenter(find.text(row));
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 70));
  await tester.tapAt(position);
  await tester.pump();
}

Future<void> _rightClick(WidgetTester tester, String row) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text(row)),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pump();
}

Future<void> _expectBlocked(
  WidgetTester tester,
  _HarnessState harness,
  String row,
) async {
  expect(_queryBlocked(tester), isTrue);
  final previousOpenings = harness.openings;
  await _doubleClick(tester, row);
  await _rightClick(tester, row);
  expect(harness.openings, previousOpenings);
  expect(find.text('查看详情'), findsNothing);
}

Future<void> _expectRecovered(
  WidgetTester tester,
  _HarnessState harness,
  String row,
) async {
  expect(_queryBlocked(tester), isFalse);
  final previousOpenings = harness.openings;
  await _doubleClick(tester, row);
  expect(harness.openings, previousOpenings + 1);
  await _rightClick(tester, row);
  expect(find.text('查看详情'), findsOneWidget);
  await tester.tapAt(const Offset(1580, 980));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('慢搜索只在结果过期期间拦截，完成后双击和右键均恢复', (tester) async {
    final harness = await _pumpHarness(tester);
    harness.search(keyword: null, pending: true);
    await tester.pump();
    await _expectBlocked(tester, harness, '原始货品');

    harness.search(keyword: '螺丝', pending: false);
    await tester.pump();
    expect(harness.reads.single.query.keyword, '螺丝');
    await tester.pump(const Duration(seconds: 5));
    await _expectBlocked(tester, harness, '原始货品');

    harness.reads.single.result.complete(_page('螺丝货品'));
    await tester.pumpAndSettle();
    await _expectRecovered(tester, harness, '螺丝货品');
  });

  testWidgets('连续输入的旧请求晚返回不解锁新查询，新结果后双击和右键恢复', (tester) async {
    final harness = await _pumpHarness(tester);
    harness.search(keyword: null, pending: true);
    await tester.pump();
    harness.search(keyword: '螺', pending: false);
    await tester.pump();
    final oldRead = harness.reads.single;

    harness.search(keyword: '螺', pending: true);
    await tester.pump();
    harness.search(keyword: '螺丝', pending: false);
    await tester.pump();
    final currentRead = harness.reads.last;
    expect(harness.reads, hasLength(2));
    expect(currentRead.query.keyword, '螺丝');

    oldRead.result.complete(_page('旧搜索结果'));
    await tester.pump();
    expect(find.text('旧搜索结果'), findsNothing);
    await _expectBlocked(tester, harness, '原始货品');

    currentRead.result.complete(_page('最新搜索结果'));
    await tester.pumpAndSettle();
    await _expectRecovered(tester, harness, '最新搜索结果');
  });

  testWidgets('搜索失败解除等待并显示错误，清空搜索后双击和右键恢复', (tester) async {
    final harness = await _pumpHarness(tester);
    harness.search(keyword: null, pending: true);
    await tester.pump();
    harness.search(keyword: '螺丝', pending: false);
    await tester.pump();
    harness.reads.single.result.completeError(
      ApiException('NETWORK_ERROR', '测试网络中断'),
    );
    await tester.pumpAndSettle();
    expect(_queryBlocked(tester), isFalse);
    expect(find.textContaining('测试网络中断'), findsOneWidget);

    harness.search(keyword: '螺丝', pending: true);
    await tester.pump();
    harness.search(keyword: null, pending: false);
    await tester.pump();
    expect(harness.reads, hasLength(2));
    expect(harness.reads.last.query.keyword, isNull);
    harness.reads.last.result.complete(_page('恢复后的货品'));
    await tester.pumpAndSettle();
    await _expectRecovered(tester, harness, '恢复后的货品');
  });

  for (final categoryId in <String?>['cat-1', null]) {
    final mode = categoryId == null ? '全局资料' : '分类资料';
    testWidgets('$mode 搜索防抖时身份和API切换，提交同词后启动替代请求并恢复操作', (tester) async {
      final harness = await _pumpHarness(tester, categoryId: categoryId);
      harness.search(keyword: null, pending: true);
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(_Harness)),
      );
      container
          .read(_boundary.notifier)
          .replace(_scope(userId: '员工B', api: ApiClient(Dio())));
      await tester.pump();
      await tester.pump();
      expect(find.text('原始货品'), findsNothing);
      expect(harness.reads, isEmpty);

      harness.search(keyword: null, pending: false);
      await tester.pump();
      await tester.pump();
      expect(harness.reads, hasLength(1));
      expect(harness.reads.single.query.categoryId, categoryId);
      harness.reads.single.result.complete(_page('新身份资料'));
      await tester.pumpAndSettle();
      await _expectRecovered(tester, harness, '新身份资料');
    });

    testWidgets('$mode 搜索请求中权限和API连续切换，旧请求迟到不阻止替代结果恢复', (tester) async {
      final harness = await _pumpHarness(tester, categoryId: categoryId);
      harness.search(keyword: null, pending: true);
      await tester.pump();
      harness.search(keyword: '螺丝', pending: false);
      await tester.pump();
      final oldRead = harness.reads.single;
      final container = ProviderScope.containerOf(
        tester.element(find.byType(_Harness)),
      );
      container.read(_boundary.notifier).replace(_scope(editable: true));
      container.read(sensitiveReadBoundaryProvider);
      container
          .read(_boundary.notifier)
          .replace(_scope(api: ApiClient(Dio()), editable: true));
      container.read(sensitiveReadBoundaryProvider);
      await tester.pump();
      await tester.pump();
      expect(harness.reads, hasLength(2));
      final replacement = harness.reads.last;
      expect(replacement.query.keyword, '螺丝');
      replacement.result.complete(_page('新权限资料'));
      await tester.pumpAndSettle();
      oldRead.result.complete(_page('过期权限资料'));
      await tester.pumpAndSettle();
      expect(find.text('过期权限资料'), findsNothing);
      await _expectRecovered(tester, harness, '新权限资料');
    });

    testWidgets('$mode 同词搜索重新进入pending仍发新请求，取消后能再次搜索恢复', (tester) async {
      final harness = await _pumpHarness(tester, categoryId: categoryId);
      harness.search(keyword: null, pending: true);
      await tester.pump();
      harness.search(keyword: '螺丝', pending: false);
      await tester.pump();
      harness.reads.single.result.complete(_page('螺丝资料'));
      await tester.pumpAndSettle();

      harness.search(keyword: '螺丝', pending: true);
      await tester.pump();
      harness.search(keyword: '螺丝', pending: false);
      await tester.pump();
      expect(harness.reads, hasLength(2));
      harness.reads.last.result.completeError(
        DioException(
          requestOptions: RequestOptions(path: '/master/goods'),
          type: DioExceptionType.cancel,
        ),
      );
      await tester.pumpAndSettle();
      expect(_queryBlocked(tester), isFalse);
      expect(find.textContaining('加载货品列表失败'), findsOneWidget);

      harness.search(keyword: '螺丝', pending: true);
      await tester.pump();
      harness.search(keyword: '螺丝', pending: false);
      await tester.pump();
      expect(harness.reads, hasLength(3));
      harness.reads.last.result.complete(_page('重试资料'));
      await tester.pumpAndSettle();
      await _expectRecovered(tester, harness, '重试资料');
    });
  }
}
