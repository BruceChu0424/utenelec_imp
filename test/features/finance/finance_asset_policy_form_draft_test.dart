import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/finance/widgets/finance_asset_policy_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';

void main() {
  testWidgets(
    'starting another policy preserves saved partial draft and resumes its raw fields',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = MemoryFormDraftStorage();
      var env = await _pump(tester, storage);
      expect(env.container.read(formDraftsProvider), isEmpty);
      _input(tester, '政策代码 *').text = 'DRAFT-A';
      _input(tester, '政策名称 *').text = '尚未完整的会计政策';
      _input(tester, '政策月份 *').text = '1.';
      await tester.pumpAndSettle();
      final first = env.container.read(formDraftsProvider).single;
      await tester.tap(find.text('新建政策'));
      await tester.pumpAndSettle();
      expect(find.text('是否保存为草稿？'), findsOneWidget);
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(_input(tester, '政策代码 *').text, isEmpty);
      expect(env.container.read(formDraftsProvider).single.id, first.id);
      _input(tester, '政策代码 *').text = 'DRAFT-B';
      await tester.pumpAndSettle();
      expect(env.container.read(formDraftsProvider), hasLength(2));
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();

      env = await _pump(tester, storage, location: first.resumeLocation);
      expect(_input(tester, '政策代码 *').text, 'DRAFT-A');
      expect(_input(tester, '政策名称 *').text, '尚未完整的会计政策');
      expect(_input(tester, '政策月份 *').text, '1.');
      expect(env.container.read(formDraftsProvider), hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      env.router.dispose();
      env.container.dispose();
    },
  );
}

TextEditingController _input(WidgetTester tester, String label) => tester
    .widget<UtenInput>(
      find.byWidgetPredicate(
        (widget) => widget is UtenInput && widget.label == label,
      ),
    )
    .controller!;

Future<({ProviderContainer container, GoRouter router})> _pump(
  WidgetTester tester,
  MemoryFormDraftStorage storage, {
  String location = '/finance/assets',
}) async {
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(_Api()),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'policy-user'),
      ),
      currentPermissionsProvider.overrideWithValue({
        Perm.financeAssetView,
        Perm.financeAssetApprove,
      }),
      apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  final router = GoRouter(
    initialLocation: location,
    routes: [
      DraftAwareGoRoute(
        path: '/finance/assets',
        builder: (_, state) => Scaffold(
          body: FinanceAssetPolicySurface(
            canApprove: true,
            resumeDraftId: state.uri.queryParameters['draftId'],
            routerPageKey: state.pageKey,
          ),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, router: router);
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {'items': <Map<String, dynamic>>[]};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}
