import 'dart:async';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/posting_style_role_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/posting_style_role_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

const _stamp = '2026-10-11T10:00:00.123456Z';
const _missing = PostingStyleRole(
  roleKey: 'INVENTORY_ASSET',
  description: '库存商品科目',
  requiredCategory: 'ACCOUNT',
  updatedAt: _stamp,
  usable: false,
);
const _configured = PostingStyleRole(
  roleKey: 'SALES_REVENUE',
  description: '销售收入科目',
  requiredCategory: 'INCOME',
  updatedAt: _stamp,
  usable: true,
  styleId: 'income',
  styleName: '原销售收入',
);

class _Roles implements PostingStyleRoleRepository {
  List<PostingStyleRole> roles = [_missing, _configured];
  int writes = 0;
  int reads = 0;
  Completer<void>? readGate, writeGate;
  bool loseReply = false;
  bool stale = false;
  bool canConfigure = true;
  @override
  Future<AuthenticatedRequestScope> captureScope({
    required bool Function() isCurrent,
  }) => AuthenticatedRequestScope.capture(
    baseUrl: 'http://fixture/api',
    storage: null,
    isCurrent: isCurrent,
  );
  @override
  Future<List<PostingStyleRole>> list(AuthenticatedRequestScope scope) async {
    reads++;
    await readGate?.future;
    return roles
        .map(
          (role) => PostingStyleRole(
            roleKey: role.roleKey,
            description: role.description,
            requiredCategory: role.requiredCategory,
            updatedAt: role.updatedAt,
            usable: role.usable,
            styleId: role.styleId,
            styleName: role.styleName,
            canConfigure: canConfigure && !role.usable,
          ),
        )
        .toList();
  }

  @override
  Future<PostingStyleRole> configure(
    PostingStyleRole role,
    String styleId,
    AuthenticatedRequestScope scope,
  ) async {
    await scope.verify();
    writes++;
    await writeGate?.future;
    expect(role.updatedAt, _stamp);
    expect(styleId, 'account');
    if (stale) throw ApiException('CONFLICT', '科目用途已变化，请刷新核对后保存');
    final next = PostingStyleRole(
      roleKey: role.roleKey,
      description: role.description,
      requiredCategory: role.requiredCategory,
      updatedAt: _stamp,
      usable: true,
      styleId: styleId,
      styleName: '测试库存资产',
    );
    roles = [next, _configured];
    if (loseReply) throw NetworkTimeoutException();
    return next;
  }
}

class _Styles implements PaymentStyleRepository {
  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async => [
    PaymentStyleNode(
      id: 'account',
      code: '001',
      name: '测试库存资产',
      category: 'ACCOUNT',
      status: '使用',
      children: [],
    ),
    PaymentStyleNode(
      id: 'disabled',
      code: '002',
      name: '禁用科目',
      category: 'ACCOUNT',
      status: '禁用',
      children: [],
    ),
    PaymentStyleNode(
      id: 'wrong',
      code: '003',
      name: '其它类别科目',
      category: 'INCOME',
      status: '使用',
      children: [],
    ),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _mount(
  WidgetTester tester,
  _Roles roles, {
  bool edit = true,
}) async {
  roles.canConfigure = edit;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue({
          Perm.paymentStyleView,
          Perm.financePostExecute,
          if (edit) Perm.paymentStyleEdit,
        }),
        postingStyleRoleRepositoryProvider.overrideWithValue(roles),
        paymentStyleRepositoryProvider.overrideWithValue(_Styles()),
      ],
      child: const MaterialApp(home: Scaffold(body: PostingStyleRolePanel())),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester) async {
  await tester.tap(find.byType(UtenDropdownField));
  await tester.pumpAndSettle();
  expect(find.textContaining('禁用科目'), findsNothing);
  expect(find.textContaining('其它类别科目'), findsNothing);
  await tester.tap(find.text('001 · 测试库存资产').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'missing role saves matching active account; configured role remains readonly',
    (tester) async {
      final roles = _Roles();
      await _mount(tester, roles);
      expect(find.text('已配置：原销售收入'), findsOneWidget);
      expect(find.text('保存用途'), findsOneWidget);
      await _select(tester);
      await tester.tap(find.text('保存用途'));
      await tester.pumpAndSettle();
      expect(roles.writes, 1);
      expect(find.text('已配置：测试库存资产'), findsOneWidget);
      expect(find.text('保存用途'), findsNothing);
    },
  );
  testWidgets('viewing finance actor with no account edit cannot configure', (
    tester,
  ) async {
    final roles = _Roles();
    await _mount(tester, roles, edit: false);
    expect(find.text('保存用途'), findsNothing);
    expect(find.textContaining('尚未配置，请由'), findsOneWidget);
    expect(roles.writes, 0);
  });
  testWidgets(
    'stale role refreshes without losing selected account or pretending success',
    (tester) async {
      final roles = _Roles()..stale = true;
      await _mount(tester, roles);
      await _select(tester);
      await tester.tap(find.text('保存用途'));
      await tester.pumpAndSettle();
      expect(find.text('科目用途已变化，请刷新核对后保存'), findsOneWidget);
      expect(find.text('001 · 测试库存资产'), findsOneWidget);
      expect(roles.writes, 1);
      expect(find.text('已配置：测试库存资产'), findsNothing);
    },
  );
  for (final save in [false, true]) {
    testWidgets(
      'role ${save ? 'save' : 'refresh'} uses one waiting card and finishes once',
      (tester) async {
        final roles = _Roles();
        await _mount(tester, roles);
        if (save) await _select(tester);
        final gate = Completer<void>();
        if (save) {
          roles.writeGate = gate;
        } else {
          roles.readGate = gate;
        }
        final button = save ? find.text('保存用途') : find.byTooltip('刷新');
        final semantics = tester.ensureSemantics();
        try {
          await tester.tap(button);
          await tester.tap(button);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          try {
            expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
            var announcements = 0;
            final title = save ? '正在保存科目用途' : '正在读取科目用途';
            void visit(SemanticsNode node) {
              if (node.getSemanticsData().label.startsWith(title)) {
                announcements++;
              }
              node.visitChildren((child) {
                visit(child);
                return true;
              });
            }

            final root = tester
                .binding
                .renderViews
                .single
                .owner
                ?.semanticsOwner
                ?.rootSemanticsNode;
            if (root != null) visit(root);
            expect(announcements, 1);
            expect(save ? roles.writes : roles.reads, save ? 1 : 2);
          } finally {
            gate.complete();
          }
          await tester.pumpAndSettle();
          expect(find.byType(UtenBusyOverlayCard), findsNothing);
          expect(save ? roles.writes : roles.reads, save ? 1 : 2);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );
  }
  testWidgets(
    'lost role reply preserves choice and requires a read before another write',
    (tester) async {
      final roles = _Roles()..loseReply = true;
      await _mount(tester, roles);
      await _select(tester);
      await tester.tap(find.text('保存用途'));
      await tester.pumpAndSettle();
      expect(roles.writes, 1);
      expect(find.text('001 · 测试库存资产'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存用途'))
            .onPressed,
        isNull,
      );
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(find.text('已配置：测试库存资产'), findsOneWidget);
      expect(find.text('保存用途'), findsNothing);
      expect(roles.writes, 1);
    },
  );
  testWidgets(
    'disposing a saving panel removes its wait and rereads without replay',
    (tester) async {
      final roles = _Roles();
      await _mount(tester, roles);
      await _select(tester);
      final gate = Completer<void>();
      roles.writeGate = gate;
      await tester.tap(find.text('保存用途'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(roles.writes, 1);
      await _mount(tester, roles);
      expect(find.text('已配置：测试库存资产'), findsOneWidget);
      expect(roles.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'repository retains raw server stamp and rejects invalid page scope before PUT',
    () async {
      final api = _Api();
      final repo = DioPostingStyleRoleRepository(api);
      bool current = true;
      final scope = await repo.captureScope(isCurrent: () => current);
      await repo.configure(_missing, 'account', scope);
      expect(api.body, {'styleId': 'account', 'expectedUpdatedAt': _stamp});
      current = false;
      await expectLater(
        repo.configure(_missing, 'account', scope),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'SESSION_CHANGED'),
        ),
      );
      expect(api.writes, 1);
    },
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'http://fixture/api')));
  Object? body;
  int writes = 0;
  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    this.body = body;
    writes++;
    expect(path, '/finance/posting-style-roles/INVENTORY_ASSET');
    return {
      'roleKey': 'INVENTORY_ASSET',
      'description': '库存商品科目',
      'requiredCategory': 'ACCOUNT',
      'updatedAt': _stamp,
      'usable': true,
      'styleId': 'account',
      'styleName': '测试库存资产',
    };
  }
}
