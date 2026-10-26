import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/repositories/unit_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/rd_task/models/rd_task.dart';
import 'package:uten_imp/features/rd_task/pages/rd_task_page.dart';
import 'package:uten_imp/features/rd_task/widgets/rd_initial_basic_unit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'A'),
);

class _Api extends ApiClient {
  _Api({
    this.actions = const ['RESOLVE', 'RECONCILE_BASIC_UNIT'],
    this.sourceDocType = 'MATERIAL_ANALYSIS_MASTER_ISSUE',
  }) : super(Dio(BaseOptions(baseUrl: 'https://a.test/api')));
  final List<String> actions;
  final String sourceDocType;
  final posts = <String>[];
  Completer<AuthenticatedRequestScope>? nextCapture;

  @override
  Future<AuthenticatedRequestScope> captureRequestScope({
    required bool Function() isCurrent,
  }) {
    final gate = nextCapture;
    nextCapture = null;
    return gate?.future ?? super.captureRequestScope(isCurrent: isCurrent);
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/initial-basic-unit')) return {'allowed': true};
    if (path != '/rd-tasks') return const {};
    return {
      'items': [
        {
          'id': 'task',
          'taskNo': 'RD-UNIT-1',
          'title': '核对组件基本单位',
          'goodsName': '单位待核对组件',
          'category': 'OTHER',
          'status': 'OPEN',
          'priority': 'NORMAL',
          'rowVersion': 1,
          'goodsId': 'goods',
          'sourceDocType': sourceDocType,
          'allowedActions': actions,
        },
      ],
      'page': 1,
      'size': 20,
      'total': 1,
      'totalPages': 1,
    };
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    posts.add(path);
    return const {};
  }
}

class _Units extends Fake implements UnitRepository {
  @override
  Future<List<UnitListItem>> dict() async => const [
    UnitListItem(id: 'unit', name: '个', status: '使用'),
  ];
}

Future<void> _mount(
  WidgetTester tester,
  _Api api, {
  double width = 1400,
  double scale = 1,
  bool canResolve = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        unitRepositoryProvider.overrideWithValue(_Units()),
        sharedPreferencesProvider.overrideWithValue(preferences),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        currentPermissionsProvider.overrideWithValue({
          Perm.rdTaskView,
          if (canResolve) Perm.rdTaskResolve,
          Perm.goodsView,
          Perm.goodsEdit,
          Perm.unitView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const RdTaskPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('取消核对后浮动按钮恢复可点并可再次打开', (tester) async {
    final api = _Api(actions: const ['RECONCILE_BASIC_UNIT']);
    await _mount(tester, api, canResolve: false);
    await tester.tap(find.text('RD-UNIT-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对基本单位'));
    await tester.pumpAndSettle();
    expect(find.byType(RdInitialBasicUnitDialog), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(834, 900));
    await tester.pumpAndSettle();
    expect(find.text('处理中…'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('处理中…'), findsNothing);
    await tester.tap(find.text('核对基本单位'));
    await tester.pumpAndSettle();
    expect(find.byType(RdInitialBasicUnitDialog), findsOneWidget);
    expect(api.posts, isEmpty);
  });

  testWidgets('捕获请求scope异常释放忙态并允许重试', (tester) async {
    final api = _Api(actions: const ['RECONCILE_BASIC_UNIT']);
    final capture = Completer<AuthenticatedRequestScope>();
    api.nextCapture = capture;
    await _mount(tester, api, canResolve: false);
    await tester.tap(find.text('RD-UNIT-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对基本单位'));
    await tester.pump();
    await tester.binding.setSurfaceSize(const Size(834, 900));
    await tester.pumpAndSettle();
    expect(find.text('处理中…'), findsOneWidget);
    capture.completeError(StateError('capture unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('处理中…'), findsNothing);
    await tester.tap(find.text('核对基本单位'));
    await tester.pumpAndSettle();
    expect(find.byType(RdInitialBasicUnitDialog), findsOneWidget);
    expect(api.posts, isEmpty);
  });

  testWidgets('旧capture经身份ABA迟到不清除新核对操作忙态', (tester) async {
    final api = _Api(actions: const ['RECONCILE_BASIC_UNIT']);
    final oldScope = await api.captureRequestScope(isCurrent: () => true);
    final gate = Completer<AuthenticatedRequestScope>();
    api.nextCapture = gate;
    await _mount(tester, api, canResolve: false);
    await tester.tap(find.text('RD-UNIT-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对基本单位'));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RdTaskPage)),
    );
    container.read(_identity.notifier).state = const AuthenticatedScope(
      userId: 'B',
    );
    await tester.pump();
    container.read(_identity.notifier).state = const AuthenticatedScope(
      userId: 'A',
    );
    await tester.pumpAndSettle();
    expect(find.text('核对基本单位'), findsNothing);
    await tester.tap(find.text('RD-UNIT-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对基本单位'));
    await tester.pumpAndSettle();
    expect(find.byType(RdInitialBasicUnitDialog), findsOneWidget);
    gate.complete(oldScope);
    await tester.pumpAndSettle();
    expect(find.byType(RdInitialBasicUnitDialog), findsOneWidget);
    expect(find.text('处理中…'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('处理中…'), findsNothing);
    expect(find.text('核对基本单位'), findsOneWidget);
    expect(api.posts, isEmpty);
  });
  for (final layout in [(1400.0, 1.0), (375.0, 1.6)]) {
    testWidgets('选中上下文动作不移动行或表头 ${layout.$1}/${layout.$2}', (tester) async {
      await _mount(tester, _Api(), width: layout.$1, scale: layout.$2);
      final row = find.text('RD-UNIT-1');
      final rowTarget = find
          .ancestor(of: row, matching: find.byType(InkWell))
          .first;
      final rowElement = tester.element(rowTarget);
      final header = find.text('任务号');
      final rowBounds = tester.getRect(rowTarget);
      final headerTop = tester.getTopLeft(header).dy;
      final point = tester.getCenter(row);
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 40));
      debugPrint(
        'RD selection geometry: row ${rowBounds.top} -> '
        '${tester.getTopLeft(rowTarget).dy}; '
        'header $headerTop -> ${tester.getTopLeft(header).dy}',
      );
      final selectedBounds = tester.getRect(rowTarget);
      expect(selectedBounds.top, closeTo(rowBounds.top, 0.01));
      expect(selectedBounds.left, rowBounds.left);
      expect(selectedBounds.right, rowBounds.right);
      expect(selectedBounds.contains(point), isTrue);
      expect(tester.getTopLeft(header).dy, closeTo(headerTop, 0.01));
      expect(identical(tester.element(rowTarget), rowElement), isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('首次在同一固定坐标双击单位任务打开核对，不误开表头筛选', (tester) async {
    final api = _Api();
    await _mount(tester, api);
    final point = tester.getCenter(find.text('RD-UNIT-1'));
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(point);
    await tester.pumpAndSettle();
    expect(find.byType(RdInitialBasicUnitDialog), findsOneWidget);
    expect(find.byKey(const Key('uten-column-keyword-input')), findsNothing);
    expect(api.posts, isEmpty, reason: '打开核对不能隐式标记完成');
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务器仅授权单位核对时上下文准确命名并走核对入口', (tester) async {
    final api = _Api(actions: const ['RECONCILE_BASIC_UNIT']);
    await _mount(tester, api, canResolve: false);
    final table = tester.widget<MasterDataTableView<RdTaskRow>>(
      find.byType(MasterDataTableView<RdTaskRow>),
    );
    expect(
      table.rowMenuBuilder!(table.items.single)
          .whereType<UtenMenuItem>()
          .single
          .label,
      '核对基本单位',
    );
    await tester.tap(find.text('RD-UNIT-1'));
    await tester.pumpAndSettle();
    expect(find.text('标记完成'), findsNothing);
    await tester.tap(find.text('核对基本单位'));
    await tester.pumpAndSettle();
    expect(find.byType(RdInitialBasicUnitDialog), findsOneWidget);
    expect(api.posts, isEmpty);
  });

  testWidgets('普通完成任务保持原确认动作，未授权行不出现完成入口', (tester) async {
    await _mount(tester, _Api(actions: const ['RESOLVE']));
    final table = tester.widget<MasterDataTableView<RdTaskRow>>(
      find.byType(MasterDataTableView<RdTaskRow>),
    );
    expect(
      table.rowMenuBuilder!(table.items.single)
          .whereType<UtenMenuItem>()
          .first
          .label,
      '打开货品资料',
    );
    await tester.tap(find.text('RD-UNIT-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标记完成'));
    await tester.pumpAndSettle();
    expect(find.text('标记任务完成'), findsOneWidget);
    expect(find.byType(RdInitialBasicUnitDialog), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await _mount(tester, _Api(actions: const [], sourceDocType: 'GOODS_BOM'));
    final unauthorizedTable = tester.widget<MasterDataTableView<RdTaskRow>>(
      find.byType(MasterDataTableView<RdTaskRow>),
    );
    expect(
      unauthorizedTable.rowMenuBuilder!(unauthorizedTable.items.single)
          .whereType<UtenMenuItem>()
          .single
          .label,
      '打开货品 BOM',
    );
    await tester.tap(find.text('RD-UNIT-1'));
    await tester.pumpAndSettle();
    expect(find.text('标记完成'), findsNothing);
    expect(find.text('核对基本单位'), findsNothing);
  });
}
