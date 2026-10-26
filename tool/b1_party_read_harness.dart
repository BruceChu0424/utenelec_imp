import 'b1_harness/post_evidence.dart';
// Explicit synthetic entry point. Business APIs stay in memory; only evidence
// saving posts to the existing loopback /b0-results collector.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/finance/pages/finance_statement_page.dart';
import 'package:uten_imp/features/finance/payables/widgets/supplier_settlement_actions.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/read_owner_fence.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/master_party_options.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';

import 'b1_harness/interaction_collector.dart';
import 'b1_harness/party_read_fixture.dart';

class _Owner extends Notifier<AuthenticatedScope?> {
  @override
  AuthenticatedScope? build() => const AuthenticatedScope(userId: 'A');
  void choose(String actor) => state = AuthenticatedScope(userId: actor);
}

final _owner = NotifierProvider<_Owner, AuthenticatedScope?>(_Owner.new);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final api = PartyReadFixtureApi();
  runApp(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://synthetic.invalid/api'),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_owner)),
        currentPermissionsProvider.overrideWithValue({
          Perm.clientView,
          Perm.supplierView,
          Perm.financeReportView,
          Perm.financeViewAll,
          Perm.supplierSettlementCreate,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(
          InMemorySharedPreferences(),
        ),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => Consumer(
          builder: (context, ref, _) => CallbackShortcuts(
            bindings: {
              for (final entry in [
                (LogicalKeyboardKey.keyA, 'A'),
                (LogicalKeyboardKey.keyB, 'B'),
              ])
                SingleActivator(entry.$1, alt: true): () {
                  api.actor = entry.$2;
                  api.scope++;
                  api.event('keyboard-actor-change', {
                    'actor': entry.$2,
                    'scope': api.scope,
                  });
                  ref.read(_owner.notifier).choose(entry.$2);
                },
              const SingleActivator(LogicalKeyboardKey.keyR, alt: true): () {
                api.scope++;
                api.event('keyboard-read-scope-change', {'scope': api.scope});
                ref.read(readScopeRevisionProvider.notifier).state++;
              },
            },
            child: child!,
          ),
        ),
        home: _Harness(api),
      ),
    ),
  );
}

class _Harness extends ConsumerStatefulWidget {
  const _Harness(this.api);
  final PartyReadFixtureApi api;
  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  final collector = B1InteractionCollector();
  int tab = 0;
  String status = '纯合成：每域1201条，候选每页100；普通延迟120ms，晚回执2500ms。';
  @override
  void initState() {
    super.initState();
    collector.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _actor(String actor) {
    widget.api.actor = actor;
    widget.api.scope++;
    widget.api.event('actor-change', {
      'actor': actor,
      'scope': widget.api.scope,
    });
    ref.read(_owner.notifier).choose(actor);
  }

  void _scope() {
    widget.api.scope++;
    widget.api.event('read-scope-change', {'scope': widget.api.scope});
    ref.read(readScopeRevisionProvider.notifier).state++;
  }

  Future<void> _save() async {
    collector.stop();
    final evidence = {
      'kind': 'b1-party-read-synthetic-ui',
      'run': Uri.base.queryParameters['run'],
      'build': const String.fromEnvironment(
        'B1_BUILD_ID',
        defaultValue: 'unidentified',
      ),
      'fixtureCandidatesPerDomain': PartyReadFixtureApi.candidateCount,
      'candidatePageSize': 100,
      'ordinaryDelayMs': 120,
      'lateDelayMs': 2500,
      'businessNetwork': false,
      'viewport': {
        'width': MediaQuery.sizeOf(context).width,
        'height': MediaQuery.sizeOf(context).height,
        'dpr': MediaQuery.devicePixelRatioOf(context),
      },
      ...collector.snapshot(),
      'requests': widget.api.requests,
    };
    try {
      await postB1HarnessEvidence(evidence);
      if (mounted) {
        setState(() => status = '证据已保存；请求${widget.api.requests.length}条。');
      }
    } catch (error) {
      if (mounted) setState(() => status = '证据保存失败：$error');
    }
  }

  @override
  void dispose() {
    collector.removeListener(_changed);
    collector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owner = ref.watch(_owner)?.userId,
        epoch = ref.watch(exportContextEpochProvider);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(
                    onPressed: collector.sampling ? null : collector.start,
                    child: const Text('开始采样'),
                  ),
                  FilledButton.tonal(
                    onPressed: collector.sampling ? _save : null,
                    child: const Text('停止并保存证据'),
                  ),
                  for (final entry in [(0, '往来对账'), (1, '远端表头'), (2, '供应商月结')])
                    OutlinedButton(
                      onPressed: () => setState(() => tab = entry.$1),
                      child: Text(entry.$2),
                    ),
                  OutlinedButton(
                    onPressed: () => _actor('A'),
                    child: const Text('身份A'),
                  ),
                  OutlinedButton(
                    onPressed: () => _actor('B'),
                    child: const Text('身份B'),
                  ),
                  OutlinedButton(
                    onPressed: () async {
                      _actor('B');
                      await Future<void>.delayed(
                        const Duration(milliseconds: 80),
                      );
                      if (mounted) _actor('A');
                    },
                    child: const Text('A→B→A'),
                  ),
                  OutlinedButton(
                    onPressed: _scope,
                    child: const Text('读取范围变化'),
                  ),
                  OutlinedButton(
                    onPressed: () => setState(() {
                      widget.api.delayNext = true;
                      status = '下一次读取延迟2.5秒；可在返回前切身份或范围。';
                    }),
                    child: const Text('下一次读取迟到'),
                  ),
                  const SizedBox(
                    width: 220,
                    child: TextField(
                      decoration: InputDecoration(
                        labelText: '加载期间独立输入',
                        isDense: true,
                      ),
                    ),
                  ),
                  Text('身份$owner / epoch $epoch'),
                  const Text('弹窗内：Alt+A/B切身份；Alt+R更改读取范围'),
                  Text(status),
                ],
              ),
            ),
            Expanded(
              child: switch (tab) {
                0 => const FinanceStatementPage(),
                1 => const _FacetPage(),
                _ => const _MonthlyPage(),
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthlyPage extends StatefulWidget {
  const _MonthlyPage();
  @override
  State<_MonthlyPage> createState() => _MonthlyPageState();
}

class _MonthlyPageState extends State<_MonthlyPage> {
  String result = '没有提交业务数据；只返回合成表单选择。';
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: () async {
              final picked = await showSupplierSettlementCreatePanel(
                context: context,
              );
              if (mounted) {
                setState(
                  () => result = picked == null
                      ? '已取消，原页保留。'
                      : 'supplier=${picked.supplierId} / currency=${picked.currencyId} / method=${picked.settlementMethodId} / period=${picked.periodStart}',
                );
              }
            },
            child: const Text('建立合成供应商月结'),
          ),
          const SizedBox(height: 16),
          Text(result),
        ],
      ),
    ),
  );
}

class _FacetPage extends ConsumerStatefulWidget {
  const _FacetPage();
  @override
  ConsumerState<_FacetPage> createState() => _FacetPageState();
}

class _FacetPageState extends ConsumerState<_FacetPage> {
  String? client = PartyReadFixtureApi.restoredId, supplier, statusFilter;
  @override
  void initState() {
    super.initState();
    listenReadOwner(ref, () {
      if (mounted) {
        setState(() {
          client = null;
          supplier = null;
        });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(salesMasterNameServiceProvider).loadClientNames([
        PartyReadFixtureApi.restoredId,
      ]);
    });
  }

  Future<void> _select(String key, String? value) async {
    final current = captureReadOwner(ref);
    if (value != null) {
      if (key == 'client') {
        await ref.read(salesMasterNameServiceProvider).loadClientNames([value]);
      } else if (key == 'supplier') {
        await ref.read(masterNameServiceProvider).loadSupplierNames([value]);
      }
    }
    if (!mounted || !current()) return;
    setState(() {
      if (key == 'client') {
        client = value;
      } else if (key == 'supplier') {
        supplier = value;
      } else {
        statusFilter = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final clients = ref.watch(salesMasterNameServiceProvider),
        suppliers = ref.watch(masterNameServiceProvider);
    return MasterDataTableView<int>(
      primary: true,
      tableKey: 'b1.harness.party-candidates',
      columns: [
        MasterColumnDef(
          key: 'client',
          label: '客户',
          width: 260,
          value: (row) => '实际业务客户$row',
        ),
        MasterColumnDef(
          key: 'supplier',
          label: '供应商',
          width: 260,
          value: (row) => '实际业务供应商$row',
        ),
        MasterColumnDef(
          key: 'status',
          label: '状态',
          width: 160,
          value: (_) => '已审',
        ),
        MasterColumnDef(
          key: 'fact',
          label: '原始来源',
          width: 480,
          value: (row) => '合成来源$row；共享表头远端候选独立于当前行/引用缓存',
        ),
      ],
      items: List.generate(200, (index) => index + 1),
      facets: {
        'client': selectedPartyFacet(client, (id) => clients.client(id)),
        'supplier': selectedPartyFacet(
          supplier,
          (id) => suppliers.supplier(id),
        ),
        'status': const [MasterFacetBucket(value: '已审', count: 200)],
      },
      nullCounts: const {},
      filters: {'client': client, 'supplier': supplier, 'status': statusFilter},
      facetPageLoaders: {
        'client': clientPartyFacetLoader(ref),
        'supplier': supplierPartyFacetLoader(ref),
      },
      facetSearchScope: partyFacetSearchScope(ref, 'party-browser-harness'),
      onFilterChanged: _select,
      summaryBar: Text(
        '当前客户UUID=${client ?? '(无)'}；供应商UUID=${supplier ?? '(无)'}',
      ),
    );
  }
}
