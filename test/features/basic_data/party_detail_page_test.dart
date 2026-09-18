// 客户/供应商详情整页测试（2026-09-17 布局改版：Hero+Tab 分区）：
// ① Hero 身份卡/统计行 + 各 Tab 子表渲染 + 联系方式添加走目录仓库；
// ② 客户就地编辑：概览与「销售条款与财务」两张分区表单合并一次提交。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/party_directory_models.dart';
import 'package:uten_imp/features/basic_data/models/reference_method_option.dart';
import 'package:uten_imp/features/basic_data/pages/party_detail_page.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/party_directory_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('客户详情页：Hero 统计行 + Tab 分区渲染子表，添加联系方式走目录仓库', (tester) async {
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

    // Hero 身份卡：名称 + 状态徽章 + 信誉分统计行。
    expect(find.text('中山测试客户'), findsOneWidget);
    expect(find.text('使用'), findsOneWidget);
    expect(find.text('信誉分'), findsOneWidget);
    expect(find.text('95'), findsOneWidget);

    // 概览 Tab（默认）：分区标题与键值瓦片。
    expect(find.text('基本信息'), findsOneWidget);
    expect(find.text('全称'), findsOneWidget);
    expect(find.text('地址与物流'), findsOneWidget);

    // 联系方式 Tab：子表 + 主选标注 + 添加弹窗走目录仓库。
    await tester.tap(find.text('联系方式'));
    await tester.pumpAndSettle();
    expect(find.text('联系方式 (1)'), findsOneWidget);
    expect(find.text('13800000000'), findsOneWidget);
    expect(find.textContaining('手机 · 主选'), findsOneWidget);
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

    // 地址 Tab。
    await tester.tap(find.text('地址'));
    await tester.pumpAndSettle();
    expect(find.text('地址 (1)'), findsOneWidget);
    expect(find.text('广东省中山市火炬开发区'), findsOneWidget);

    // 跟进与行为记录 Tab：内容 + 信誉分变动胶囊。
    await tester.tap(find.text('跟进与行为记录'));
    await tester.pumpAndSettle();
    expect(find.text('逾期未付定金'), findsOneWidget);
    expect(find.text('信誉分 -10'), findsOneWidget);
  });

  testWidgets('客户详情页就地编辑：两张分区表单合并一次提交', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = _FakeClientRepository();
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
            Perm.clientStatus,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          clientRepositoryProvider.overrideWithValue(repo),
          clientDirectoryRepositoryProvider.overrideWithValue(
            _FakePartyDirectoryRepository(),
          ),
          referenceMethodRepositoryProvider.overrideWithValue(
            _FakeReferenceMethodRepository(),
          ),
          currencyRepositoryProvider.overrideWithValue(
            _FakeCurrencyRepository(),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: PartyDetailPage(partyType: 'client', id: 'client-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点「编辑」：概览 Tab 原地变输入表单（基础/联系/地址/资质分组）。
    await tester.tap(find.byKey(const Key('party-detail-edit')));
    await tester.pumpAndSettle();
    expect(_labeledField('名称'), findsOneWidget);
    expect(_labeledField('联系人'), findsOneWidget);
    await tester.enterText(_labeledField('联系人'), '李四新');

    // 销售条款与财务 Tab：财务分组表单也在原地；两边各改一个字段，
    // 点「保存」→ 合并成一次 update 提交。
    await tester.tap(find.text('销售条款与财务'));
    await tester.pumpAndSettle();
    expect(_labeledField('开户行'), findsOneWidget);
    await tester.enterText(_labeledField('开户行'), '工商银行中山分行');
    await tester.tap(find.byKey(const Key('party-detail-save')));
    await tester.pumpAndSettle();

    expect(repo.lastUpdateId, 'client-1');
    expect(repo.lastUpdateBody?['linkman'], '李四新');
    expect(repo.lastUpdateBody?['bank'], '工商银行中山分行');
    expect(repo.lastUpdateBody?['name'], '中山测试客户');

    // 保存成功后退出编辑态回展示（当前停在财务 Tab，切回概览看展示态）。
    expect(_labeledField('名称'), findsNothing);
    await tester.tap(find.text('概览'));
    await tester.pumpAndSettle();
    expect(find.text('基本信息'), findsOneWidget);
  });
}

class _FakeClientRepository implements ClientRepository {
  String? lastUpdateId;
  Map<String, dynamic>? lastUpdateBody;

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

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    lastUpdateId = id;
    lastUpdateBody = body;
  }
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

class _FakeReferenceMethodRepository extends ReferenceMethodRepository {
  _FakeReferenceMethodRepository() : super(_EmptyApi());

  @override
  Future<List<ReferenceMethodOption>> settlementMethods() async => const [
    ReferenceMethodOption(id: 'sm-1', code: 'M', name: '月结30'),
  ];
}

class _FakeCurrencyRepository implements CurrencyRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<List<CurrencyListItem>> dict() async => const [
    CurrencyListItem(id: 'cny', name: '人民币', code: 'CNY'),
  ];
}

class _EmptyApi extends ApiClient {
  _EmptyApi() : super(Dio());
}

/// 必填字段的浮动标签是 Text.rich（「名称 *」），widgetWithText 匹配不上；
/// 按标签文本（含富文本）回溯所属 TextField。注意 Hero 元信息行可能含同字样
/// （如「联系人 张三」），但其没有 TextField 祖先，不会污染计数，勿取 .first。
Finder _labeledField(String labelText) => find.ancestor(
  of: find.textContaining(labelText, findRichText: true),
  matching: find.byType(TextField),
);
