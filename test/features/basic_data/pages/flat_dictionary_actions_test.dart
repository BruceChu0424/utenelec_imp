import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/pages/color_page.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/pages/currency_page.dart';
import 'package:uten_imp/features/basic_data/pages/unit_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/models/user.dart';

import '../../../shared/drafts/memory_form_draft_storage.dart';

final _grants = StateProvider<Set<String>>((_) => {});
final _identity = StateProvider<AuthenticatedScope>(
  (_) => const AuthenticatedScope(userId: 'flat-dictionary-test'),
);

class _Session extends SessionNotifier {
  @override
  SessionState build() {
    final identity = ref.watch(_identity);
    return SessionState(
      status: AuthStatus.authenticated,
      user: AppUser(
        id: identity.userId,
        code: identity.userId,
        name: identity.userId,
        permissions: ref.watch(_grants).toList(),
      ),
      impersonationReadOnly: identity.readOnly,
    );
  }
}

void main() {
  for (final type in ['units', 'colors', 'currencies']) {
    for (final foreignPopup in [false, true]) {
      for (final detailError in [false, true]) {
        testWidgets(
          '$type shell root loading foreignPopup=$foreignPopup detailError=$detailError',
          (tester) async {
            final pending = Completer<void>();
            final api = _Api(type)
              ..holdDetailReads = pending
              ..detailError = detailError;
            final container = await _pump(tester, type, api, shell: true);
            final pageContext = tester.element(find.byType(_pageType(type)));
            final leafRoute = ModalRoute.of(pageContext)!;
            expect(
              Navigator.of(pageContext),
              isNot(same(Navigator.of(pageContext, rootNavigator: true))),
            );
            _openDetail(tester, type);
            await tester.pump(const Duration(milliseconds: 80));
            expect(leafRoute.isCurrent, isTrue);
            ModalRoute<dynamic>? foreignRoute;
            if (foreignPopup) {
              unawaited(
                showDialog<void>(
                  context: pageContext,
                  builder: (ctx) {
                    foreignRoute = ModalRoute.of(ctx);
                    return const AlertDialog(content: Text('根导航器新窗口'));
                  },
                ),
              );
              await tester.pump(const Duration(milliseconds: 350));
              expect(leafRoute.isCurrent, isTrue);
              expect(foreignRoute!.isCurrent, isTrue);
            }
            pending.complete();
            await tester.pumpAndSettle();
            expect(find.byType(CircularProgressIndicator), findsNothing);
            if (foreignPopup) {
              expect(foreignRoute!.isCurrent, isTrue);
              expect(find.text('根导航器新窗口'), findsOneWidget);
              expect(find.text('编辑'), findsNothing);
              expect(container.read(appNotificationProvider), isEmpty);
            } else if (detailError) {
              expect(
                container.read(appNotificationProvider).map((n) => n.message),
                contains('旧详情失败'),
              );
            } else {
              expect(find.text('编辑'), findsOneWidget);
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
    for (final action in ['删除选中', '停用选中']) {
      testWidgets('$type $action confirmation cannot revive after A B A', (
        tester,
      ) async {
        final api = _Api(type);
        final container = await _pump(tester, type, api);
        await tester.tap(find.text('资料一'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        expect(find.byType(UtenAlertDialog), findsOneWidget);
        container.read(_identity.notifier).state = const AuthenticatedScope(
          userId: 'second-user',
        );
        await tester.pumpAndSettle();
        container.read(_identity.notifier).state = const AuthenticatedScope(
          userId: 'flat-dictionary-test',
        );
        await tester.pumpAndSettle();
        expect(find.byType(UtenAlertDialog), findsNothing);
        expect(api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets(
      '$type revoke then regrant closes the old confirmation permanently',
      (tester) async {
        final api = _Api(type);
        final container = await _pump(tester, type, api);
        await tester.tap(find.text('资料一'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('停用选中'));
        await tester.pumpAndSettle();
        final grants = container.read(_grants);
        container.read(_grants.notifier).state = {'${_prefix(type)}:view'};
        await tester.pumpAndSettle();
        container.read(_grants.notifier).state = grants;
        await tester.pumpAndSettle();
        expect(find.byType(UtenAlertDialog), findsNothing);
        expect(api.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('$type query change closes its owned confirmation', (
      tester,
    ) async {
      final api = _Api(type);
      await _pump(tester, type, api);
      await tester.tap(find.text('资料一'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中'));
      await tester.pumpAndSettle();
      _table(tester).onFilterChanged('status', '禁用');
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      '$type result dialog closes on identity change and keeps fresh data private',
      (tester) async {
        final api = _Api(type)..failSecond = true;
        final container = await _pump(tester, type, api);
        await tester.tap(find.text('资料二'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除选中'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除').last);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('master-batch-outcome')),
          findsOneWidget,
        );
        container.read(_identity.notifier).state = const AuthenticatedScope(
          userId: 'second-user',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('master-batch-outcome')),
          findsNothing,
        );
        expect(find.text('被货品或单据引用'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
    for (final fail in [false, true]) {
      testWidgets(
        '$type late ${fail ? 'error' : 'success'} cannot toast or close a new popup',
        (tester) async {
          final pending = Completer<void>();
          final api = _Api(type)
            ..holdWrites = pending
            ..writeError = fail;
          final container = await _pump(tester, type, api);
          await tester.tap(find.text('资料一'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('停用选中'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认').last);
          await tester.pump(const Duration(milliseconds: 80));
          expect(api.writes, hasLength(1));
          container.read(_identity.notifier).state = const AuthenticatedScope(
            userId: 'second-user',
          );
          await tester.pumpAndSettle();
          container.read(_identity.notifier).state = const AuthenticatedScope(
            userId: 'flat-dictionary-test',
          );
          await tester.pumpAndSettle();
          unawaited(
            showDialog<void>(
              context: tester.element(find.byType(_pageType(type))),
              builder: (_) => const AlertDialog(content: Text('新身份的窗口')),
            ),
          );
          await tester.pumpAndSettle();
          pending.complete();
          await tester.pumpAndSettle();
          expect(find.text('新身份的窗口'), findsOneWidget);
          expect(find.text('旧请求失败'), findsNothing);
          expect(container.read(appNotificationProvider), isEmpty);
          expect(find.textContaining('已停用'), findsNothing);
          expect(
            find.byKey(const ValueKey('master-batch-outcome')),
            findsNothing,
          );
          expect(api.writes, hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      '$type old completion cannot clear a new identity command busy state',
      (tester) async {
        final first = Completer<void>();
        final second = Completer<void>();
        final api = _Api(type)..holdWrites = first;
        final container = await _pump(tester, type, api);
        await tester.tap(find.text('资料一'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('停用选中'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认').last);
        await tester.pump(const Duration(milliseconds: 80));
        expect(api.writes, hasLength(1));
        container.read(_identity.notifier).state = const AuthenticatedScope(
          userId: 'second-user',
        );
        await tester.pumpAndSettle();
        api.holdWrites = second;
        await tester.tap(find.text('资料一'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('停用选中'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认').last);
        await tester.pump(const Duration(milliseconds: 80));
        expect(api.writes, hasLength(2));
        first.complete();
        await tester.pump(const Duration(milliseconds: 80));
        expect(find.text('正在处理${_noun(type)}'), findsOneWidget);
        expect(find.textContaining('已停用'), findsNothing);
        expect(container.read(appNotificationProvider), isEmpty);
        second.complete();
        await tester.pumpAndSettle();
        expect(find.text('正在处理${_noun(type)}'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('$type full editor saves once, closes and refreshes its list', (
      tester,
    ) async {
      final api = _Api(type);
      final container = await _pump(tester, type, api);
      await _openEdit(tester, type);
      final reads = api.listReads;
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.controller?.text == '资料一',
        ),
        '资料已改',
      );
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();
      expect(api.writes, hasLength(1));
      expect(api.writes.single.path, '/master/$type/one');
      expect(find.byType(MasterEditForm), findsNothing);
      expect(api.listReads, greaterThan(reads));
      expect(find.text('资料已改'), findsOneWidget);
      expect(
        container.read(appNotificationProvider).map((n) => n.message),
        contains('${_noun(type)}已更新'),
      );
      expect(tester.takeException(), isNull);
    });
    testWidgets('$type pending editor load cannot reopen after A B A', (
      tester,
    ) async {
      final pending = Completer<void>();
      final api = _Api(type)..holdDetailReads = pending;
      final container = await _pump(tester, type, api);
      final opening = Future<void>.sync(_editEntry(tester, type).onTap);
      await tester.pump(const Duration(milliseconds: 80));
      expect(api.detailReads, 1);
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'second-user',
      );
      await tester.pumpAndSettle();
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'flat-dictionary-test',
      );
      await tester.pumpAndSettle();
      pending.complete();
      await tester.pumpAndSettle();
      await opening;
      expect(find.byType(MasterEditForm), findsNothing);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
    testWidgets('$type leaving and returning cannot revive a confirmation', (
      tester,
    ) async {
      final api = _Api(type);
      await _pump(tester, type, api);
      final pageContext = tester.element(find.byType(_pageType(type)));
      await tester.tap(find.text('资料一'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除选中'));
      await tester.pumpAndSettle();
      final nav = Navigator.of(pageContext);
      unawaited(
        nav.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('另一个页面')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('另一个页面'), findsOneWidget);
      nav.pop();
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
    testWidgets('$type full editor cannot survive identity A B A', (
      tester,
    ) async {
      final api = _Api(type);
      final container = await _pump(tester, type, api);
      await _openEdit(tester, type);
      expect(find.byType(MasterEditForm), findsOneWidget);
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'second-user',
      );
      await tester.pumpAndSettle();
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'flat-dictionary-test',
      );
      await tester.pumpAndSettle();
      expect(find.byType(MasterEditForm), findsNothing);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
    testWidgets('$type pending full save is silent after identity changes', (
      tester,
    ) async {
      final pending = Completer<void>();
      final api = _Api(type)
        ..holdWrites = pending
        ..writeError = true;
      final container = await _pump(tester, type, api);
      await _openEdit(tester, type);
      await tester.tap(find.text('保存').last);
      await tester.pump(const Duration(milliseconds: 80));
      expect(api.writes, hasLength(1));
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'second-user',
      );
      await tester.pumpAndSettle();
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(MasterEditForm), findsNothing);
      expect(find.text('旧请求失败'), findsNothing);
      expect(find.text('${_noun(type)}已更新'), findsNothing);
      expect(container.read(appNotificationProvider), isEmpty);
      expect(tester.takeException(), isNull);
    });
    for (final identityChanged in [false, true]) {
      for (final detailError in [false, true]) {
        testWidgets(
          '$type detail loading owns only its original popup identityChanged=$identityChanged detailError=$detailError',
          (tester) async {
            final pending = Completer<void>();
            final api = _Api(type)
              ..holdDetailReads = pending
              ..detailError = detailError;
            final container = await _pump(tester, type, api);
            _openDetail(tester, type);
            await tester.pump(const Duration(milliseconds: 80));
            expect(find.byType(CircularProgressIndicator), findsWidgets);
            if (identityChanged) {
              container.read(_identity.notifier).state =
                  const AuthenticatedScope(userId: 'second-user');
              await tester.pumpAndSettle();
            }
            unawaited(
              showDialog<void>(
                context: tester.element(find.byType(_pageType(type))),
                builder: (_) => const AlertDialog(content: Text('新身份的窗口')),
              ),
            );
            await tester.pump(const Duration(milliseconds: 350));
            pending.complete();
            await tester.pumpAndSettle();
            expect(find.text('新身份的窗口'), findsOneWidget);
            expect(find.text('编辑'), findsNothing);
            expect(find.text('旧详情失败'), findsNothing);
            expect(container.read(appNotificationProvider), isEmpty);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
    testWidgets(
      '$type current detail failure closes loading and reports its own error',
      (tester) async {
        final api = _Api(type)..detailError = true;
        final container = await _pump(tester, type, api);
        _openDetail(tester, type);
        await tester.pumpAndSettle();
        expect(
          container.read(appNotificationProvider).map((n) => n.message),
          contains('旧详情失败'),
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('$type read detail closes on permission revoke', (
      tester,
    ) async {
      final api = _Api(type);
      final container = await _pump(tester, type, api);
      _openDetail(tester, type);
      await tester.pumpAndSettle();
      expect(find.text('编辑'), findsOneWidget);
      container.read(_grants.notifier).state = {};
      await tester.pumpAndSettle();
      expect(find.text('编辑'), findsNothing);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      '$type single and multiple selection share one floating group and confirm before writes',
      (tester) async {
        final api = _Api(type);
        await _pump(tester, type, api);
        await tester.tap(find.text('资料一'));
        await tester.pumpAndSettle();
        expect(find.text('删除选中'), findsOneWidget);
        expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
        await tester.tap(find.text('删除选中'));
        await tester.pumpAndSettle();
        expect(api.writes, isEmpty);
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        expect(api.writes, isEmpty);
        await tester.tap(find.text('资料二'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('停用选中'));
        await tester.pumpAndSettle();
        expect(api.writes, isEmpty);
        await tester.tap(find.text('确认').last);
        await tester.pumpAndSettle();
        if (type == 'currencies') {
          expect(api.writes.map((r) => r.path), [
            '/master/currencies/one/status',
            '/master/currencies/two/status',
          ]);
        } else {
          expect(api.writes, hasLength(1));
          expect(api.writes.single.path, '/master/$type/batch-status');
          expect((api.writes.single.data as Map)['items'], [
            {'id': 'one'},
            {'id': 'two'},
          ]);
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$type confirmation rechecks revoked permissions and sends zero commands',
      (tester) async {
        final api = _Api(type);
        final container = await _pump(tester, type, api);
        await tester.tap(find.text('资料一'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除选中'));
        await tester.pumpAndSettle();
        container.read(_grants.notifier).state = {'${_prefix(type)}:view'};
        await tester.pumpAndSettle();
        expect(find.text('删除${_noun(type)}'), findsNothing);
        expect(api.writes, isEmpty);
        expect(find.text('删除选中'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$type keeps batch actions disabled while editing and saves through CAS',
      (tester) async {
        final api = _Api(type);
        await _pump(tester, type, api);
        await tester.tap(find.text('资料一'));
        await tester.pumpAndSettle();
        final delete = tester
            .widget<UtenButton>(
              find
                  .ancestor(
                    of: find.text('删除选中'),
                    matching: find.byType(UtenButton),
                  )
                  .first,
            )
            .onPressed!;
        await tester.tap(find.text('编辑模式'));
        await tester.pumpAndSettle();
        await Future<void>.sync(delete);
        await tester.pumpAndSettle();
        expect(find.text('删除${_noun(type)}'), findsNothing);
        expect(api.writes, isEmpty);
        await tester.tap(
          find.byKey(const ValueKey('inline-activate-one-name')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('inline-one-name')),
            matching: find.byType(TextField),
          ),
          '修改后',
        );
        await tester.pump();
        await tester.tap(find.text('保存 1 行修改'));
        await tester.pumpAndSettle();
        expect(api.writes.single.path, '/master/inline-edit/$type/one');
        expect(api.writes.single.data, {
          'expected': {'name': '资料一'},
          'changes': {'name': '修改后'},
        });
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '$type pending command shows feedback and keeps failed selections',
      (tester) async {
        final api = _Api(type)..failSecond = true;
        final pending = Completer<void>();
        api.holdWrites = pending;
        await _pump(tester, type, api);
        await tester.tap(find.text('资料一'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('资料二'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除选中'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除').last);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.pump(const Duration(milliseconds: 80));
        expect(find.text('正在处理${_noun(type)}'), findsOneWidget);
        pending.complete();
        await tester.pumpAndSettle();
        expect(find.text('被货品或单据引用'), findsOneWidget);
        await tester.tap(find.byType(UtenCloseButton));
        await tester.pumpAndSettle();
        final table = tester.widget<MasterDataTableView<dynamic>>(
          find.byWidgetPredicate(
            (widget) => widget is MasterDataTableView<dynamic>,
          ),
        );
        expect(table.selectedIds, {'two'});
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '$type opening an editor paints loading and rejects a duplicate request',
      (tester) async {
        final api = _Api(type);
        final pending = Completer<void>();
        api.holdDetailReads = pending;
        await _pump(tester, type, api);
        final menu = switch (type) {
          'units' => _firstRowMenu<UnitListItem>(tester),
          'colors' => _firstRowMenu<ColorListItem>(tester),
          _ => _firstRowMenu<CurrencyListItem>(tester),
        };
        final edit = menu
            .whereType<UtenMenuItem>()
            .singleWhere((entry) => entry.label == '编辑${_noun(type)}')
            .onTap;
        final first = Future<void>.sync(edit);
        await tester.pump(const Duration(milliseconds: 80));
        await tester.pump(const Duration(milliseconds: 80));
        expect(find.text('正在处理${_noun(type)}'), findsOneWidget);
        await Future<void>.sync(edit);
        expect(api.detailReads, 1);
        pending.complete();
        await first;
        await tester.pumpAndSettle();
        expect(find.byType(MasterEditForm), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'currency serial batch stops after the pending first write changes identity',
    (tester) async {
      final pending = Completer<void>();
      final api = _Api('currencies')..holdWrites = pending;
      final container = await _pump(tester, 'currencies', api);
      await tester.tap(find.text('资料一'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('资料二'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('停用选中'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认').last);
      await tester.pump(const Duration(milliseconds: 80));
      expect(api.writes.single.path, '/master/currencies/one/status');
      container.read(_identity.notifier).state = const AuthenticatedScope(
        userId: 'second-user',
      );
      await tester.pumpAndSettle();
      pending.complete();
      await tester.pumpAndSettle();
      expect(api.writes, hasLength(1));
      expect(api.detailReads, 1);
      expect(find.textContaining('已停用'), findsNothing);
      expect(container.read(appNotificationProvider), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'currency base remains unselectable and cannot enter a destructive batch',
    (tester) async {
      final api = _Api('currencies');
      await _pump(tester, 'currencies', api);
      await tester.tap(find.text('本位币'));
      await tester.pumpAndSettle();
      expect(find.text('删除选中'), findsNothing);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('color remark is available in view, full editor and inline CAS', (
    tester,
  ) async {
    final api = _Api('colors');
    await _pump(tester, 'colors', api);
    expect(find.text('旧备注'), findsOneWidget);
    await tester.tap(find.text('资料一'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('资料一'));
    await tester.pumpAndSettle();
    expect(find.text('旧备注'), findsWidgets);
    await tester.tap(find.text('编辑').last);
    await tester.pumpAndSettle();
    final form = tester.widget<MasterEditForm>(find.byType(MasterEditForm));
    expect(form.fields.map((field) => field.key), [
      'code',
      'name',
      'status',
      'remark',
    ]);
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == '旧备注',
      ),
      '新备注',
    );
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect((api.writes.single.data as Map)['remark'], '新备注');
    expect(tester.takeException(), isNull);
  });
  testWidgets('color inline remark submits its own CAS baseline', (
    tester,
  ) async {
    final api = _Api('colors');
    await _pump(tester, 'colors', api);
    await tester.tap(find.text('编辑模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('inline-activate-one-remark')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('inline-one-remark')),
        matching: find.byType(TextField),
      ),
      '行内备注',
    );
    await tester.pump();
    await tester.tap(find.text('保存 1 行修改'));
    await tester.pumpAndSettle();
    expect(api.writes.single.data, {
      'expected': {'remark': '旧备注'},
      'changes': {'remark': '行内备注'},
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('unit compact large text keeps selection actions reachable', (
    tester,
  ) async {
    await _pump(tester, 'units', _Api('units'), textScale: 1.5);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    await tester.tap(find.text('资料一'));
    await tester.pumpAndSettle();
    final group = tester.getRect(find.byType(UtenFloatingActionGroup));
    expect(group.left, greaterThanOrEqualTo(0));
    expect(group.right, lessThanOrEqualTo(390));
    expect(group.top, greaterThanOrEqualTo(0));
    expect(group.bottom, lessThanOrEqualTo(844));
    expect(find.text('删除选中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

String _prefix(String type) =>
    {'units': 'unit', 'colors': 'color', 'currencies': 'currency'}[type]!;
String _noun(String type) =>
    {'units': '单位', 'colors': '颜色', 'currencies': '币种'}[type]!;

Type _pageType(String type) => switch (type) {
  'units' => UnitPage,
  'colors' => ColorPage,
  _ => CurrencyPage,
};

MasterDataTableView<dynamic> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<dynamic>>(
      find.byWidgetPredicate((w) => w is MasterDataTableView<dynamic>),
    );

Future<void> _openEdit(WidgetTester tester, String type) async {
  final opening = Future<void>.sync(_editEntry(tester, type).onTap);
  await tester.pumpAndSettle();
  await opening;
}

UtenMenuItem _editEntry(WidgetTester tester, String type) {
  final menu = switch (type) {
    'units' => _firstRowMenu<UnitListItem>(tester),
    'colors' => _firstRowMenu<ColorListItem>(tester),
    _ => _firstRowMenu<CurrencyListItem>(tester),
  };
  return menu.whereType<UtenMenuItem>().singleWhere(
    (e) => e.label == '编辑${_noun(type)}',
  );
}

void _openDetail(WidgetTester tester, String type) {
  switch (type) {
    case 'units':
      final table = tester.widget<MasterDataTableView<UnitListItem>>(
        find.byType(MasterDataTableView<UnitListItem>),
      );
      table.onRowTap!(table.items.first);
    case 'colors':
      final table = tester.widget<MasterDataTableView<ColorListItem>>(
        find.byType(MasterDataTableView<ColorListItem>),
      );
      table.onRowTap!(table.items.first);
    default:
      final table = tester.widget<MasterDataTableView<CurrencyListItem>>(
        find.byType(MasterDataTableView<CurrencyListItem>),
      );
      table.onRowTap!(table.items.first);
  }
}

List<UtenContextMenuEntry> _firstRowMenu<T>(WidgetTester tester) {
  final table = tester.widget<MasterDataTableView<T>>(
    find.byType(MasterDataTableView<T>),
  );
  return table.rowMenuBuilder!(table.items.first);
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  String type,
  _Api api, {
  double textScale = 1,
  bool shell = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(1440, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final prefix = _prefix(type);
  final page = switch (type) {
    'units' => const UnitPage(),
    'colors' => const ColorPage(),
    _ => const CurrencyPage(),
  };
  final router = shell
      ? GoRouter(
          initialLocation: '/flat',
          routes: [
            ShellRoute(
              builder: (_, _, child) => child,
              routes: [GoRoute(path: '/flat', builder: (_, _) => page)],
            ),
          ],
        )
      : null;
  if (router != null) addTearDown(router.dispose);
  Widget appBuilder(BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith(_Session.new),
        apiClientProvider.overrideWithValue(api.client),
        sharedPreferencesProvider.overrideWithValue(preferences),
        formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
        _grants.overrideWith(
          (_) => {
            '$prefix:view',
            '$prefix:edit',
            '$prefix:create',
            '$prefix:status',
            '$prefix:delete',
          },
        ),
      ],
      child: router != null
          ? MaterialApp.router(
              routerConfig: router,
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: appBuilder,
            )
          : MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: appBuilder,
              home: page,
            ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(
      find.byType(switch (type) {
        'units' => UnitPage,
        'colors' => ColorPage,
        _ => CurrencyPage,
      }),
    ),
  );
}

class _Api {
  _Api(this.type) {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            if (request.method != 'GET') writes.add(request);
            if (request.method != 'GET') await holdWrites?.future;
            if (request.method != 'GET' && writeError) {
              handler.reject(
                DioException.badResponse(
                  statusCode: 409,
                  requestOptions: request,
                  response: Response<dynamic>(
                    requestOptions: request,
                    statusCode: 409,
                    data: {'code': 'CONFLICT', 'message': '旧请求失败'},
                  ),
                ),
              );
              return;
            }
            final path = request.path;
            Object data = <String, dynamic>{};
            if (request.method == 'GET') {
              if (path == '/master/$type') {
                listReads++;
                data = {
                  'items': rows.values.toList(),
                  'page': 1,
                  'size': 20,
                  'total': rows.length,
                  'totalPages': 1,
                };
              } else if (rows.containsKey(path.split('/').last)) {
                detailReads++;
                await holdDetailReads?.future;
                if (detailError) {
                  handler.reject(
                    DioException.badResponse(
                      statusCode: 409,
                      requestOptions: request,
                      response: Response<dynamic>(
                        requestOptions: request,
                        statusCode: 409,
                        data: {'code': 'CONFLICT', 'message': '旧详情失败'},
                      ),
                    ),
                  );
                  return;
                }
                data = Map<String, dynamic>.from(rows[path.split('/').last]!);
              } else if (path.endsWith('code-availability')) {
                data = {'available': true};
              }
            } else if (path.endsWith('/batch-status') ||
                path.endsWith('/batch-delete')) {
              final body = request.data as Map;
              final items = body['items'] as List;
              data = {
                'succeeded': items.length - (failSecond ? 1 : 0),
                'failed': failSecond ? 1 : 0,
                'results': [
                  for (final item in items)
                    {
                      'id': (item as Map)['id'],
                      'ok': !(failSecond && item['id'] == 'two'),
                      if (failSecond && item['id'] == 'two')
                        'reason': '被货品或单据引用',
                    },
                ],
              };
            } else if (failSecond &&
                request.method != 'GET' &&
                path.contains('/two')) {
              handler.reject(
                DioException.badResponse(
                  statusCode: 409,
                  requestOptions: request,
                  response: Response<dynamic>(
                    requestOptions: request,
                    statusCode: 409,
                    data: {'code': 'CONFLICT', 'message': '被货品或单据引用'},
                  ),
                ),
              );
              return;
            } else if (path.contains('/inline-edit/')) {
              rows[path.split('/').last]!.addAll(
                Map<String, dynamic>.from(
                  (request.data as Map)['changes'] as Map,
                ),
              );
            } else if (request.method == 'PUT' &&
                rows.containsKey(path.split('/').last)) {
              rows[path.split('/').last]!.addAll(
                Map<String, dynamic>.from(request.data as Map),
              );
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: request,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      );
    client = ApiClient(dio);
    if (type == 'currencies') {
      rows['base'] = {
        'id': 'base',
        'code': 'CNY',
        'name': '本位币',
        'status': '使用',
        'baseCurrency': true,
        'exchangeRate': 1,
      };
    }
  }
  final String type;
  final writes = <RequestOptions>[];
  bool failSecond = false;
  bool writeError = false;
  bool detailError = false;
  int listReads = 0;
  Completer<void>? holdWrites;
  Completer<void>? holdDetailReads;
  int detailReads = 0;
  late final ApiClient client;
  final rows = <String, Map<String, dynamic>>{
    'one': {
      'id': 'one',
      'code': 'CODE001',
      'name': '资料一',
      'status': '使用',
      'remark': '旧备注',
      'exchangeRate': 1,
    },
    'two': {
      'id': 'two',
      'code': 'CODE002',
      'name': '资料二',
      'status': '使用',
      'exchangeRate': 2,
    },
  };
}
