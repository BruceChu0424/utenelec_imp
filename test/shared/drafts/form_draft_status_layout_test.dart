import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/ui/capsule_nav_metrics.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'form_draft_mixin_test.dart' show MemoryDraftStorage;

class _Editor extends ConsumerStatefulWidget {
  const _Editor();
  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> with FormDraftMixin<_Editor> {
  final input = TextEditingController();
  int actions = 0;
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  FormDraftSpec get formDraftSpec => const FormDraftSpec(
    title: '布局测试',
    module: BadgeModule.sales,
    route: '/new',
    permission: 'test:create',
  );
  @override
  Iterable<Listenable> get formDraftListenables => [input];
  @override
  Map<String, dynamic> captureFormDraft() => {'input': input.text};
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async =>
      input.text = data['input'] as String;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => initializeFormDraft());
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => withFormDraft(
    Scaffold(
      body: ListView(
        children: [
          TextField(key: const Key('layout-input'), controller: input),
          const SizedBox(height: 450),
          const Text('最后一行'),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: FilledButton(
          key: const Key('layout-action'),
          onPressed: () => actions++,
          child: const Text('保存业务单据'),
        ),
      ),
    ),
  );
}

void main() {
  for (final scenario in [
    (568.0, 0.0, 0.0, false),
    (568.0, 260.0, 0.0, true),
    (700.0, 0.0, 70.0, false),
  ]) {
    for (final failure in [false, true]) {
      testWidgets(
        'draft status never covers footer height=${scenario.$1} keyboard=${scenario.$2} capsule=${scenario.$3} failure=$failure',
        (tester) async {
          tester.view.physicalSize = Size(375, scenario.$1);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final storage = MemoryDraftStorage()..failWrites = failure;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                authenticatedScopeProvider.overrideWithValue(
                  const AuthenticatedScope(userId: 'layout'),
                ),
                currentPermissionsProvider.overrideWithValue({'test:create'}),
                apiBaseUrlProvider.overrideWithValue(
                  'https://layout.example/api',
                ),
                formDraftStorageProvider.overrideWithValue(storage),
              ],
              child: MaterialApp(
                theme: scenario.$4 ? buildDarkTheme() : buildLightTheme(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh'),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: const TextScaler.linear(2),
                    viewInsets: EdgeInsets.only(bottom: scenario.$2),
                  ),
                  child: UtenCapsuleNavScope(
                    occlusion: scenario.$3,
                    child: child!,
                  ),
                ),
                home: const _Editor(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final state = tester.state<_EditorState>(find.byType(_Editor));
          final inputState = tester.state(
            find.byKey(const Key('layout-input')),
          );
          await tester.enterText(find.byKey(const Key('layout-input')), '保留输入');
          await tester.pumpAndSettle();
          if (failure) {
            final retry = find.byKey(const Key('form-draft-save-retry'));
            expect(retry.hitTestable(), findsOneWidget);
            expect(
              tester
                  .getRect(retry)
                  .overlaps(
                    tester.getRect(find.byKey(const Key('layout-action'))),
                  ),
              isFalse,
            );
            storage.failWrites = false;
            await tester.tap(retry);
            await tester.pumpAndSettle();
            expect(storage.records, hasLength(1));
            expect(state.actions, 0);
          }
          final status = find.text('已自动保存本机草稿');
          expect(status, findsOneWidget);
          final statusRect = tester.getRect(status);
          final actionRect = tester.getRect(
            find.byKey(const Key('layout-action')),
          );
          expect(statusRect.overlaps(actionRect), isFalse);
          expect(
            statusRect.bottom,
            lessThanOrEqualTo(scenario.$1 - scenario.$2 - scenario.$3),
          );
          await tester.tap(find.byKey(const Key('layout-action')));
          expect(state.actions, 1);
          expect(tester.state(find.byType(_Editor)), same(state));
          expect(state.input.text, '保留输入');
          expect(
            tester.state(find.byKey(const Key('layout-input'))),
            same(inputState),
          );
          await state.completeFormDraft();
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('form-draft-status-bar')), findsNothing);
          expect(
            tester.state(find.byKey(const Key('layout-input'))),
            same(inputState),
          );
          await tester.scrollUntilVisible(
            find.text('最后一行'),
            100,
            scrollable: find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(find.text('最后一行').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
