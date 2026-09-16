// 客户/供应商详情整页（V579）测试：子表渲染 + 信誉分展示 + 联系方式添加调用。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/party_directory_models.dart';
import 'package:uten_imp/features/basic_data/pages/party_detail_page.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/party_directory_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('客户详情页渲染子表与信誉分，添加联系方式走目录仓库', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final directory = _FakePartyDirectoryRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(
            await SharedPreferences.getInstance(),
          ),
          apiClientProvider.overrideWithValue(_EmptyApi()),
          currentPermissionsProvider.overrideWithValue({
            Perm.clientView,
            Perm.clientEdit,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          clientRepositoryProvider.overrideWithValue(_FakeClientRepository()),
          clientDirectoryRepositoryProvider.overrideWithValue(directory),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PartyDetailPage(partyType: 'client', id: 'client-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 基本信息响应式网格 + 子表分区标题。
    expect(find.text('基本信息'), findsOneWidget);
    expect(find.text('联系方式(1)'), findsOneWidget);
    // 手机既出现在基本信息（平铺列）也出现在联系方式子表。
    expect(find.text('13800000000'), findsWidgets);
    expect(find.textContaining('手机 · 主选'), findsOneWidget);
    expect(find.text('地址(1)'), findsOneWidget);
    expect(find.text('跟进与行为记录(1)', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('信誉分：95'), findsOneWidget);
    expect(find.text('逾期未付定金', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('信誉分-10', skipOffstage: false), findsOneWidget);

    // 添加联系方式：弹窗选类型 + 填内容 → 保存调用仓库。
    await tester.tap(find.text('添加联系方式'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '内容(必填)').first,
      '0760-8888888',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(directory.addedContacts, hasLength(1));
    expect(directory.addedContacts.single.value, '0760-8888888');
  });
}

class _FakeClientRepository implements ClientRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<ClientDetail> detail(String id) async => ClientDetail(
    id: id,
    name: '中山测试客户',
    code: 'C-001',
    status: '使用',
    linkman: '张三',
    mobile: '13800000000',
    ownerEmployeeName: '李销售',
    salesPaymentType: ClientSalesPaymentType.monthly,
    writable: true,
  );
}

class _FakePartyDirectoryRepository implements PartyDirectoryRepository {
  final addedContacts = <({String kind, String value})>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<List<PartyContactMethod>> contactMethods(String partyId) async =>
      const [
        PartyContactMethod(
          id: 'cm-1',
          kind: 'MOBILE',
          value: '13800000000',
          primary: true,
        ),
      ];

  @override
  Future<List<PartyAddress>> addresses(String partyId) async => const [
    PartyAddress(
      id: 'addr-1',
      kind: 'SHIPPING',
      address: '广东省中山市火炬开发区',
      defaultAddress: true,
    ),
  ];

  @override
  Future<List<PartyActivityRecord>> activityRecords(String partyId) async =>
      const [
        PartyActivityRecord(
          id: 'act-1',
          kind: 'PENALTY',
          content: '逾期未付定金',
          scoreDelta: -10,
          createdAt: '2026-09-14T10:00:00+08:00',
        ),
      ];

  @override
  Future<int?> creditScore(String partyId) async => 95;

  @override
  Future<void> addContactMethod(
    String partyId, {
    required String kind,
    required String value,
    bool primary = false,
    String? remark,
  }) async {
    addedContacts.add((kind: kind, value: value));
  }
}

class _EmptyApi extends ApiClient {
  _EmptyApi() : super(Dio());
}
