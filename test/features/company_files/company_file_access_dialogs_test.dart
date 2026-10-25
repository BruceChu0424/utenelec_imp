import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/company_files/models/company_file.dart';
import 'package:uten_imp/features/company_files/models/company_file_access_draft.dart';
import 'package:uten_imp/features/company_files/repositories/company_file_repository.dart';
import 'package:uten_imp/features/company_files/widgets/company_file_dialogs.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

final _api = ApiClient(Dio(BaseOptions(baseUrl: 'https://dialog.test/api')));
SensitiveReadBoundary _boundary(String id) => SensitiveReadBoundary(
  identity: AuthenticatedScope(userId: id),
  api: _api,
  permissions: {'company_file:view', 'company_file:create'},
  superAdmin: false,
);
final _identity = StateProvider<SensitiveReadBoundary>((_) => _boundary('A'));
const _captureKey = ValueKey('company-file-dialog-capture');

class _Repository extends CompanyFileRepository {
  _Repository() : super(_api);
  CompanyFileAccess existing = const CompanyFileAccess(
    inheritPermissions: true,
    version: 4,
    rules: [],
  );
  List<CompanyFileAccessRule>? savedRules;
  bool? savedInheritance;
  int saves = 0;
  Completer<void>? saveGate;

  @override
  Future<CompanyFileAccess> access(String id) async => existing;

  @override
  Future<void> saveAccess(
    String id, {
    required int version,
    required bool inheritPermissions,
    required List<CompanyFileAccessRule> rules,
  }) async {
    saves++;
    savedRules = rules.toList();
    savedInheritance = inheritPermissions;
    expect(version, 4);
    await saveGate?.future;
  }

  @override
  Future<List<CompanyFilePrincipal>> principals({
    required String type,
    String search = '',
  }) async => type == 'USER'
      ? [const CompanyFilePrincipal(id: 'alice', name: '张明', type: 'USER')]
      : [const CompanyFilePrincipal(id: 'hr', name: '人事部', type: 'DEPARTMENT')];
}

Future<({ProviderContainer container, AuthenticatedRequestScope scope})> _mount(
  WidgetTester tester, {
  Size size = const Size(1200, 1000),
  double scale = 1,
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      sensitiveReadBoundaryProvider.overrideWith((ref) => ref.watch(_identity)),
    ],
  );
  addTearDown(container.dispose);
  final scope = await _api.captureRequestScope(isCurrent: () => true);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: dark ? buildDarkTheme() : buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
          ),
          child: RepaintBoundary(key: _captureKey, child: child!),
        ),
        home: const Scaffold(body: SizedBox(key: ValueKey('dialog-launcher'))),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: container, scope: scope);
}

Future<T?> _show<T>(WidgetTester tester, Widget child) {
  final context = tester.element(find.byKey(const ValueKey('dialog-launcher')));
  return showDialog<T>(context: context, builder: (_) => child);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _input(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(EditableText),
);

Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['UI_CAPTURE'] != '1') return;
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final picture = await boundary.toImage();
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('output/company-files-explorer-ui/previews');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    picture.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'))).load();
  });

  testWidgets(
    'new folder returns atomic inherited draft without system actions',
    (tester) async {
      final state = await _mount(tester);
      final result = _show<CompanyFileCreateFolderDraft>(
        tester,
        CompanyFileCreateFolderDialog(
          repository: _Repository(),
          scope: state.scope,
          boundary: state.container.read(_identity),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(_input('company-folder-name'), '模板');
      expect(find.byType(FilterChip), findsNothing);
      expect(find.text('谁可以查看'), findsOneWidget);
      await _capture(tester, 'folder-create-access-desktop');
      await _tap(
        tester,
        find.byKey(const ValueKey('company-initial-access-confirm')),
      );
      final draft = await result;
      expect(draft!.name, '模板');
      expect(draft.description, isEmpty);
      expect(draft.access.toJson(), {
        'inheritPermissions': true,
        'rules': <Map<String, dynamic>>[],
        'password': null,
      });
    },
  );

  testWidgets(
    'specified people and denied department retain reading actions only',
    (tester) async {
      final state = await _mount(tester);
      final result = _show<CompanyFileInitialAccessDraft>(
        tester,
        CompanyFileUploadAccessDialog(
          repository: _Repository(),
          scope: state.scope,
          boundary: state.container.read(_identity),
          selectedNames: const ['公文.docx', '报销.xlsx'],
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('initial-access-specific')));
      await _tap(tester, find.byKey(const Key('initial-access-add-allow')));
      await _tap(tester, find.text('张明'));
      await _tap(tester, find.byKey(const Key('initial-access-add-deny')));
      await _tap(tester, find.text('部门'));
      await _tap(tester, find.text('人事部'));
      await _tap(
        tester,
        find.byKey(const ValueKey('company-initial-access-confirm')),
      );
      final draft = (await result)!;
      expect(draft.inheritPermissions, false);
      expect(draft.rules.map((r) => r.effect), ['ALLOW', 'DENY']);
      expect(draft.rules.map((r) => r.subjectType), ['USER', 'DEPARTMENT']);
      for (final rule in draft.rules) {
        expect(rule.actions, {'view', 'download'});
      }
    },
  );

  testWidgets('password requires confirmation and counts UTF-8 bytes', (
    tester,
  ) async {
    final state = await _mount(tester);
    final result = _show<CompanyFileInitialAccessDraft>(
      tester,
      CompanyFileUploadAccessDialog(
        repository: _Repository(),
        scope: state.scope,
        boundary: state.container.read(_identity),
        selectedNames: const ['保密.docx'],
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('initial-access-password-switch')));
    await tester.enterText(_input('initial-access-password'), '12345678');
    await tester.enterText(_input('initial-access-password-repeat'), 'wrong');
    await _tap(
      tester,
      find.byKey(const ValueKey('company-initial-access-confirm')),
    );
    expect(find.byTooltip('两次输入的密码不一致'), findsOneWidget);
    final long = List.filled(25, '密').join();
    await tester.enterText(_input('initial-access-password'), long);
    await tester.enterText(_input('initial-access-password-repeat'), long);
    await _tap(
      tester,
      find.byKey(const ValueKey('company-initial-access-confirm')),
    );
    expect(find.byTooltip('密码至少 8 个字符，UTF-8 长度不超过 72 字节'), findsWidgets);
    await tester.enterText(_input('initial-access-password'), '保密文件密码八个');
    await tester.enterText(
      _input('initial-access-password-repeat'),
      '保密文件密码八个',
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('company-initial-access-confirm')),
    );
    expect((await result)!.password, '保密文件密码八个');
  });

  testWidgets(
    'entry access retains mixed advanced rules and blocks double save',
    (tester) async {
      final state = await _mount(tester);
      final repo = _Repository()
        ..saveGate = Completer<void>()
        ..existing = const CompanyFileAccess(
          inheritPermissions: false,
          version: 4,
          rules: [
            CompanyFileAccessRule(
              subjectType: 'USER',
              subjectId: 'alice',
              subjectName: '张明',
              actions: {'view', 'download', 'upload', 'manage_permissions'},
            ),
            CompanyFileAccessRule(
              subjectType: 'DEPARTMENT',
              subjectId: 'hr',
              subjectName: '人事部',
              effect: 'DENY',
              actions: {'delete', 'move'},
            ),
          ],
        );
      _show<bool>(
        tester,
        CompanyFileAccessDialog(
          entry: const CompanyFile(
            id: 'file',
            name: '合同.docx',
            kind: 'FILE',
            version: 4,
            allowedActions: {'view', 'manage_permissions'},
          ),
          repository: repo,
          scope: state.scope,
          boundary: state.container.read(_identity),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('资料访问权限'), findsOneWidget);
      final save = find.text('保存');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pump();
      await tester.tap(save, warnIfMissed: false);
      await tester.pump();
      expect(repo.saves, 1);
      expect(repo.savedInheritance, false);
      expect(repo.savedRules![0].actions, {
        'view',
        'download',
        'upload',
        'manage_permissions',
      });
      expect(repo.savedRules![1].effect, 'DENY');
      expect(repo.savedRules![1].actions, {'delete', 'move'});
      repo.saveGate!.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('identity A B A invalidates drafts and nested principal picker', (
    tester,
  ) async {
    final state = await _mount(tester);
    _show<CompanyFileCreateFolderDraft>(
      tester,
      CompanyFileCreateFolderDialog(
        repository: _Repository(),
        scope: state.scope,
        boundary: state.container.read(_identity),
        initialName: '私有资料',
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byKey(const Key('initial-access-specific')));
    await _tap(tester, find.byKey(const Key('initial-access-add-allow')));
    state.container.read(_identity.notifier).state = _boundary('B');
    await tester.pump();
    state.container.read(_identity.notifier).state = _boundary('A');
    await tester.pumpAndSettle();
    expect(find.text('张明'), findsNothing);
    expect(find.text('私有资料'), findsNothing);
    expect(find.text('访问权限已变化，请刷新后重试'), findsWidgets);
  });

  testWidgets(
    'copy name dialog keeps extension and returns no source description',
    (tester) async {
      await _mount(tester);
      final result = _show<({String name, String description})>(
        tester,
        const CompanyFileNameDialog(
          entry: CompanyFile(
            id: 'source',
            name: '原稿.docx',
            description: '机密说明',
            kind: 'FILE',
            version: 1,
            allowedActions: {'view', 'download'},
          ),
          copy: true,
          initialName: '原稿 - 副本.docx',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('机密说明'), findsNothing);
      expect(find.text('粘贴文件副本'), findsOneWidget);
      await _tap(tester, find.text('粘贴'));
      expect(await result, (name: '原稿 - 副本.docx', description: ''));
    },
  );

  for (final layout in [
    (size: const Size(360, 780), scale: 2.0, dark: true),
    (size: const Size(844, 390), scale: 2.0, dark: false),
  ]) {
    testWidgets('initial access scrolls at ${layout.size}, ${layout.scale}', (
      tester,
    ) async {
      final state = await _mount(
        tester,
        size: layout.size,
        scale: layout.scale,
        dark: layout.dark,
      );
      final result = _show<CompanyFileCreateFolderDraft>(
        tester,
        CompanyFileCreateFolderDialog(
          repository: _Repository(),
          scope: state.scope,
          boundary: state.container.read(_identity),
          initialName: '新资料',
          initialAccess: CompanyFileInitialAccessDraft(
            inheritPermissions: false,
            password: '12345678',
            rules: const [
              CompanyFileAccessRule(
                subjectType: 'USER',
                subjectId: 'alice',
                subjectName: '张明',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, 'folder-create-${layout.size.width.toInt()}-200');
      await _tap(
        tester,
        find.byKey(const Key('initial-access-password-repeat')),
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('company-initial-access-confirm')),
      );
      expect((await result)!.name, '新资料');
      expect(tester.takeException(), isNull);
    });
  }
}
