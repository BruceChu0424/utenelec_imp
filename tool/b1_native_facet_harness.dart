import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import 'package:uten_imp/shared/providers/native_facet_options.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'b1_harness/interaction_collector.dart';
import 'b1_harness/post_evidence.dart';

class _Owner extends Notifier<AuthenticatedScope?> {
  @override
  AuthenticatedScope? build() => const AuthenticatedScope(userId: 'A');
  void choose(String value) => state = AuthenticatedScope(userId: value);
}

final _owner = NotifierProvider<_Owner, AuthenticatedScope?>(_Owner.new);

class _Api extends ApiClient {
  _Api()
    : super(
        Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) => handler.reject(
                DioException(
                  requestOptions: options,
                  error: 'Synthetic native fixture forbids business transport',
                ),
              ),
            ),
          ),
      );
  String actor = 'A';
  int scope = 1;
  bool delayNext = false;
  final requests = <Map<String, Object?>>[];
  @override
  Future<Map<String, dynamic>> postForm(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final reader = actor, version = scope, delay = delayNext;
    delayNext = false;
    requests.add({
      'action': 'candidate-start',
      'path': path,
      'body': Map<String, dynamic>.of(body),
      'actor': reader,
      'scope': version,
      'delayed': delay,
    });
    await Future<void>.delayed(Duration(milliseconds: delay ? 2500 : 120));
    final keyword = body['__facetKeyword'].toString().toLowerCase();
    final page = body['__facetPage'] as int, size = body['__facetSize'] as int;
    final values = [
      for (var n = 1; n <= 1201; n++)
        '$reader-单号-${n.toString().padLeft(4, '0')}',
    ].where((value) => value.toLowerCase().contains(keyword)).toList();
    final items = [
      for (final value in values.skip((page - 1) * size).take(size))
        {
          'value': value,
          'label': value,
          'count': value.endsWith('1201') ? 7 : 1,
        },
    ];
    requests.add({
      'action': 'candidate-return',
      'actor': reader,
      'scope': version,
      'rows': items.length,
      'page': page,
    });
    return {
      'field': body['__facetField'],
      'page': page,
      'size': size,
      'items': items,
      'hasMore': page * size < values.length,
      'readScopeVersion': '$reader-$version',
    };
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  runApp(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue(
          'https://native-synthetic.invalid/api',
        ),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_owner)),
        currentPermissionsProvider.overrideWithValue(const <String>{}),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => Consumer(
          builder: (context, ref, _) => CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyA, alt: true): () =>
                  _choose(api, ref, 'A'),
              const SingleActivator(LogicalKeyboardKey.keyB, alt: true): () =>
                  _choose(api, ref, 'B'),
              const SingleActivator(LogicalKeyboardKey.keyR, alt: true): () =>
                  _scope(api, ref),
            },
            child: child!,
          ),
        ),
        home: _Page(api),
      ),
    ),
  );
}

void _choose(_Api api, WidgetRef ref, String actor) {
  api.actor = actor;
  api.scope++;
  api.requests.add({
    'action': 'actor-change',
    'actor': actor,
    'scope': api.scope,
  });
  ref.read(_owner.notifier).choose(actor);
}

void _scope(_Api api, WidgetRef ref) {
  api.scope++;
  api.requests.add({'action': 'scope-change', 'scope': api.scope});
  ref.read(readScopeRevisionProvider.notifier).state++;
}

class _Page extends ConsumerStatefulWidget {
  const _Page(this.api);
  final _Api api;
  @override
  ConsumerState<_Page> createState() => _PageState();
}

class _PageState extends ConsumerState<_Page> {
  final collector = B1InteractionCollector();
  String? selected;
  String route = '/sales/orders/progress/facets';
  String stateFilter = 'CURRENT';
  String note = '1201条合成候选，每页100；当前表只显示3条。';
  void actor(String value) => _choose(widget.api, ref, value);

  Future<void> save() async {
    collector.stop();
    await postB1HarnessEvidence({
      'kind': 'b1-native-facet-synthetic-ui',
      'run': Uri.base.queryParameters['run'],
      'build': const String.fromEnvironment(
        'B1_BUILD_ID',
        defaultValue: 'unidentified',
      ),
      'businessNetwork': false,
      'candidateCount': 1201,
      'pageSize': 100,
      'selected': selected,
      'requests': widget.api.requests,
      ...collector.snapshot(),
    });
    if (mounted) setState(() => note = '已保存${widget.api.requests.length}条请求证据');
  }

  @override
  void dispose() {
    collector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owner = ref.watch(_owner)?.userId,
        epoch = ref.watch(exportContextEpochProvider);
    final field = route.contains('/payables/')
        ? 'sourceDocNo'
        : route.contains('loss-claims')
        ? 'wasteBillNo'
        : route.contains('short-deliveries') || route.contains('/schedule/')
        ? 'orderBillNo'
        : route.contains('/inspection/') ||
              route.contains('quality-inspections')
        ? 'sourceNo'
        : route.contains('production-finished-in')
        ? 'taskNo'
        : route.contains('material-analyses')
        ? 'orderNo'
        : route.contains('execution-workbench')
        ? 'orders'
        : route.contains('workshop-tasks')
        ? 'sourcePlan'
        : route.contains('overproduction-rate')
        ? 'plan'
        : 'billNo';
    final filters = <String, dynamic>{'keyword': '', 'status': stateFilter};
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
                    onPressed: () {
                      collector.start();
                      setState(() => note = '采样中');
                    },
                    child: const Text('开始采样'),
                  ),
                  FilledButton.tonal(
                    onPressed: save,
                    child: const Text('停止并保存证据'),
                  ),
                  OutlinedButton(
                    onPressed: () => actor('A'),
                    child: const Text('身份A'),
                  ),
                  OutlinedButton(
                    onPressed: () => actor('B'),
                    child: const Text('身份B'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      widget.api.delayNext = true;
                      setState(() => note = '下一请求迟到2.5秒；弹窗内Alt+A/B/R切身份/范围');
                    },
                    child: const Text('下一次迟到'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      widget.api.scope++;
                      ref.read(readScopeRevisionProvider.notifier).state++;
                    },
                    child: const Text('读取范围变化'),
                  ),
                  OutlinedButton(
                    onPressed: () => setState(
                      () => stateFilter = stateFilter == 'CURRENT'
                          ? 'HISTORY'
                          : 'CURRENT',
                    ),
                    child: Text('过滤:$stateFilter'),
                  ),
                  DropdownButton<String>(
                    value: route,
                    items: [
                      for (final path in nativeFacetPaths)
                        DropdownMenuItem(value: path, child: Text(path)),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => route = value);
                    },
                  ),
                  const SizedBox(
                    width: 200,
                    child: TextField(
                      decoration: InputDecoration(
                        labelText: '加载期间独立输入',
                        isDense: true,
                      ),
                    ),
                  ),
                  Text('身份$owner / epoch$epoch / 选中${selected ?? "无"}'),
                  Text(note),
                ],
              ),
            ),
            Expanded(
              child: MasterDataTableView<String>(
                tableKey: 'b1-native-synthetic',
                columns: [
                  MasterColumnDef(
                    key: field,
                    label: '业务单号',
                    width: 300,
                    value: (row) => row,
                  ),
                ],
                items: const ['当前行-0001', '当前行-0002', '当前行-0003'],
                facets: const {},
                nullCounts: const {},
                filters: {field: selected},
                facetPageLoaders: nativeFacetLoaders(
                  ref,
                  path: route,
                  fields: [field],
                  filters: filters,
                ),
                facetSearchScope: nativeFacetSearchScope(ref, route, filters),
                onFilterChanged: (key, value) =>
                    setState(() => selected = value),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
