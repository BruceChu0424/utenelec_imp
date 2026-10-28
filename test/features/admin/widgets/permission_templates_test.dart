import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/cards/uten_card.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/features/admin/widgets/permission_catalog_browser.dart';
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
import 'package:uten_imp/shared/auth/permission_action_type.dart';
import 'package:uten_imp/shared/auth/permission_grant_policy.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import '../../../support/audit_screenshot_support.dart';

final _identity = StateProvider<String>((ref) => 'admin');
final _captureKey = GlobalKey();
const _capture = bool.fromEnvironment('UTEN_CAPTURE_PERMISSION_TEMPLATES');
const _ordinaryDependencyCatalog = [
  AdminPermission(
    id: 'goods-view',
    code: 'goods:view',
    name: '查看货品',
    category: '货品资料',
    actionType: PermissionActionType.view,
  ),
  AdminPermission(
    id: 'goods-edit',
    code: 'goods:edit',
    name: '编辑货品',
    category: '货品资料',
    actionType: PermissionActionType.edit,
    requiredPermissions: ['goods:view'],
  ),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('template selection includes safe ordinary read dependencies', (
    tester,
  ) async {
    final repository = _Repository()
      ..template = const PermissionTemplate(
        id: 'template',
        name: '采购模板',
        description: '',
        permissions: [],
        version: 3,
      );
    await _mount(
      tester,
      repository,
      const AdminPermissionTemplatesView(navigation: SizedBox()),
      catalogPermissions: _ordinaryDependencyCatalog,
    );
    await tester.tap(find.text('采购模板'));
    await tester.pumpAndSettle();
    await _expandCatalog(tester);
    await tester.tap(find.byKey(const ValueKey('template-code-goods:edit')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('template-code-goods:view')),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('template-code-goods:edit')),
          )
          .value,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('save-permission-template')));
    await tester.pumpAndSettle();
    expect(repository.savedCodes, {'goods:view', 'goods:edit'});
    expect(repository.writes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('template selection never silently includes a sensitive read', (
    tester,
  ) async {
    final repository = _Repository()
      ..template = const PermissionTemplate(
        id: 'template',
        name: '采购模板',
        description: '',
        permissions: [],
        version: 3,
      );
    await _mount(
      tester,
      repository,
      const AdminPermissionTemplatesView(navigation: SizedBox()),
      catalogPermissions: const [
        AdminPermission(
          id: 'sensitive-view',
          code: 'goods:price:view',
          name: '查看价格',
          category: '货品资料',
          actionType: PermissionActionType.view,
          sensitivity: 'SENSITIVE_COMMERCIAL',
          grantPolicy: PermissionGrantPolicy({
            PermissionGrantPolicy.bulkExcluded,
          }),
        ),
        AdminPermission(
          id: 'price-edit',
          code: 'goods:price:edit',
          name: '修改价格',
          category: '货品资料',
          actionType: PermissionActionType.edit,
          requiredPermissions: ['goods:price:view'],
        ),
      ],
    );
    await tester.tap(find.text('采购模板'));
    await tester.pumpAndSettle();
    await _expandCatalog(tester);
    final action = find.byKey(const ValueKey('template-code-goods:price:edit'));
    final sensitive = find.byKey(
      const ValueKey('template-code-goods:price:view'),
    );
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(action).value, isFalse);
    expect(tester.widget<Switch>(sensitive).value, isFalse);
    expect(repository.writes, 0);
    await tester.tap(sensitive);
    await tester.pumpAndSettle();
    expect(find.text('确认模板敏感权限'), findsOneWidget);
    await tester.tap(find.text('确认加入模板'));
    await tester.pumpAndSettle();
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(sensitive).value, isTrue);
    expect(tester.widget<Switch>(action).value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'template association on another tab cannot skip sensitive confirmation',
    (tester) async {
      final repository = _Repository()
        ..template = const PermissionTemplate(
          id: 'template',
          name: '采购模板',
          description: '',
          permissions: [],
          version: 3,
        );
      final tab = ValueNotifier(0);
      addTearDown(tab.dispose);
      await _mount(
        tester,
        repository,
        ValueListenableBuilder<int>(
          valueListenable: tab,
          builder: (context, selected, child) => Column(
            children: [
              Row(
                children: [
                  TextButton(
                    onPressed: () => tab.value = 0,
                    child: const Text('返回模板设置'),
                  ),
                  TextButton(
                    onPressed: () => tab.value = 1,
                    child: const Text('切换员工授权'),
                  ),
                ],
              ),
              Expanded(
                child: IndexedStack(
                  index: selected,
                  children: [
                    const AdminPermissionTemplatesView(navigation: SizedBox()),
                    Center(
                      child: TextButton(
                        onPressed: () {
                          repository.template = const PermissionTemplate(
                            id: 'template',
                            name: '采购模板',
                            description: '',
                            permissions: [],
                            version: 3,
                            appliedCount: 1,
                            appliedUserCount: 1,
                          );
                          ProviderScope.containerOf(
                            context,
                          ).invalidate(permissionTemplatesProvider);
                        },
                        child: const Text('关联一名员工'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        catalogPermissions: const [
          AdminPermission(
            id: 'sensitive-view',
            code: 'goods:price:view',
            name: '查看价格',
            category: '货品资料',
            actionType: PermissionActionType.view,
            sensitivity: 'SENSITIVE_COMMERCIAL',
            grantPolicy: PermissionGrantPolicy({
              PermissionGrantPolicy.bulkExcluded,
            }),
          ),
        ],
      );
      await tester.tap(find.text('采购模板'));
      await tester.pumpAndSettle();
      await _expandCatalog(tester);
      await tester.tap(find.text('切换员工授权'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关联一名员工'));
      await tester.pumpAndSettle();
      expect(repository.template.appliedUserCount, 1);
      await tester.tap(find.text('返回模板设置'));
      await tester.pumpAndSettle();
      final sensitive = find.byKey(
        const ValueKey('template-code-goods:price:view'),
      );
      await tester.ensureVisible(sensitive);
      await tester.tap(sensitive);
      await tester.pumpAndSettle();
      expect(find.text('确认模板敏感权限'), findsOneWidget);
      expect(tester.widget<Switch>(sensitive).value, isFalse);
      expect(repository.writes, 0);
      expect(repository.savedConfirmations, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(sensitive).value, isFalse);
      expect(repository.writes, 0);
      expect(repository.savedConfirmations, isEmpty);
      await tester.tap(sensitive);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认加入模板'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(sensitive).value, isTrue);
      await tester.tap(find.byKey(const ValueKey('save-permission-template')));
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      expect(repository.savedConfirmations.single, {'goods:price:view'});
      expect(repository.savedCodes, {'goods:price:view'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'template selection removes dependent actions when its read is cleared',
    (tester) async {
      final repository = _Repository()
        ..template = const PermissionTemplate(
          id: 'template',
          name: '采购模板',
          description: '',
          permissions: ['goods:view', 'goods:edit'],
          version: 3,
        );
      await _mount(
        tester,
        repository,
        const AdminPermissionTemplatesView(navigation: SizedBox()),
        catalogPermissions: _ordinaryDependencyCatalog,
      );
      await tester.tap(find.text('采购模板'));
      await tester.pumpAndSettle();
      await _expandCatalog(tester);
      await tester.tap(find.byKey(const ValueKey('template-code-goods:view')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('template-code-goods:view')),
            )
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey('template-code-goods:edit')),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('save-permission-template')));
      await tester.pumpAndSettle();
      expect(repository.savedCodes, isEmpty);
      expect(repository.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('delete confirms on the dialog navigator inside a nested page', (
    tester,
  ) async {
    final repository = _Repository();
    final nested = GlobalKey<NavigatorState>();
    await _mount(
      tester,
      repository,
      Navigator(
        key: nested,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('parent page')),
        ),
      ),
    );
    nested.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          body: AdminPermissionTemplatesView(navigation: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('采购模板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除模板'));
    await tester.pumpAndSettle();
    final confirm = find
        .descendant(
          of: find.byType(UtenAlertDialog),
          matching: find.text('删除模板'),
        )
        .last;
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(repository.deletedId, 'template');
    expect(repository.savedVersion, 3);
    expect(find.byType(UtenAlertDialog), findsNothing);
    expect(find.byType(AdminPermissionTemplatesView), findsOneWidget);
    expect(nested.currentState!.canPop(), isTrue);
  });
  testWidgets(
    'new template dialog only collects metadata then opens permissions',
    (tester) async {
      final repository = _Repository();
      await _mount(
        tester,
        repository,
        const AdminPermissionTemplatesView(navigation: SizedBox()),
      );
      final newButton = find.byKey(const ValueKey('new-permission-template'));
      expect(
        find.ancestor(
          of: newButton,
          matching: find.byType(UtenFloatingActionGroup),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('import-permission-template')),
        findsOneWidget,
      );
      await tester.tap(newButton);
      await tester.pumpAndSettle();
      final dialog = find.byType(UtenAlertDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(
          of: dialog,
          matching: find.byType(PermissionCatalogBrowser),
        ),
        findsNothing,
      );
      await tester.enterText(_field('permission-template-name'), '仓库模板');
      await tester.enterText(
        _field('permission-template-description'),
        '收发货岗位',
      );
      await tester.tap(
        find.byKey(const ValueKey('create-permission-template')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UtenAlertDialog), findsNothing);
      expect(repository.savedName, '仓库模板');
      expect(repository.savedCodes, isEmpty);
      expect(repository.savedVersion, isNull);
      expect(find.byType(PermissionCatalogBrowser), findsOneWidget);
      expect(
        find.byKey(const ValueKey('save-permission-template')),
        findsOneWidget,
      );
      expect(find.text('仓库模板'), findsWidgets);
      await _expandCatalog(tester);
      await tester.tap(find.byKey(const ValueKey('template-code-goods:view')));
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(repository.savedCodes, {'goods:view'});
      expect(repository.savedVersion, 1);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('save-permission-template')))
            .right,
        closeTo(tester.getRect(find.byType(UtenCard)).right, 0.1),
      );
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'permission-template-workspace-desktop',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rapid new-template clicks open a single metadata dialog', (
    tester,
  ) async {
    final repository = _Repository();
    await _mount(
      tester,
      repository,
      const AdminPermissionTemplatesView(navigation: SizedBox()),
    );
    final button = find.byKey(const ValueKey('new-permission-template'));
    final action = tester.widget<UtenButton>(button).onPressed!;
    final first = Future<void>.sync(action);
    final second = Future<void>.sync(action);
    await tester.pumpAndSettle();
    expect(find.byType(UtenAlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await Future.wait([first, second]);
    expect(find.byType(UtenAlertDialog), findsNothing);
    expect(repository.writes, 0);
  });

  for (final width in [375.0, 1440.0]) {
    testWidgets(
      'inline template detail and metadata fit at $width with large text',
      (tester) async {
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
        expect(find.byType(PermissionCatalogBrowser), findsOneWidget);
        expect(find.byType(UtenAlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        if (_capture) {
          await saveAuditScreenshot(
            tester,
            _captureKey,
            'permission-template-detail-${width.toInt()}',
          );
        }
        final edit = find.byKey(const ValueKey('edit-permission-template'));
        await tester.ensureVisible(edit);
        await tester.tap(edit);
        await tester.pumpAndSettle();
        final dialog = find.byType(UtenAlertDialog);
        expect(dialog, findsOneWidget);
        expect(
          find.descendant(
            of: dialog,
            matching: find.byType(PermissionCatalogBrowser),
          ),
          findsNothing,
        );
        expect(_field('permission-template-name'), findsOneWidget);
        expect(_field('permission-template-description'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (_capture) {
          await saveAuditScreenshot(
            tester,
            _captureKey,
            'permission-template-metadata-${width.toInt()}',
          );
        }
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(repository.writes, 0);
      },
    );
  }

  testWidgets(
    'expanded inline permissions stay usable at 200 percent on mobile',
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
      await _expandCatalog(tester);
      final last = find.byKey(
        const ValueKey('template-code-fixture:permission:19'),
      );
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final save = find.byKey(const ValueKey('save-permission-template'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(1100));
      if (_capture) {
        await saveAuditScreenshot(
          tester,
          _captureKey,
          'permission-template-mobile-expanded-200',
        );
      }
      await tester.tap(last);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(repository.savedCodes, contains('fixture:permission:19'));
    },
  );

  testWidgets(
    'metadata edits preserve codes and version; cancelling never writes',
    (tester) async {
      final repository = _Repository();
      await _mount(
        tester,
        repository,
        const AdminPermissionTemplatesView(navigation: SizedBox()),
      );
      await tester.tap(find.text('采购模板'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit-permission-template')));
      await tester.pumpAndSettle();
      await tester.enterText(_field('permission-template-name'), '采购与仓库');
      await tester.tap(find.byKey(const ValueKey('confirm-template-metadata')));
      await tester.pumpAndSettle();
      expect(repository.savedName, '采购与仓库');
      expect(repository.savedCodes, {'goods:view'});
      expect(repository.savedVersion, 3);
      expect(repository.writes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'autosave debounces and subsequent saves use the returned version',
    (tester) async {
      final repository = _Repository();
      await _mount(
        tester,
        repository,
        const AdminPermissionTemplatesView(navigation: SizedBox()),
      );
      await tester.tap(find.text('采购模板'));
      await tester.pumpAndSettle();
      await _expandCatalog(tester);
      final toggle = find.byKey(const ValueKey('template-code-goods:view'));
      await tester.tap(toggle);
      // 草稿不再 650ms 即存（每次保存都要输一次密码）。
      await tester.pump(const Duration(milliseconds: 300));
      expect(repository.writes, 0);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(repository.writes, 0);
      // 停止操作满一分钟：闲置自动保存落库，版本随之推进。
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(repository.savedCodes, isEmpty);
      expect(repository.savedVersion, 3);
      await tester.tap(toggle);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(repository.savedCodes, {'goods:view'});
      expect(repository.savedVersion, 4);
      expect(repository.writes, 2);
    },
  );

  testWidgets('manual save flushes the debounce without a duplicate request', (
    tester,
  ) async {
    final repository = _Repository();
    await _mount(
      tester,
      repository,
      const AdminPermissionTemplatesView(navigation: SizedBox()),
    );
    await tester.tap(find.text('采购模板'));
    await tester.pumpAndSettle();
    await _expandCatalog(tester);
    await tester.tap(find.byKey(const ValueKey('template-code-goods:view')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-permission-template')));
    await tester.pumpAndSettle();
    expect(repository.writes, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(repository.writes, 1);
  });

  testWidgets(
    'new edits during a save survive the response and save serially',
    (tester) async {
      final repository = _Repository();
      final gate = Completer<void>();
      repository.nextSaveGate = gate;
      await _mount(
        tester,
        repository,
        const AdminPermissionTemplatesView(navigation: SizedBox()),
        manyPermissions: true,
      );
      await tester.tap(find.text('采购模板'));
      await tester.pumpAndSettle();
      await _expandCatalog(tester);
      final first = find.byKey(const ValueKey('template-code-goods:view'));
      final second = find.byKey(
        const ValueKey('template-code-fixture:permission:0'),
      );
      await tester.tap(first);
      await tester.pump(const Duration(minutes: 1));
      expect(repository.writes, 1);
      await tester.ensureVisible(second);
      await tester.tap(second);
      await tester.pump(const Duration(minutes: 1));
      expect(repository.writes, 1);
      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(repository.writes, 2);
      expect(repository.savedVersion, 4);
      expect(repository.savedCodes, {'fixture:permission:0'});
      expect(tester.widget<Switch>(second).value, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown autosave outcome preserves edits and blocks automatic retries',
    (tester) async {
      final repository = _Repository()..saveError = NetworkTimeoutException();
      await _mount(
        tester,
        repository,
        const AdminPermissionTemplatesView(navigation: SizedBox()),
      );
      await tester.tap(find.text('采购模板'));
      await tester.pumpAndSettle();
      await _expandCatalog(tester);
      final toggle = find.byKey(const ValueKey('template-code-goods:view'));
      await tester.tap(toggle);
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(repository.writes, 1);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('save-permission-template')),
            )
            .onPressed,
        isNull,
      );
      await tester.pump(const Duration(seconds: 5));
      expect(repository.writes, 1);
      expect(find.textContaining('请求结果尚未确认'), findsWidgets);
    },
  );

  testWidgets('identity change cancels a pending template autosave', (
    tester,
  ) async {
    final repository = _Repository();
    final container = await _mount(
      tester,
      repository,
      const AdminPermissionTemplatesView(navigation: SizedBox()),
    );
    await tester.tap(find.text('采购模板'));
    await tester.pumpAndSettle();
    await _expandCatalog(tester);
    await tester.tap(find.byKey(const ValueKey('template-code-goods:view')));
    await tester.pump(const Duration(milliseconds: 200));
    container.read(_identity.notifier).state = 'other-admin';
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(repository.writes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejected autosave keeps local edits for an explicit retry', (
    tester,
  ) async {
    final repository = _Repository()
      ..saveError = ApiException(
        'VALIDATION_FAILED',
        '请补齐所需查看权限',
        httpStatus: 400,
      );
    await _mount(
      tester,
      repository,
      const AdminPermissionTemplatesView(navigation: SizedBox()),
    );
    await tester.tap(find.text('采购模板'));
    await tester.pumpAndSettle();
    await _expandCatalog(tester);
    final toggle = find.byKey(const ValueKey('template-code-goods:view'));
    await tester.tap(toggle);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(repository.writes, 1);
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(find.textContaining('请补齐所需查看权限'), findsWidgets);
    await tester.pump(const Duration(seconds: 5));
    expect(repository.writes, 1);
    repository.saveError = null;
    await tester.tap(find.byKey(const ValueKey('save-permission-template')));
    await tester.pumpAndSettle();
    expect(repository.writes, 2);
    expect(repository.savedVersion, 3);
    expect(repository.savedCodes, isEmpty);
  });

  testWidgets('resizing from split view to mobile retains pending edits', (
    tester,
  ) async {
    final repository = _Repository();
    await _mount(
      tester,
      repository,
      const AdminPermissionTemplatesView(navigation: SizedBox()),
    );
    await tester.tap(find.text('采购模板'));
    await tester.pumpAndSettle();
    await _expandCatalog(tester);
    await tester.tap(find.byKey(const ValueKey('template-code-goods:view')));
    await tester.pump(const Duration(milliseconds: 200));
    tester.view.physicalSize = const Size(375, 1100);
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(repository.writes, 1);
    expect(repository.savedCodes, isEmpty);
    expect(
      find.byKey(const ValueKey('save-permission-template')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

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
      await tester.ensureVisible(find.text('替换直接设置'));
      await tester.tap(find.text('替换直接设置'));
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

Finder _field(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(TextField),
);

Future<void> _expandCatalog(WidgetTester tester) async {
  final toggle = find.byKey(const ValueKey('permission-toggle-all-groups'));
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  for (var i = 0; i < 12 && toggle.hitTestable().evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView).last, const Offset(0, -400));
    await tester.pumpAndSettle();
  }
  expect(toggle.hitTestable(), findsOneWidget);
  await tester.tap(toggle);
  await tester.pumpAndSettle();
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
  List<AdminPermission>? catalogPermissions,
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
            permissions:
                catalogPermissions ??
                [
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
          debugShowCheckedModeBanner: false,
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
  var template = PermissionTemplate(
    id: 'template',
    name: '采购模板',
    description: List.filled(12, '采购岗位可复用的操作权限。').join(),
    permissions: ['goods:view'],
    version: 3,
  );
  int writes = 0;
  String? deletedId;
  String? savedName;
  Set<String>? savedCodes;
  int? savedVersion;
  String? appliedFingerprint;
  Set<String>? appliedConfirmations;
  Object? applyError;
  Object? saveError;
  Completer<void>? nextSaveGate;
  final extraTemplates = <PermissionTemplate>[];
  bool deleted = false;
  final previewModes = <bool>[];
  final savedConfirmations = <Set<String>>[];
  @override
  Future<List<PermissionTemplate>> list() async => [
    if (!deleted) template,
    ...extraTemplates,
  ];
  @override
  Future<void> delete(PermissionTemplate template) async {
    deletedId = template.id;
    deleted = true;
    savedVersion = template.version;
    writes++;
  }

  @override
  Future<PermissionTemplate> save({
    PermissionTemplate? template,
    required String name,
    required String description,
    required Set<String> permissions,
  }) async {
    writes++;
    savedName = name;
    savedCodes = {...permissions};
    savedVersion = template?.version;
    final gate = nextSaveGate;
    nextSaveGate = null;
    if (gate != null) await gate.future;
    if (saveError != null) throw saveError!;
    final saved = PermissionTemplate(
      id: template?.id ?? 'created-${extraTemplates.length}',
      name: name.trim(),
      description: description.trim(),
      permissions: permissions.toList()..sort(),
      version: (template?.version ?? 0) + 1,
    );
    if (saved.id == this.template.id) {
      this.template = saved;
    } else {
      extraTemplates.removeWhere((item) => item.id == saved.id);
      extraTemplates.add(saved);
    }
    return saved;
  }

  @override
  Future<PermissionTemplate> saveReviewed({
    PermissionTemplate? template,
    required String name,
    required String description,
    required Set<String> permissions,
    Set<String> sensitiveConfirmations = const {},
  }) {
    savedConfirmations.add({...sensitiveConfirmations});
    return save(
      template: template,
      name: name,
      description: description,
      permissions: permissions,
    );
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
