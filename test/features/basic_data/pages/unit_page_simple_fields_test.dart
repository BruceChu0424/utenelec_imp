import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/pages/unit_page.dart';
import 'package:uten_imp/features/basic_data/repositories/unit_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

const _weightUnit = UnitDetail(
  id: 'u-kg',
  code: 'DW000017',
  name: 'kg',
  status: '使用',
  measurementDimension: 'MASS',
  massUnitCode: 'KG',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('模型保留内部换算规则供既有业务读取', () {
    final detail = UnitDetail.fromJson({
      'id': 'u-kg',
      'measurementDimension': 'MASS',
      'massUnitCode': 'KG',
    });
    expect(detail.measurementDimension, 'MASS');
    expect(detail.massUnitCode, 'KG');
  });
  testWidgets('日常单位表格仅显示名称编号状态', (tester) async {
    await _pumpPage(tester, _FakeUnitRepository(detailPayload: _weightUnit));
    final table = tester.widget<MasterDataTableView<UnitListItem>>(
      find.byType(MasterDataTableView<UnitListItem>),
    );
    expect(table.columns.map((column) => column.key).toSet(), {
      'name',
      'code',
      'status',
    });
    expect(find.text('重量单位'), findsNothing);
    expect(find.text('计量维度'), findsNothing);
  });
  testWidgets('单位详情和编辑不显示计量设置，普通保存不提交或清空内部规则', (tester) async {
    final units = _FakeUnitRepository(detailPayload: _weightUnit);
    await _pumpPage(tester, units);
    await _openDetail(tester);
    expect(find.text('计量维度'), findsNothing);
    expect(find.text('等于哪种重量单位'), findsNothing);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final field = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller?.text == 'kg',
    );
    await tester.enterText(field, '公斤');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(units.lastUpdateBody?['name'], '公斤');
    expect(units.lastUpdateBody, isNot(contains('measurementDimension')));
    expect(units.lastUpdateBody, isNot(contains('massUnitCode')));
    expect(tester.takeException(), isNull);
  });
  testWidgets('表格编辑同样只允许日常字段，不提供技术分类编辑入口', (tester) async {
    await _pumpPage(tester, _FakeUnitRepository(detailPayload: _weightUnit));
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('inline-activate-u-kg-measurementDimension')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('inline-activate-u-kg-massUnitCode')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('inline-activate-u-kg-name')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

/// 点列表行 → 详情面板。
Future<void> _openDetail(WidgetTester tester) async {
  final table = tester.widget<MasterDataTableView<UnitListItem>>(
    find.byWidgetPredicate(
      (widget) => widget is MasterDataTableView<UnitListItem>,
    ),
  );
  table.onRowTap!(table.items.single);
  await tester.pumpAndSettle();
}

Future<void> _pumpPage(WidgetTester tester, _FakeUnitRepository units) async {
  await tester.binding.setSurfaceSize(const Size(1440, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final preferences = await SharedPreferences.getInstance();
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: request,
              statusCode: 200,
              data: {'available': true},
            ),
          );
        },
      ),
    );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'unit-fields-test'),
        ),
        apiClientProvider.overrideWithValue(ApiClient(dio)),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
        unitRepositoryProvider.overrideWithValue(units),
        currentPermissionsProvider.overrideWithValue(<String>{
          Perm.unitView,
          Perm.unitEdit,
          Perm.unitStatus,
        }),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        home: UnitPage(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeUnitRepository implements UnitRepository {
  _FakeUnitRepository({required this.detailPayload});

  final UnitDetail detailPayload;
  String? lastUpdateId;
  Map<String, dynamic>? lastUpdateBody;

  @override
  Future<PagedResult<UnitListItem>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    Map<String, String?> filters = const {},
  }) async => PagedResult(
    items: [
      UnitListItem(
        id: detailPayload.id,
        code: detailPayload.code,
        name: detailPayload.name,
        status: detailPayload.status,
        measurementDimension: detailPayload.measurementDimension,
        massUnitCode: detailPayload.massUnitCode,
      ),
    ],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<UnitFacets> facets() async =>
      const UnitFacets(fields: {}, nullCounts: {});

  @override
  Future<UnitDetail> detail(String id) async => detailPayload;

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    lastUpdateId = id;
    lastUpdateBody = Map<String, dynamic>.of(body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
