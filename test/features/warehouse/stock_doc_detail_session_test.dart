import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_detail_page.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/document_scope_fixture.dart';
import 'outbound_weight_fakes.dart';

class _Api extends ApiClient {
  _Api([String endpoint = 'https://stock-detail.invalid/api'])
    : super(Dio(BaseOptions(baseUrl: endpoint)));

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {'links': <Map<String, dynamic>>[]};
}

class _Names extends MasterNameService {
  _Names() : super(_Api());

  @override
  Future<void> ensureLoaded() async {}
  @override
  Future<void> loadGoodsDetails(Iterable<String> ids) async {}
  @override
  String goods(String? id) => '功能件';
  @override
  String unit(String? id) => '件';
  @override
  String warehouse(String? id) => '正常仓';
  @override
  List<WarehouseDictEntry> get warehouseHierarchy => const [
    WarehouseDictEntry(id: 'main', name: '主仓', isAccountable: false),
    WarehouseDictEntry(
      id: 'leaf',
      name: '正常仓',
      parentId: 'main',
      selectableForNew: true,
    ),
  ];
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

const _all = {
  Perm.stockDocView,
  Perm.stockDocApprove,
  Perm.stockDocIssue,
  Perm.stockDocReverseIssue,
  Perm.stockDocReverse,
  Perm.stockDocDelete,
};
final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'me'),
);
final _permissions = StateProvider<Set<String>>((_) => _all);
final _client = StateProvider<ApiClient>((_) => _Api());
final _documentId = StateProvider<String>((_) => 'doc');

class _Repo extends StockDocRepository {
  _Repo(StockDocType type, {this.status = 0, this.linked = false})
    : super(_Api(), type);

  final int status;
  final bool linked;
  int reads = 0;
  final commands = <String>[];
  Completer<StockDocDetail>? pendingRead;
  Completer<StockDocDetail>? pendingCommand;

  StockDocDetail get document => StockDocDetail(
    id: 'doc',
    docType: type.code,
    billNo: 'SENSITIVE-DOC',
    status: status,
    makerId: 'me',
    warehouseId: 'leaf',
    productionLinked: linked,
    productionMaterialReturn: linked && type == StockDocType.wdraw,
    materialReturnMainWarehouseId: 'main',
    canDelete: true,
    items: [
      StockDocItem(
        id: 'line',
        goodsId: 'goods',
        unitId: 'unit',
        qty: 5,
        qtyText: '5',
        issuedQty: type == StockDocType.draw && status == 1 ? 2 : 0,
        issuedQtyText: type == StockDocType.draw && status == 1 ? '2' : '0',
        unitRate: 1,
      ),
    ],
    finishedLots: type == StockDocType.finishedIn
        ? const [
            FinishedInLot(
              lotId: 'lot',
              itemIds: ['line'],
              qty: 5,
              goodsId: 'goods',
              unitId: 'unit',
            ),
          ]
        : const [],
  );

  @override
  Future<StockDocDetail> detail(String id) async {
    reads++;
    if (pendingRead case final pending?) return pending.future;
    return document;
  }

  @override
  Future<StockDocOutboundReview> review(String id) async =>
      StockDocOutboundReview(
        document: await detail(id),
        reviewToken: 'original-review',
      );

  Future<StockDocDetail> _send(String action) async {
    commands.add(action);
    if (pendingCommand case final pending?) return pending.future;
    return document;
  }

  @override
  Future<StockDocDetail> approveReviewed(
    String id, {
    required String expectedReviewToken,
    List<String>? itemIds,
  }) => _send('review:$expectedReviewToken');

  @override
  Future<StockDocDetail> approve(String id) => _send('approve');

  @override
  Future<void> delete(String id) async {
    await _send('delete');
  }

  @override
  Future<StockDocDetail> reverseFinishedInbound(String id) =>
      _send('finished-reverse');

  @override
  Future<StockDocDetail> reverseMaterialReturn(String id) =>
      _send('return-reverse');

  @override
  Future<StockDocDetail> confirmMaterialReturn(
    String id, {
    required String warehouseId,
    required String idempotencyKey,
    List<Map<String, dynamic>> lines = const [],
    List<String>? itemIds,
  }) => _send('return');

  @override
  Future<StockDocDetail> confirmFinishedInbound(
    String id,
    List<Map<String, dynamic>> lots,
    String idempotencyKey, {
    String? varianceReason,
  }) => _send('finished');

  @override
  Future<StockDocDetail> approveAndIssue(
    String id,
    List<Map<String, dynamic>> lines,
    String idempotencyKey, {
    String? remark,
  }) => _send('approve-issue');

  @override
  Future<StockDocDetail> issue(
    String id,
    List<Map<String, dynamic>> lines,
    String idempotencyKey, {
    String? remark,
  }) => _send('issue');

  @override
  Future<StockDocDetail> reverseIssue(
    String id,
    List<Map<String, dynamic>> lines,
    String idempotencyKey,
    String reason,
  ) => _send('reverse-issue');
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Repo repo, {
  AuthenticatedScope? identity = const AuthenticatedScope(userId: 'me'),
  Set<String> permissions = _all,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        _identity.overrideWith((_) => identity),
        _permissions.overrideWith((_) => permissions),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_permissions),
        ),
        apiClientProvider.overrideWith((ref) => ref.watch(_client)),
        sessionProvider.overrideWith(_Session.new),
        sharedPreferencesProvider.overrideWithValue(prefs),
        isSuperAdminProvider.overrideWithValue(false),
        masterNameServiceProvider.overrideWithValue(_Names()),
        stockDocRepositoryProvider(repo.type).overrideWithValue(repo),
        documentScopeOverride(owners: const {'me'}),
        businessAttachmentsProvider.overrideWith(
          (ref, owner) async => const <Attachment>[],
        ),
        fakeWeightRepositoryOverride(FakeWeightRepository()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (context, child) => Stack(
          children: [
            child!,
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppNotificationHost(useSafeArea: false),
            ),
          ],
        ),
        home: Consumer(
          builder: (context, ref, child) => StockDocDetailPage(
            docType: repo.type,
            id: ref.watch(_documentId),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(tester.takeException(), isNull);
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

Future<void> _open(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(UtenButton, label).last);
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
}

Future<void> _confirm(WidgetTester tester, String label) async {
  await tester.tap(
    find
        .descendant(of: find.byType(AlertDialog), matching: find.text(label))
        .last,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('anonymous detail never reads stock or offers commands', (
    tester,
  ) async {
    final repo = _Repo(StockDocType.otherOut);
    await _pump(tester, repo, identity: null);
    expect(repo.reads, 0);
    expect(repo.commands, isEmpty);
    expect(find.text('SENSITIVE-DOC'), findsNothing);
  });

  testWidgets('initial read-only identity may read but cannot approve', (
    tester,
  ) async {
    final repo = _Repo(StockDocType.otherOut);
    await _pump(
      tester,
      repo,
      identity: const AuthenticatedScope(userId: 'me', readOnly: true),
    );
    expect(repo.reads, 1);
    expect(find.widgetWithText(UtenButton, '确认出库'), findsNothing);
    expect(repo.commands, isEmpty);
  });

  testWidgets(
    'initial identity without view authority never reads the source',
    (tester) async {
      final repo = _Repo(StockDocType.otherOut);
      await _pump(tester, repo, permissions: const {Perm.stockDocApprove});
      expect(repo.reads, 0);
      expect(repo.commands, isEmpty);
      expect(find.text('SENSITIVE-DOC'), findsNothing);
    },
  );

  for (final change in ['identity', 'permission', 'readOnly', 'endpoint']) {
    testWidgets('$change during outbound review dialog invalidates its token', (
      tester,
    ) async {
      final repo = _Repo(StockDocType.otherOut);
      final container = await _pump(tester, repo);
      await _open(tester, '确认出库');
      switch (change) {
        case 'identity':
          container.read(_identity.notifier).state = const AuthenticatedScope(
            userId: 'other',
          );
        case 'permission':
          container.read(_permissions.notifier).state = {Perm.stockDocView};
        case 'readOnly':
          container.read(_identity.notifier).state = const AuthenticatedScope(
            userId: 'me',
            readOnly: true,
          );
        case 'endpoint':
          container.read(_client.notifier).state = _Api(
            'https://other-stock.invalid/api',
          );
      }
      await tester.pump();
      await _confirm(tester, '确认出库');
      expect(repo.commands, isEmpty);
      expect(find.text('SENSITIVE-DOC'), findsNothing);
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'me',
      );
      container.read(_permissions.notifier).state = _all;
      await tester.pumpAndSettle();
      expect(find.text('SENSITIVE-DOC'), findsNothing);
      expect(repo.reads, 1);
      expect(tester.takeException(), isNull);
    });
  }

  for (final type in [StockDocType.otherIn, StockDocType.otherOut]) {
    testWidgets('${type.code} late initial GET cannot revive an invalid page', (
      tester,
    ) async {
      final pending = Completer<StockDocDetail>();
      final repo = _Repo(type)..pendingRead = pending;
      final container = await _pump(tester, repo, settle: false);
      expect(repo.reads, 1);
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'other',
      );
      await tester.pump();
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'me',
      );
      await tester.pump();
      pending.complete(repo.document);
      await tester.pumpAndSettle();
      expect(find.text('SENSITIVE-DOC'), findsNothing);
      expect(repo.commands, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'source document ABA cannot reuse an earlier review or page state',
    (tester) async {
      final repo = _Repo(StockDocType.otherOut);
      final container = await _pump(tester, repo);
      await _open(tester, '确认出库');
      container.read(_documentId.notifier).state = 'other-document';
      await tester.pump();
      container.read(_documentId.notifier).state = 'doc';
      await tester.pump();
      await _confirm(tester, '确认出库');
      expect(repo.commands, isEmpty);
      expect(repo.reads, 1);
      expect(find.text('SENSITIVE-DOC'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  final actions = [
    (
      type: StockDocType.otherIn,
      status: 0,
      linked: false,
      label: '审核',
      confirm: '确认审核',
    ),
    (
      type: StockDocType.otherIn,
      status: 0,
      linked: false,
      label: '删除',
      confirm: '删除',
    ),
    (
      type: StockDocType.wdraw,
      status: 0,
      linked: true,
      label: '确认实收并入库',
      confirm: '确认收料',
    ),
    (
      type: StockDocType.wdraw,
      status: 1,
      linked: true,
      label: '撤回收仓',
      confirm: '撤回收仓',
    ),
    (
      type: StockDocType.finishedIn,
      status: 0,
      linked: true,
      label: '确认实收并入库',
      confirm: '确认实收并入库',
    ),
    (
      type: StockDocType.finishedIn,
      status: 1,
      linked: true,
      label: '撤回点收',
      confirm: '确认',
    ),
    (
      type: StockDocType.draw,
      status: 0,
      linked: true,
      label: '出库',
      confirm: '确认出库',
    ),
    (
      type: StockDocType.draw,
      status: 1,
      linked: true,
      label: '出库',
      confirm: '确认出库',
    ),
    (
      type: StockDocType.draw,
      status: 1,
      linked: true,
      label: '取消出库',
      confirm: '确认取消出库',
    ),
  ];
  for (final action in actions) {
    testWidgets(
      '${action.type.code}/${action.status}/${action.label} fences confirmation',
      (tester) async {
        final repo = _Repo(
          action.type,
          status: action.status,
          linked: action.linked,
        );
        final container = await _pump(tester, repo);
        await _open(tester, action.label);
        if (action.label == '取消出库') {
          await tester.enterText(find.byType(TextField).last, '领料退回');
        }
        container.read(_identity.notifier).state = const AuthenticatedScope(
          userId: 'other',
        );
        await tester.pump();
        await _confirm(tester, action.confirm);
        expect(repo.commands, isEmpty);
        expect(find.text('SENSITIVE-DOC'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('late dispatched approval does not show old success or reload', (
    tester,
  ) async {
    final pending = Completer<StockDocDetail>();
    final repo = _Repo(StockDocType.otherOut)..pendingCommand = pending;
    final container = await _pump(tester, repo);
    await _open(tester, '确认出库');
    await tester.tap(
      find
          .descendant(of: find.byType(AlertDialog), matching: find.text('确认出库'))
          .last,
    );
    await tester.pump(const Duration(milliseconds: 10));
    expect(repo.commands, ['review:original-review']);
    container.read(_identity.notifier).state = const AuthenticatedScope(
      userId: 'other',
    );
    await tester.pump();
    pending.complete(repo.document);
    await tester.pumpAndSettle();
    expect(repo.reads, 1);
    expect(find.text('SENSITIVE-DOC'), findsNothing);
    expect(find.textContaining('已出库 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
