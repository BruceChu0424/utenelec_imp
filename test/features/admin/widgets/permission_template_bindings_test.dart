import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/admin/models/permission_template.dart';
import 'package:uten_imp/features/admin/repositories/permission_template_repository.dart';
import 'package:uten_imp/features/admin/widgets/permission_template_binding_strip.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

const _bindingA = PermissionTemplateBinding(
  kind: 'user',
  targetId: 'target',
  templateId: 'template-a',
  templateName: '模板甲',
  templateVersion: 7,
);
const _bindingB = PermissionTemplateBinding(
  kind: 'user',
  targetId: 'target',
  templateId: 'template-b',
  templateName: '模板乙',
  templateVersion: 9,
);
final _binding = StateProvider<PermissionTemplateBinding>((ref) => _bindingA);
final _identity = StateProvider<String>((ref) => 'operator');

void main() {
  test('unbind sends only the five reviewed binding identity fields', () async {
    final api = _BindingApi();
    await PermissionTemplateRepository(
      api,
    ).unbind(userIds: ['target'], expectedBindings: [_bindingA]);
    expect(api.requests.single, {
      'userIds': ['target'],
      'departmentIds': <String>[],
      'expectedBindings': [
        {
          'kind': 'user',
          'targetId': 'target',
          'templateId': 'template-a',
          'templateVersion': 7,
          'legacySnapshot': false,
        },
      ],
    });
    final expected =
        (api.requests.single['expectedBindings'] as List).single as Map;
    expect(expected.length, 5);
    expect(expected.containsKey('templateName'), isFalse);
  });

  testWidgets('confirmation retains binding A when another operator binds B', (
    tester,
  ) async {
    final api = _BindingApi()..rejectChangedBinding = true;
    final container = await _mount(tester, api);
    await tester.tap(find.text('解除关联'));
    await tester.pumpAndSettle();
    container.read(_binding.notifier).state = _bindingB;
    api.actual = _bindingB;
    await tester.pumpAndSettle();
    await tester.tap(find.text('解除关联').last);
    await tester.pumpAndSettle();
    expect(api.requests, hasLength(1));
    expect((api.requests.single['expectedBindings'] as List).single, {
      'kind': 'user',
      'targetId': 'target',
      'templateId': 'template-a',
      'templateVersion': 7,
      'legacySnapshot': false,
    });
    expect(api.detached, isFalse);
    expect(container.read(_binding).templateId, 'template-b');
    expect(find.text('关联模板：模板乙'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final changeIdentity in [false, true]) {
    testWidgets(
      'unbind does not send after cancel or identity change: identity=$changeIdentity',
      (tester) async {
        final api = _BindingApi();
        final container = await _mount(tester, api);
        await tester.tap(find.text('解除关联'));
        await tester.pumpAndSettle();
        if (changeIdentity) {
          container.read(_identity.notifier).state = 'other-operator';
          await tester.pumpAndSettle();
          await tester.tap(find.text('解除关联').last);
        } else {
          await tester.tap(find.text('取消'));
        }
        await tester.pumpAndSettle();
        expect(api.requests, isEmpty);
        expect(api.detached, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<ProviderContainer> _mount(WidgetTester tester, _BindingApi api) async {
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      isSuperAdminProvider.overrideWithValue(true),
      currentPermissionsProvider.overrideWithValue({Perm.authorizationManage}),
      permissionTemplateRepositoryProvider.overrideWithValue(
        PermissionTemplateRepository(api),
      ),
      permissionTemplateBindingsProvider.overrideWith(
        (ref) async => [ref.watch(_binding)],
      ),
      sensitiveReadBoundaryProvider.overrideWith(
        (ref) => SensitiveReadBoundary(
          identity: AuthenticatedScope(userId: ref.watch(_identity)),
          api: api,
          permissions: {Perm.authorizationManage},
          superAdmin: true,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PermissionTemplateBindingStrip(
            kind: 'user',
            targetId: 'target',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

class _BindingApi extends ApiClient {
  _BindingApi() : super(Dio(BaseOptions(baseUrl: 'https://example.test/api')));
  final requests = <Map<String, dynamic>>[];
  bool rejectChangedBinding = false;
  bool detached = false;
  PermissionTemplateBinding actual = _bindingA;

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    expect(path, '/admin/permission-templates/unbind');
    final request = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
    requests.add(request);
    final expected = (request['expectedBindings'] as List).single as Map;
    if (rejectChangedBinding && expected['templateId'] != actual.templateId) {
      throw ApiException('CONFLICT', '模板关联已变化，请重新读取后确认解除关联', httpStatus: 409);
    }
    detached = true;
    return {};
  }
}
