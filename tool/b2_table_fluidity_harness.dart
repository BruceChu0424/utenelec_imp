// Actual shared ERP pane, editors and lifecycle guards, with isolated synthetic
// records. No business transport or credential store is used by this target.
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'b1_harness/interaction_collector.dart';
import 'b2_table_fluidity_post_web.dart';

const _build = String.fromEnvironment(
  'B1_HARNESS_BUILD_ID',
  defaultValue: 'b2-20261026',
);
typedef _Row = ({String id, String name, String quantity, int version});

class _Actor extends Notifier<AuthenticatedScope> {
  @override
  AuthenticatedScope build() => const AuthenticatedScope(userId: 'synthetic-A');
  void switchActor() => state = AuthenticatedScope(
    userId: state.userId.endsWith('A') ? 'synthetic-B' : 'synthetic-A',
    epoch: state.epoch + 1,
  );
}

final _actor = NotifierProvider<_Actor, AuthenticatedScope>(_Actor.new);

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _NoNetworkApi extends ApiClient {
  _NoNetworkApi()
    : super(
        Dio(
            BaseOptions(
              baseUrl: Uri.base.resolve('/b1-synthetic-api').toString(),
            ),
          )
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (request, handler) => handler.reject(
                DioException(
                  requestOptions: request,
                  type: DioExceptionType.cancel,
                  error: 'Synthetic harness forbids business HTTP',
                ),
              ),
            ),
          ),
      );
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => {};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final api = _NoNetworkApi();
  runApp(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue(
          Uri.base.resolve('/b1-synthetic-api').toString(),
        ),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_actor)),
        currentPermissionsProvider.overrideWithValue({
          'goods:view',
          'goods:edit',
          'goods:create',
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
        home: const _Harness(),
      ),
    ),
  );
}

class _Harness extends ConsumerStatefulWidget {
  const _Harness();
  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  final _events = <Map<String, Object?>>[];
  final _extra = <String, List<_Row>>{};
  final _collector = B1InteractionCollector();
  final _clock = Stopwatch()..start();
  String _scope = 'A', _status = '等待操作';
  bool _delayNext = false, _unknownNext = false;
  Timer? _aba;
  int _serial = 0, _writing = 0;
  void event(String kind, Map<String, Object?> data) {
    if (_events.length >= 500) _events.removeAt(0);
    _events.add({'kind': kind, 'atMs': _clock.elapsedMilliseconds, ...data});
  }

  void changeScope(String scope) {
    if (!mounted) return;
    setState(() => _scope = scope);
    ref.read(readScopeRevisionProvider.notifier).state++;
    event('scope', {
      'scope': scope,
      'revision': ref.read(readScopeRevisionProvider),
    });
  }

  void aba() {
    _aba?.cancel();
    final old = _scope;
    changeScope(old == 'A' ? 'B' : 'A');
    _aba = Timer(const Duration(milliseconds: 250), () => changeScope(old));
  }

  Future<PagedResult<_Row>> read(
    String actor,
    String scope,
    int revision,
    MasterPaneQuery query,
  ) async {
    final delay = _delayNext;
    _delayNext = false;
    event('read-start', {
      'actor': actor,
      'scope': scope,
      'revision': revision,
      'page': query.page,
      'keywordLength': query.keyword?.length ?? 0,
      'delayed': delay,
    });
    await Future<void>.delayed(Duration(milliseconds: delay ? 3000 : 450));
    final all =
        [
              for (int index = 1; index <= 1000; index++)
                if (scope == 'A' || index.isEven)
                  (
                    id: '$actor-$index',
                    name: '$actor 合成货品 ${index.toString().padLeft(4, '0')}',
                    quantity: '1234567890123456.00000001',
                    version: 1,
                  ),
              ...?_extra[actor],
            ]
            .where(
              (row) =>
                  query.keyword?.isNotEmpty != true ||
                  row.name.contains(query.keyword!),
            )
            .toList();
    final size = (query.size ?? 50).clamp(1, 100);
    final rows = all.skip((query.page - 1) * size).take(size).toList();
    event('read-done', {
      'actor': actor,
      'scope': scope,
      'revision': revision,
      'page': query.page,
      'rows': rows.length,
    });
    return PagedResult(
      items: rows,
      page: query.page,
      size: size,
      total: all.length,
      totalPages: (all.length / size).ceil(),
      readScopeVersion: '$actor-$scope-$revision',
    );
  }

  Future<void> save(String actor, String id, Map<String, dynamic> patch) async {
    event('write-start', {
      'actor': actor,
      'id': id,
      'characters': patch['name']?.toString().length,
    });
    setState(() => _writing++);
    try {
      await Future<void>.delayed(const Duration(seconds: 2));
      event('write-ack', {'actor': actor, 'id': id});
    } finally {
      if (mounted) setState(() => _writing--);
    }
  }

  Future<void> create(
    String actor,
    String key,
    Map<String, dynamic> body,
  ) async {
    final unknown = _unknownNext;
    _unknownNext = false;
    event('create-start', {
      'actor': actor,
      'key': key,
      'unknown': unknown,
      'characters': body['name']?.toString().length,
    });
    setState(() => _writing++);
    try {
      await Future<void>.delayed(const Duration(seconds: 2));
      _extra.putIfAbsent(actor, () => []).add((
        id: '$actor-new-${++_serial}',
        name: body['name'] as String,
        quantity: '0.00000001',
        version: 1,
      ));
      event(unknown ? 'create-unknown' : 'create-ack', {
        'actor': actor,
        'key': key,
      });
      if (unknown) throw NetworkTimeoutException();
    } finally {
      if (mounted) setState(() => _writing--);
    }
  }

  Future<void> evidence() async {
    final result = <String, Object?>{
      'kind': 'b2-table-fluidity-real-master-pane-profile',
      'build': _build,
      'actor': ref.read(_actor).userId,
      'scope': _scope,
      'revision': ref.read(readScopeRevisionProvider),
      'events': List.of(_events),
      'interaction': _collector.snapshot(),
    };
    try {
      await postB2HarnessEvidence(result);
      if (mounted) setState(() => _status = '本地验证记录已保存');
    } catch (_) {
      if (mounted) setState(() => _status = '记录保存失败，请保留当前页面');
    }
  }

  @override
  void initState() {
    super.initState();
    _collector.start();
  }

  @override
  void dispose() {
    _aba?.cancel();
    _collector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final actor = ref.watch(_actor);
    final revision = ref.watch(readScopeRevisionProvider);
    final scope = _scope;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('表格连续浏览验证 · $_build'),
                  Text(
                    '${actor.userId} / 范围$scope / 版本$revision / 等待写入$_writing',
                  ),
                  OutlinedButton(
                    onPressed: () => changeScope(_scope == 'A' ? 'B' : 'A'),
                    child: const Text('切换可见范围'),
                  ),
                  OutlinedButton(onPressed: aba, child: const Text('范围 A→B→A')),
                  OutlinedButton(
                    onPressed: () {
                      setState(() => _delayNext = true);
                      changeScope(_scope);
                    },
                    child: const Text('启动延迟读取'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      ref.read(_actor.notifier).switchActor();
                      event('actor', {'actor': ref.read(_actor).userId});
                    },
                    child: const Text('切换合成账号'),
                  ),
                  OutlinedButton(
                    onPressed: () => setState(() => _unknownNext = true),
                    child: Text(_unknownNext ? '下次新增将超时' : '模拟新增未知提交'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      _collector.stop();
                      _collector.start();
                      setState(() => _status = '采样已重置');
                    },
                    child: const Text('重置采样'),
                  ),
                  OutlinedButton(
                    onPressed: evidence,
                    child: const Text('保存验证记录'),
                  ),
                  Text(_status),
                ],
              ),
            ),
            Expanded(
              child: MasterEntityDetailPane<_Row, _Row>(
                categoryId: 'synthetic-category',
                externalKeyword: null,
                config: MasterEntityPaneConfig(
                  noun: '合成货品',
                  icon: Icons.inventory_2_outlined,
                  defaultCodePrefix: 'B1',
                  columns: [
                    MasterColumnDef(
                      key: 'name',
                      label: '名称',
                      width: 320,
                      value: (row) => row.name,
                    ),
                    MasterColumnDef(
                      key: 'quantity',
                      label: '原始精确数量',
                      width: 320,
                      value: (row) => row.quantity,
                    ),
                  ],
                  idOf: (row) => row.id,
                  labelOf: (row) => row.name,
                  statusOf: (_) => '使用',
                  versionOf: (row) => row.version,
                  loadCategory: (id) async => ProductCategoryDetail(
                    id: id,
                    code: 'B1',
                    name: '隔离合成记录',
                    level: 0,
                    path: '隔离合成记录',
                    childCount: 0,
                  ),
                  loadPage: (query) =>
                      read(actor.userId, scope, revision, query),
                  loadFacets: (_) async =>
                      const MasterPaneFacets(fields: {}, nullCounts: {}),
                  batchEntityPath: '/master/goods',
                  statusResourceOf: (id) => '/master/goods/$id',
                  onOpen: (_, row) => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: Text(row.name)),
                        body: MasterDataTableView<_Row>(
                          virtualized: true,
                          expensiveRowMounts: false,
                          rowKeyOf: (item) => item.id,
                          columns: [
                            MasterColumnDef<_Row>(
                              key: 'name',
                              label: '详情明细',
                              width: 320,
                              value: (item) => item.name,
                            ),
                          ],
                          items: List.generate(
                            1000,
                            (i) => (
                              id: 'detail-$i',
                              name: '${row.name} 明细 $i',
                              quantity: row.quantity,
                              version: 1,
                            ),
                          ),
                          facets: const {},
                          nullCounts: const {},
                          filters: const {},
                          onFilterChanged: (_, _) {},
                        ),
                      ),
                    ),
                  ),
                  canCreate: true,
                  canEdit: true,
                  canDelete: false,
                  canStatus: false,
                  inlineFields: {
                    'name': MasterInlineField(
                      key: 'name',
                      read: (row) => row.name,
                    ),
                  },
                  onInlineSave: (id, patch, original) =>
                      save(actor.userId, id, patch),
                  inlineCreation: (_) => MasterInlineCreateConfig(
                    namespace: actor.userId,
                    fields: const [
                      MasterFieldDef(key: 'name', label: '名称', required: true),
                    ],
                    canCreate: true,
                    onCreate: (key, body) => create(actor.userId, key, body),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
