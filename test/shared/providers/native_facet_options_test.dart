import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/native_facet_options.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _Owner extends Notifier<AuthenticatedScope?> {
  @override
  AuthenticatedScope? build() => const AuthenticatedScope(userId: 'A');
  void change(String id) => state = AuthenticatedScope(userId: id);
}

final _owner = NotifierProvider<_Owner, AuthenticatedScope?>(_Owner.new);

class _Api extends ApiClient {
  _Api() : super(Dio());
  final requests = <({String path, Map<String, dynamic> body})>[];
  Completer<Map<String, dynamic>>? paused;
  @override
  Future<Map<String, dynamic>> postForm(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    requests.add((path: path, body: {...body}));
    if (paused case final pending?) return pending.future;
    return {
      'field': body['__facetField'],
      'page': body['__facetPage'],
      'size': 100,
      'items': [
        {'value': '0001. %_ 原始单号 中文', 'count': 7, 'label': '原始单号'},
      ],
      'hasMore': body['__facetPage'] == 1,
      'readScopeVersion': 'current-proof',
    };
  }
}

Future<(WidgetRef, ProviderContainer)> _mount(
  WidgetTester tester,
  _Api api,
) async {
  late WidgetRef pageRef;
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue('https://native.invalid/api'),
      currentPermissionsProvider.overrideWithValue(const <String>{}),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_owner)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            pageRef = ref;
            ref.watch(exportContextEpochProvider);
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    ),
  );
  return (pageRef, container);
}

void main() {
  testWidgets(
    'all 21 routes use body-only bounded literal candidate reads with original filters',
    (tester) async {
      final api = _Api();
      final (ref, _) = await _mount(tester, api);
      expect(nativeFacetPaths.length, 21);
      for (final path in nativeFacetPaths) {
        final filters = <String, dynamic>{
          'keyword': '采购 %_ 原文',
          'status': 'HISTORY',
          'supplierId': 'selected-1201',
          'rejected': false,
          'dateFrom': '2020-01-01',
          'empty': '',
          'null': null,
        };
        final loader = nativeFacetLoaders(
          ref,
          path: path,
          fields: const ['billNo'],
          filters: filters,
        )['billNo']!;
        filters['keyword'] = 'later mutation';
        final first = await tester.runAsync(() => loader('%_ 中文', 1));
        final second = await tester.runAsync(() => loader('%_ 中文', 2));
        expect(first!.hasMore, isTrue);
        expect(second!.hasMore, isFalse);
        expect(second.items.single.count, 7);
        final request = api.requests.last;
        expect(request.path.contains('?'), isFalse);
        expect(request.body, {
          'keyword': '采购 %_ 原文',
          'status': 'HISTORY',
          'supplierId': 'selected-1201',
          'rejected': false,
          'dateFrom': '2020-01-01',
          '__facetField': 'billNo',
          '__facetKeyword': '%_ 中文',
          '__facetPage': 2,
          '__facetSize': 100,
        });
      }
    },
  );
  testWidgets('late candidate response cannot cross owner A-B-A', (
    tester,
  ) async {
    final api = _Api();
    final (ref, container) = await _mount(tester, api);
    api.paused = Completer();
    final loader = nativeFacetLoaders(
      ref,
      path: '/finance/payables/facets',
      fields: const ['sourceDocNo'],
    )['sourceDocNo']!;
    final pending = loader('', 1);
    final checked = expectLater(pending, throwsStateError);
    container.read(_owner.notifier).change('B');
    await tester.pump();
    container.read(_owner.notifier).change('A');
    await tester.pump();
    api.paused!.complete({
      'field': 'sourceDocNo',
      'page': 1,
      'size': 100,
      'items': <Map<String, dynamic>>[],
      'hasMore': false,
    });
    await tester.pumpAndSettle();
    await checked;
  });
  testWidgets(
    'wrong field/page and overfull responses fail closed; query changes retire search scope',
    (tester) async {
      final api = _Api();
      final (ref, _) = await _mount(tester, api);
      expect(
        nativeFacetSearchScope(ref, '/finance/payables/facets', {
          'status': 'A',
        }),
        isNot(
          nativeFacetSearchScope(ref, '/finance/payables/facets', {
            'status': 'B',
          }),
        ),
      );
      api.paused = Completer();
      final pending = nativeFacetLoaders(
        ref,
        path: '/finance/payables/facets',
        fields: const ['sourceDocNo'],
      )['sourceDocNo']!('', 2);
      final checked = expectLater(pending, throwsStateError);
      api.paused!.complete({
        'field': 'other',
        'page': 1,
        'size': 100,
        'items': <Map<String, dynamic>>[],
        'hasMore': false,
      });
      await tester.pumpAndSettle();
      await checked;
      expect(
        () => nativeFacetLoaders(
          ref,
          path: '/master/clients/facets',
          fields: const ['mobile'],
        ),
        throwsArgumentError,
      );
    },
  );
}
