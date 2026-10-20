import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/payables/models/finance_payable.dart';
import 'package:uten_imp/features/finance/payables/pages/finance_payables_page.dart';
import 'package:uten_imp/features/finance/payables/widgets/subcontract_loss_claim_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/filter_segment_tap.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <({String path, Map<String, dynamic> query})>[];
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add((path: path, query: Map.of(query ?? const {})));
    if (path.endsWith('/facets')) return const {};
    return const {
      'items': <Object?>[],
      'page': 1,
      'size': 30,
      'total': 0,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}

Future<void> _mount(
  WidgetTester tester,
  _Api api,
  Set<String> permissions, {
  Widget child = const FinancePayablesPage(),
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        settlementMethodOptionsProvider.overrideWith((_) async => const []),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(home: child),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final scenario in [
    (
      name: '应付台账',
      path: '/finance/payables',
      permissions: {Perm.arApLedgerView, Perm.financeViewAll},
      status: null,
    ),
    (
      name: '委外超耗责任',
      path: '/finance/subcontract-loss-claims',
      permissions: {Perm.subcontractLossClaimView},
      status: 'OPEN',
    ),
    (
      name: '月结批次',
      path: '/finance/supplier-settlements',
      permissions: {Perm.supplierSettlementView},
      status: 'FROZEN',
    ),
  ]) {
    testWidgets('${scenario.name}页面顶栏刷新一次并保留当前筛选', (tester) async {
      final api = _Api();
      await _mount(tester, api, scenario.permissions);
      await tester.enterText(
        find.descendant(
          of: find.byType(UtenSearchBar).first,
          matching: find.byType(TextField),
        ),
        'KEEP-WORKSPACE',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      if (scenario.status != null) {
        await selectFilterSegment(
          tester,
          scenario.status == 'OPEN' ? '待处理' : '已冻结',
        );
        await tester.pumpAndSettle();
      } else {
        final table = tester.widget<MasterDataTableView<FinancePayableItem>>(
          find.byType(MasterDataTableView<FinancePayableItem>),
        );
        table.onFilterChanged('businessType', 'PURCHASE');
        await tester.pumpAndSettle();
      }
      final refresh = find.byTooltip('刷新');
      expect(refresh, findsOneWidget, reason: '宿主页只保留一个页面刷新');
      expect(
        find.ancestor(of: refresh, matching: find.byType(UtenAppBar)),
        findsOneWidget,
      );
      final before = api.reads
          .where((read) => read.path == scenario.path)
          .length;
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      final reads = api.reads
          .where((read) => read.path == scenario.path)
          .toList();
      expect(reads.length, before + 1);
      expect(reads.last.query['keyword'], 'KEEP-WORKSPACE');
      if (scenario.status != null) {
        expect(reads.last.query['status'], scenario.status);
        expect(
          api.reads.where((read) => read.path == '/finance/payables'),
          isEmpty,
        );
      } else {
        expect(reads.last.query['businessType'], 'PURCHASE');
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('无可见工作区不暴露刷新或读取业务列表', (tester) async {
    final api = _Api();
    await _mount(tester, api, {});
    expect(find.byTooltip('刷新'), findsNothing);
    expect(
      api.reads.where(
        (read) => {
          '/finance/payables',
          '/finance/subcontract-loss-claims',
          '/finance/supplier-settlements',
        }.contains(read.path),
      ),
      isEmpty,
    );
  });
  testWidgets('独立超耗panel仍保留其默认局部刷新', (tester) async {
    final api = _Api();
    await _mount(tester, api, {
      Perm.subcontractLossClaimView,
    }, child: const Scaffold(body: SubcontractLossClaimPanel()));
    final before = api.reads
        .where((read) => read.path == '/finance/subcontract-loss-claims')
        .length;
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(
      api.reads
          .where((read) => read.path == '/finance/subcontract-loss-claims')
          .length,
      before + 1,
    );
  });
}
