import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/repositories/unit_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/rd_task/models/rd_task.dart';
import 'package:uten_imp/features/rd_task/pages/rd_task_page.dart';
import 'package:uten_imp/features/rd_task/widgets/rd_initial_basic_unit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../helpers/badge_summary_fixture.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'A'),
);
final _server = StateProvider<String>((ref) => 'https://a.test/api');
final _permissions = StateProvider<Set<String>>(
  (ref) => {'rd_task:view', 'goods:view', 'goods:edit', 'unit:view'},
);

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://a.test/api')));
  final posts = <String>[];
  Completer<Map<String, dynamic>>? admission;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/initial-basic-unit')) {
      return admission?.future ?? {'allowed': true};
    }
    if (path == '/rd-tasks') {
      return {
        'items': [
          {
            'id': 'task',
            'taskNo': 'RD-1',
            'title': '缺单位组件',
            'category': 'OTHER',
            'status': 'OPEN',
            'priority': 'NORMAL',
            'rowVersion': 1,
            'goodsId': 'goods',
            'sourceDocType': 'MATERIAL_ANALYSIS_MASTER_ISSUE',
            'allowedActions': ['RECONCILE_BASIC_UNIT'],
          },
        ],
        'page': 1,
        'size': 20,
        'total': 1,
        'totalPages': 1,
      };
    }
    return const {'count': 0, 'open': 0, 'inProgress': 0};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    posts.add(path);
    return const {};
  }
}

class _Units extends Fake implements UnitRepository {
  @override
  Future<List<UnitListItem>> dict() async => const [
    UnitListItem(id: 'unit', name: '个', status: '使用'),
  ];
}

void main() {
  for (final kind in ['account', 'server', 'permission']) {
    testWidgets(
      'initial-unit confirmation rejects $kind A-B-A and drops late preflight',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        await tester.binding.setSurfaceSize(const Size(1400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final api = _Api()..admission = Completer<Map<String, dynamic>>();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(api),
              unitRepositoryProvider.overrideWithValue(_Units()),
              sharedPreferencesProvider.overrideWithValue(preferences),
              authenticatedScopeProvider.overrideWith(
                (ref) => ref.watch(_identity),
              ),
              apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
              currentPermissionsProvider.overrideWith(
                (ref) => ref.watch(_permissions),
              ),
              isSuperAdminProvider.overrideWithValue(false),
              fixedBadgeSummaryOverride(badgeSummaryFixture()),
            ],
            child: const MaterialApp(
              locale: Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: RdTaskPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final table = tester.widget<MasterDataTableView<RdTaskRow>>(
          find.byType(MasterDataTableView<RdTaskRow>),
        );
        table.onRowTap!(table.items.single);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(RdInitialBasicUnitDialog), findsOneWidget);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(RdTaskPage)),
        );
        if (kind == 'account') {
          container.read(_identity.notifier).state = const AuthenticatedScope(
            userId: 'B',
          );
        } else if (kind == 'server') {
          container.read(_server.notifier).state = 'https://b.test/api';
        } else {
          container.read(_permissions.notifier).state = {
            'rd_task:view',
            'goods:view',
            'unit:view',
          };
        }
        await tester.pump();
        if (kind == 'account') {
          container.read(_identity.notifier).state = const AuthenticatedScope(
            userId: 'A',
          );
        } else if (kind == 'server') {
          container.read(_server.notifier).state = 'https://a.test/api';
        } else {
          container.read(_permissions.notifier).state = {
            'rd_task:view',
            'goods:view',
            'goods:edit',
            'unit:view',
          };
        }
        await tester.pump();
        api.admission!.complete({'allowed': true});
        await tester.pumpAndSettle();
        expect(find.byType(RdInitialBasicUnitDialog), findsNothing);
        expect(api.posts, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
