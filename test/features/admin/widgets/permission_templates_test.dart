import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/admin/models/admin_models.dart';
import 'package:uten_imp/features/admin/models/permission_configuration.dart';
import 'package:uten_imp/features/admin/models/permission_template.dart';
import 'package:uten_imp/features/admin/providers/admin_providers.dart';
import 'package:uten_imp/features/admin/repositories/permission_template_repository.dart';
import 'package:uten_imp/features/admin/widgets/admin_permission_templates.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import '../../../support/audit_screenshot_support.dart';

final _identity = StateProvider<String>((ref) => 'admin');
final _captureKey = GlobalKey();
const _capture = bool.fromEnvironment('UTEN_CAPTURE_PERMISSION_TEMPLATES');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [375.0, 1440.0]) {
    testWidgets('template detail and editor fit at $width with large text', (
      tester,
    ) async {
      final repository = _Repository();
      await _mount(
        tester,
        repository,
        const AdminPermissionTemplatesView(navigation: SizedBox()),
        width: width,
        scale: 1.8,
      );
      await tester.tap(find.text('采购模板'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'permission-template-detail-${width.toInt()}',
        );
      }
      await tester.ensureVisible(find.text('编辑模板'));
      await tester.tap(find.text('编辑模板'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final dialog = find.byType(UtenAlertDialog);
      final search = find.descendant(
        of: dialog,
        matching: find.byKey(const ValueKey('permission-catalog-search')),
      );
      final note = find.byKey(
        const ValueKey('permission-template-sensitive-note'),
      );
      expect(tester.getRect(note).bottom, lessThan(tester.getRect(search).top));
      final module = find.descendant(
        of: dialog,
        matching: find.byKey(const ValueKey('permission-module-基础资料')),
      );
      final field = tester.getRect(
        find.byKey(const ValueKey('permission-template-name')),
      );
      expect(tester.getRect(module).left, greaterThanOrEqualTo(field.left - 1));
      expect(tester.getRect(module).right, lessThanOrEqualTo(field.right + 1));
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'permission-template-editor-${width.toInt()}',
        );
      }
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repository.writes, 0);
    });
  }

  testWidgets(
    'expanded catalog stays inside the editor at 200 percent with a keyboard',
    (tester) async {
      final repository = _Repository();
      await _mount(
        tester,
        repository,
        const AdminPermissionTemplatesView(navigation: SizedBox()),
        width: 375,
        scale: 2,
        manyPermissions: true,
      );
      await tester.tap(find.text('采购模板'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('编辑模板'));
      await tester.tap(find.text('编辑模板'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final toggle = find.descendant(
        of: find.byType(UtenAlertDialog),
        matching: find.byKey(const ValueKey('permission-toggle-all-groups')),
      );
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final last = find.byKey(
        const ValueKey('template-code-fixture:permission:19'),
      );
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('save-permission-template')))
            .bottom,
        lessThanOrEqualTo(800),
      );
      final field = tester.getRect(
        find.byKey(const ValueKey('permission-template-name')),
      );
      expect(tester.getRect(last).left, greaterThanOrEqualTo(field.left - 1));
      expect(tester.getRect(last).right, lessThanOrEqualTo(field.right + 1));
    },
  );

  testWidgets(
    'editing saves reviewed codes and version; cancelling never mutates',
    (tester) async {
      final repository = _Repository();
      await _mount(
        tester,
        repository,
        const AdminPermissionTemplatesView(navigation: SizedBox()),
      );
      await tester.tap(find.text('采购模板'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑模板'));
      await tester.pumpAndSettle();
      final name = find.descendant(
        of: find.byKey(const ValueKey('permission-template-name')),
        matching: find.byType(TextField),
      );
      await tester.enterText(name, '采购与仓库');
      await tester.tap(find.byKey(const ValueKey('save-permission-template')));
      await tester.pumpAndSettle();
      expect(repository.savedName, '采购与仓库');
      expect(repository.savedCodes, {'goods:view'});
      expect(repository.savedVersion, 3);
      expect(repository.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'apply requires preview and sensitive confirmation, mode changes clear both',
    (tester) async {
      final repository = _Repository();
      await _mount(
        tester,
        repository,
        AdminPermissionTemplateActions(
          user: _user,
          enabled: true,
          onApplied: () {},
        ),
      );
      await _choose(tester);
      final apply = find.byKey(
        const ValueKey('confirm-apply-permission-template'),
      );
      expect(tester.widget<UtenButton>(apply).onPressed, isNull);
      await tester.tap(find.text('预览变更'));
      await tester.pumpAndSettle();
      expect(repository.previewModes, [true]);
      expect(tester.widget<UtenButton>(apply).onPressed, isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-sensitive-template-sensitive')),
      );
      await tester.tap(
        find.byKey(const ValueKey('confirm-sensitive-template-sensitive')),
      );
      await tester.pump();
      expect(tester.widget<UtenButton>(apply).onPressed, isNotNull);
      await tester.ensureVisible(find.text('覆盖为模板'));
      await tester.tap(find.text('覆盖为模板'));
      await tester.pumpAndSettle();
      expect(tester.widget<UtenButton>(apply).onPressed, isNull);
      expect(
        find.byKey(const ValueKey('confirm-sensitive-template-sensitive')),
        findsNothing,
      );
      await tester.ensureVisible(find.text('预览变更'));
      await tester.tap(find.text('预览变更'));
      await tester.pumpAndSettle();
      expect(repository.previewModes, [true, false]);
      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-sensitive-template-sensitive')),
      );
      await tester.tap(
        find.byKey(const ValueKey('confirm-sensitive-template-sensitive')),
      );
      await tester.pump();
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      expect(repository.appliedFingerprint, 'template-preview');
      expect(repository.appliedConfirmations, {'template-sensitive'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'identity changes invalidate an open preview without submitting',
    (tester) async {
      final repository = _Repository();
      final container = await _mount(
        tester,
        repository,
        AdminPermissionTemplateActions(
          user: _user,
          enabled: true,
          onApplied: () {},
        ),
      );
      await _choose(tester);
      await tester.tap(find.text('预览变更'));
      await tester.pumpAndSettle();
      container.read(_identity.notifier).state = 'other-admin';
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('confirm-apply-permission-template')),
            )
            .onPressed,
        isNull,
      );
      expect(repository.writes, 0);
    },
  );

  testWidgets(
    'unknown apply outcome blocks retries until the result is reloaded',
    (tester) async {
      final repository = _Repository()..applyError = NetworkTimeoutException();
      await _mount(
        tester,
        repository,
        AdminPermissionTemplateActions(
          user: _user,
          enabled: true,
          onApplied: () {},
        ),
      );
      await _choose(tester);
      await tester.tap(find.text('预览变更'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm-sensitive-template-sensitive')),
      );
      await tester.tap(
        find.byKey(const ValueKey('confirm-sensitive-template-sensitive')),
      );
      await tester.pump();
      final apply = find.byKey(
        const ValueKey('confirm-apply-permission-template'),
      );
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      expect(tester.widget<UtenButton>(apply).onPressed, isNull);
      expect(find.textContaining('请求结果尚未确认'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(repository.writes, 1);
    },
  );
}

Future<void> _choose(WidgetTester tester) async {
  await tester.tap(find.text('应用模板'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(DropdownButtonFormField<PermissionTemplate>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('采购模板').last);
  await tester.pumpAndSettle();
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Repository repository,
  Widget child, {
  double width = 1440,
  double scale = 1,
  bool manyPermissions = false,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (_capture) await loadAuditScreenshotFonts(tester);
  final api = ApiClient(Dio(BaseOptions(baseUrl: 'https://example.test/api')));
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      isSuperAdminProvider.overrideWithValue(true),
      currentPermissionsProvider.overrideWithValue({Perm.authorizationManage}),
      permissionTemplateRepositoryProvider.overrideWithValue(repository),
      permissionCatalogProvider.overrideWith(
        (ref) async => [
          PermissionCatalogGroup(
            module: '基础资料',
            category: '货品资料',
            permissions: [
              const AdminPermission(
                id: 'goods',
                code: 'goods:view',
                name: '查看货品',
                category: '货品资料',
              ),
              if (manyPermissions)
                for (var i = 0; i < 20; i++)
                  AdminPermission(
                    id: 'fixture-$i',
                    code: 'fixture:permission:$i',
                    name: '测试权限 $i',
                    category: '货品资料',
                  ),
            ],
          ),
        ],
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
      child: RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          theme: _capture
              ? auditScreenshotTheme(buildLightTheme())
              : buildLightTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(body: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

const _user = AdminUserSummary(
  id: 'target',
  loginAccount: 'target',
  status: 'active',
  mustChangePassword: false,
  remoteAccess: false,
  currentEmployee: true,
  employeeStatus: 'active',
  employeeName: '员工甲',
);

class _Repository extends PermissionTemplateRepository {
  _Repository() : super(ApiClient(Dio()));
  final template = PermissionTemplate(
    id: 'template',
    name: '采购模板',
    description: List.filled(12, '采购岗位可复用的操作权限。').join(),
    permissions: ['goods:view'],
    version: 3,
  );
  int writes = 0;
  String? savedName;
  Set<String>? savedCodes;
  int? savedVersion;
  String? appliedFingerprint;
  Set<String>? appliedConfirmations;
  Object? applyError;
  final previewModes = <bool>[];
  @override
  Future<List<PermissionTemplate>> list() async => [template];
  @override
  Future<void> save({
    PermissionTemplate? template,
    required String name,
    required String description,
    required Set<String> permissions,
  }) async {
    writes++;
    savedName = name;
    savedCodes = {...permissions};
    savedVersion = template?.version;
  }

  @override
  Future<PermissionTransferPreview> preview(
    String target,
    PermissionTemplate template,
    bool merge,
  ) async {
    previewModes.add(merge);
    return PermissionTransferPreview.fromJson({
      'fingerprint': 'template-preview',
      'canApply': true,
      'issues': <String>[],
      'changes': <Map<String, dynamic>>[],
      'notes': <String>[],
      'suggestions': <Map<String, dynamic>>[],
      'pinnedBaselineAdditions': <String>[],
      'sensitiveAdditions': [
        {
          'key': 'template-sensitive',
          'label': '商业信息',
          'permissionCode': 'goods:price:view',
          'targetLabel': '员工甲',
        },
      ],
    });
  }

  @override
  Future<void> apply(
    String target,
    PermissionTemplate template,
    bool merge,
    PermissionTransferPreview preview,
    Set<String> confirmations,
  ) async {
    writes++;
    appliedFingerprint = preview.fingerprint;
    appliedConfirmations = {...confirmations};
    if (applyError != null) throw applyError!;
  }
}
