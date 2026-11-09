import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../support/uten_test_actions.dart';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/applications/models/business_application.dart';
import 'package:uten_imp/features/applications/pages/business_application_list_page.dart';
import 'package:uten_imp/features/applications/repositories/business_application_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'owner-A',
      employeeId: 'owner-A',
      code: 'T01',
      name: '本地夹具',
    ),
  );
}

class _Epoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void retire() => state++;
}

BusinessApplicationQuery _query(String queue) => (
  queue: queue,
  kind: 'PREPAYMENT',
  status: queue == 'mine' ? 'PROCESSING' : null,
  stage: 'FINANCE',
  departmentCode: 'DEPT-ORIGINAL',
  scope: 'owner-A',
);

ProviderContainer _container(ApiClient api, {SharedPreferences? preferences}) =>
    ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_Session.new),
        sessionSnapshotProvider.overrideWith(_Snapshot.new),
        apiBaseUrlProvider.overrideWithValue('http://127.0.0.1:9'),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'owner-A'),
        ),
        currentPermissionsProvider.overrideWithValue(const {}),
        isSuperAdminProvider.overrideWithValue(false),
        if (preferences != null)
          sharedPreferencesProvider.overrideWithValue(preferences),
        businessApplicationRepositoryProvider.overrideWithValue(
          BusinessApplicationRepository(api),
        ),
        masterDataSessionKeyProvider.overrideWithValue('owner-A'),
        exportContextEpochProvider.overrideWith(_Epoch.new),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'held application tail retires on opaque cover and returns with one fresh complete source',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final api = _Api()..second = Completer<Map<String, dynamic>>();
      final container = _container(api, preferences: preferences);
      final navigator = GlobalKey<NavigatorState>();
      await setUtenTestSurfaceSize(tester, const Size(1440, 1000));
      addTearDown(() => setUtenTestSurfaceSize(tester, null));
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              navigatorKey: navigator,
              theme: buildLightTheme(),
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const BusinessApplicationApprovalListPage(
                initialHistory: true,
                historyOnly: true,
              ),
            ),
          ),
        );
        for (var frame = 0; api.reads.length < 2 && frame < 100; frame++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(api.reads.map((read) => read.$2['page']), [1, 2]);
        unawaited(
          navigator.currentState!.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('其它页面')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final old = api.second!;
        api.second = null;
        // The held continuation is the ladder's (2,50) batch.
        expect(api.reads.map((read) => read.$2['size']), [50, 50]);
        old.complete(api.page(2, 50));
        await tester.pumpAndSettle();
        expect(api.reads.map((read) => read.$2['page']), [1, 2]);
        api.prefix = 'fresh';
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        final table = tester.widget<MasterDataTableView<BusinessApplication>>(
          find.byType(MasterDataTableView<BusinessApplication>).first,
        );
        expect(table.items, hasLength(251));
        expect(table.items.last.id, 'fresh-250');
        // One fresh complete source: (1,50)(2,50)(2,100)(2,200).
        expect(api.reads.map((read) => read.$2['page']), [1, 2, 1, 2, 2, 2]);
        expect(
          api.reads.skip(2).map((read) => read.$2['size']),
          [50, 50, 100, 200],
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        container.dispose();
      }
    },
  );

  for (final queue in ['mine', 'pending', 'history', 'prepayment-posting']) {
    test(
      '$queue application provider reads all 251 original scoped summaries',
      () async {
        final api = _Api();
        final container = _container(api);
        addTearDown(container.dispose);
        final provider = businessApplicationListProvider(_query(queue));
        final subscription = container.listen(provider, (_, _) {});
        addTearDown(subscription.close);
        final result = await container.read(provider.future);
        expect(result.items, hasLength(251));
        expect(result.items.last.id, 'A-250');
        expect(result.items.last.amount, '0.0001');
        expect(result.items.last.canPay, isTrue);
        expect(result.items.last.version, 13);
        expect(result.items.last.fields['immutableSource'], 'original-250');
        expect(
          api.reads.map((r) => r.$1),
          List.filled(4, '/business-applications/$queue'),
        );
        // Progressive ladder: rows 0-49, 50-99, 100-199, 200-250.
        expect(api.reads.map((r) => r.$2['page']), [1, 2, 2, 2]);
        expect(api.reads.map((r) => r.$2['size']), [50, 50, 100, 200]);
        for (final read in api.reads) {
          expect(read.$2, {
            'page': read.$2['page'],
            'size': read.$2['size'],
            'kind': 'PREPAYMENT',
            if (queue == 'mine') 'status': 'PROCESSING',
            'approvalStage': 'FINANCE',
            'departmentCode': 'DEPT-ORIGINAL',
          });
        }
      },
    );
  }

  test(
    'a failed later application batch cannot publish a partial list; retry starts at one',
    () async {
      final api = _Api()..failSecond = true;
      final container = _container(api);
      addTearDown(container.dispose);
      final provider = businessApplicationListProvider(_query('history'));
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      unawaited(
        container
            .read(provider.future)
            .then<void>((_) {}, onError: (Object _) {}),
      );
      for (
        var attempt = 0;
        !container.read(provider).hasError && attempt < 200;
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(container.read(provider).hasError, isTrue);
      expect(container.read(provider).hasValue, isFalse);
      api.failSecond = false;
      container.invalidate(provider);
      final complete = await container.read(provider.future);
      expect(complete.items, hasLength(251));
      expect(api.reads.map((r) => r.$2['page']), [1, 2, 1, 2, 2, 2]);
      expect(
        api.reads.map((r) => r.$2['size']),
        [50, 50, 50, 50, 100, 200],
      );
    },
  );

  test(
    'owner A to B to A never accepts the retired application continuation',
    () async {
      final api = _Api()..second = Completer<Map<String, dynamic>>();
      final container = _container(api);
      addTearDown(container.dispose);
      final provider = businessApplicationListProvider(_query('pending'));
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      unawaited(
        container
            .read(provider.future)
            .then<void>((_) {}, onError: (Object _) {}),
      );
      while (api.reads.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      final oldGate = api.second!;
      api.second = null;
      api.prefix = 'fresh-A';
      (container.read(exportContextEpochProvider.notifier) as _Epoch).retire();
      (container.read(exportContextEpochProvider.notifier) as _Epoch).retire();
      final fresh = await container.read(provider.future);
      expect(fresh.items.last.id, 'fresh-A-250');
      oldGate.complete(api.page(2, 50, prefix: 'retired-A'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        container.read(provider).requireValue.items.last.id,
        'fresh-A-250',
      );
    },
  );

  test(
    'closing the actual application provider cancels the owned HTTP continuation',
    () async {
      final adapter = _Adapter();
      final dio = Dio(
        BaseOptions(baseUrl: 'https://application-local.test/api'),
      )..httpClientAdapter = adapter;
      final container = _container(ApiClient(dio));
      addTearDown(() {
        container.dispose();
        dio.close(force: true);
      });
      final provider = businessApplicationListProvider(_query('history'));
      final subscription = container.listen(provider, (_, _) {});
      unawaited(
        container
            .read(provider.future)
            .then<void>((_) {}, onError: (Object _) {}),
      );
      await adapter.ready(2);
      subscription.close();
      await container.pump();
      for (var i = 0; !adapter.cancelled && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(adapter.cancelled, isTrue);
      expect(adapter.requests, hasLength(2));
      adapter.pending.complete(
        ResponseBody.fromString(
          jsonEncode(_Api().page(2, 100)),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
    },
  );

  testWidgets(
    '251 business application rows scroll locally with no paging or replay',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      tester.view.devicePixelRatio = 1;
      await setUtenTestSurfaceSize(tester, const Size(1440, 1000));
      addTearDown(() => setUtenTestSurfaceSize(tester, null));
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _Api();
      final container = _container(api, preferences: preferences);
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: buildLightTheme(),
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const BusinessApplicationApprovalListPage(
                initialHistory: true,
                historyOnly: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final table = tester.widget<MasterDataTableView<BusinessApplication>>(
          find.byType(MasterDataTableView<BusinessApplication>).first,
        );
        expect(table.items, hasLength(251));
        expect(table.items.last.amount, '0.0001');
        final reads = api.reads.length;
        final scrollable = find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .last;
        final position = tester.state<ScrollableState>(scrollable).position;
        for (final fraction in [.95, .0, .75, .0]) {
          position.jumpTo(position.maxScrollExtent * fraction);
          await tester.pumpAndSettle();
        }
        expect(api.reads, hasLength(reads));
        debugPrint(
          'APPLICATION_LOCAL_SCROLL rows=251 dataReads=$reads after=${api.reads.length} independentSessionReads=${api.sessionReads}',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        container.dispose();
      }
    },
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <(String, Map<String, dynamic>)>[];
  int sessionReads = 0;
  bool failSecond = false;
  String prefix = 'A';
  Completer<Map<String, dynamic>>? second;
  Map<String, dynamic> page(int page, int size, {String? prefix}) => {
    'items': [
      for (var i = (page - 1) * size; i < page * size && i < 251; i++)
        {
          'id': '${prefix ?? this.prefix}-$i',
          'applicationNo': 'SQ-$i',
          'kind': 'PREPAYMENT',
          'title': '原申请$i',
          'amount': '0.0001',
          'status': 'APPROVED',
          'applicantId': 'original-owner',
          'applicantName': '原申请人',
          'createdAt': '2026-11-05T08:00:00+08:00',
          'version': 13,
          'canPay': true,
          'fields': {'immutableSource': 'original-$i'},
        },
    ],
    'page': page,
    'size': size,
    'total': 251,
    'totalPages': (251 / size).ceil(),
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/auth/me') {
      sessionReads++;
      return {
        'id': 'owner-A',
        'employeeId': 'owner-A',
        'code': 'T01',
        'name': '本地夹具',
        'permissions': <String>[],
        'delegableSurfaceKeys': <String>[],
        'documentScopes': <String, dynamic>{},
        'preferences': <String, dynamic>{},
      };
    }
    if (path.endsWith('/counts')) return {};
    if (!path.startsWith('/business-applications/')) {
      throw StateError('Unexpected fixture read: $path');
    }
    reads.add((path, {...?query}));
    final number = query!['page'] as int;
    final size = query['size'] as int;
    if (number == 2 && failSecond) {
      throw ApiException('UNAVAILABLE', 'offline', httpStatus: 503);
    }
    if (number == 2 && second != null) return second!.future;
    return page(number, size);
  }
}

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final pending = Completer<ResponseBody>();
  bool cancelled = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requests.length == 1) {
      return ResponseBody.fromString(
        jsonEncode(_Api().page(1, 100)),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    cancelFuture?.then((_) => cancelled = true);
    return pending.future;
  }

  Future<void> ready(int count) async {
    for (var i = 0; requests.length < count && i < 500; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(requests, hasLength(count));
  }

  @override
  void close({bool force = false}) {}
}
