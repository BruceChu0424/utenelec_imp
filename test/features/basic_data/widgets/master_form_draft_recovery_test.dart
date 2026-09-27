import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_dialog_resume.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../../shared/drafts/memory_form_draft_storage.dart';

void main() {
  testWidgets(
    'master dialog saves partial values on exit and resumes on its retained parent route',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var submits = 0;
      final storage = MemoryFormDraftStorage();
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'master-user'),
          ),
          currentPermissionsProvider.overrideWithValue({'master:create'}),
          apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
          formDraftStorageProvider.overrideWithValue(storage),
        ],
      );
      final router = GoRouter(
        initialLocation: '/master',
        routes: [
          DraftAwareGoRoute(
            path: '/master',
            builder: (_, _) => _Host(
              onSubmit: (body) async {
                submits++;
                return true;
              },
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
      await tester.tap(find.text('新增'));
      await tester.pumpAndSettle();
      expect(container.read(formDraftsProvider), isEmpty);
      await tester.enterText(_field('名称'), '尚未完成资料');
      await tester.enterText(_field('数量'), '1.');
      await tester.tap(find.text('选择业务员'));
      await tester.pumpAndSettle();
      expect(submits, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('是否保存为草稿？'), findsOneWidget);
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(find.byType(MasterEditForm), findsNothing);
      final draft = container.read(formDraftsProvider).single;
      expect((draft.data['text'] as Map)['数量'], '1.');
      expect((draft.data['custom'] as Map)['owner'], 'employee-1');
      expect(submits, 0);

      // Query-only navigation deliberately preserves the master page State.
      router.go(draft.resumeLocation);
      await tester.pumpAndSettle();
      expect(find.byType(MasterEditForm), findsOneWidget);
      expect(tester.widget<TextField>(_field('名称')).controller!.text, '尚未完成资料');
      expect(tester.widget<TextField>(_field('数量')).controller!.text, '1.');
      expect(find.text('业务员:employee-1'), findsOneWidget);
      await tester.enterText(_field('数量'), '2');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(submits, 1);
      expect(container.read(formDraftsProvider), isEmpty);
      expect(find.byType(MasterEditForm), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      container.dispose();
    },
  );
}

Finder _field(String key) => find.byType(TextField).at(key == '名称' ? 0 : 1);

class _Host extends StatelessWidget {
  const _Host({required this.onSubmit});
  final MasterSubmit onSubmit;
  static const _descriptor = FormDraftDescriptor(
    title: '新增资料',
    module: BadgeModule.sales,
    route: '/master',
    permission: 'master:create',
    dialogKind: 'master',
  );

  Future<void> _open(BuildContext context) => showMasterEditDialog(
    context: context,
    title: '新增资料',
    draftSpec: _descriptor.spec(),
    fields: [
      const MasterFieldDef(key: '名称', label: '名称', required: true),
      const MasterFieldDef(
        key: '数量',
        label: '数量',
        type: MasterFieldType.integer,
      ),
      MasterFieldDef(
        key: 'owner',
        label: '业务员',
        type: MasterFieldType.custom,
        customBuilder: (field) => Column(
          children: [
            Text('业务员:${field.initialValue ?? ''}'),
            TextButton(
              onPressed: () => field.onChanged('employee-1'),
              child: const Text('选择业务员'),
            ),
          ],
        ),
      ),
    ],
    onSubmit: onSubmit,
  );

  @override
  Widget build(BuildContext context) => FormDraftDialogResume(
    descriptor: _descriptor,
    onResume: (_) => _open(context),
    child: Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => _open(context),
          child: const Text('新增'),
        ),
      ),
    ),
  );
}
