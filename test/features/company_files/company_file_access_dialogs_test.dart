import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/components/feedback/uten_dialog_modules.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/models/department_node.dart';
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
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/company_files/models/company_file.dart';
import 'package:uten_imp/features/company_files/models/company_file_access_draft.dart';
import 'package:uten_imp/features/company_files/repositories/company_file_repository.dart';
import 'package:uten_imp/features/company_files/widgets/company_file_dialogs.dart';
import 'package:uten_imp/features/company_files/widgets/company_file_access_editor.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker_models.dart';
import 'package:uten_imp/shared/attachments/attachment_file_rules.dart';
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
  Future<List<DepartmentNode>> principalDepartments() async => [
    DepartmentNode(
      id: 'hr',
      code: 'DEPT_TEST',
      name: '人事部',
      level: '一级部门',
      children: [],
    ),
  ];

  @override
  Future<PagedResult<CompanyFilePrincipal>> principalsPage({
    required String type,
    String search = '',
    int page = 1,
    int size = 100,
    String? departmentId,
    bool includeSubtree = false,
  }) async => PagedResult(
    items: type == 'USER'
        ? [const CompanyFilePrincipal(id: 'alice', name: '张明', type: 'USER')]
        : [
            const CompanyFilePrincipal(
              id: 'hr',
              name: '人事部',
              type: 'DEPARTMENT',
            ),
          ],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );
}

class _PagedPrincipals extends _Repository {
  final pages = <int>[];
  Completer<PagedResult<CompanyFilePrincipal>>? continuation;
  static PagedResult<CompanyFilePrincipal> response(int page) => PagedResult(
    items: [
      for (var i = (page - 1) * 100; i < (page == 1 ? 100 : 101); i++)
        CompanyFilePrincipal(
          id: 'account-$i',
          name: '资料账号$i',
          type: 'USER',
          detail: '人事部',
          departmentId: 'hr',
        ),
    ],
    page: page,
    size: 100,
    total: 101,
    totalPages: 2,
  );
  @override
  Future<PagedResult<CompanyFilePrincipal>> principalsPage({
    required String type,
    String search = '',
    int page = 1,
    int size = 100,
    String? departmentId,
    bool includeSubtree = false,
  }) async {
    pages.add(page);
    if (page == 2 && continuation != null) return continuation!.future;
    return response(page);
  }
}

class _HistoricalPrincipals extends _Repository {
  final queries = <({String? departmentId, bool includeSubtree})>[];
  @override
  Future<PagedResult<CompanyFilePrincipal>> principalsPage({
    required String type,
    String search = '',
    int page = 1,
    int size = 100,
    String? departmentId,
    bool includeSubtree = false,
  }) async {
    queries.add((departmentId: departmentId, includeSubtree: includeSubtree));
    return PagedResult(
      items: const [
        CompanyFilePrincipal(
          id: 'historical-account',
          name: '历史账号',
          type: 'USER',
          departmentId: 'historical-department',
          detail: '历史部门',
        ),
      ],
      page: page,
      size: size,
      total: 1,
      totalPages: 1,
    );
  }
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
      apiBaseUrlProvider.overrideWithValue('https://library.test/api'),
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
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  // Recompute after the inner and outer scroll views have both laid out.
  for (var attempt = 0; attempt < 2; attempt++) {
    await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
    await tester.pumpAndSettle();
  }
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

typedef _EntrySwitch =
    Future<void> Function(WidgetTester tester, _Repository repo);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'historical library department selection requests its exact UUID without a deleted-subtree seed',
    (tester) async {
      final state = await _mount(tester);
      final repository = _HistoricalPrincipals();
      final result = showCompanyFilePrincipalPicker(
        tester.element(find.byKey(const ValueKey('dialog-launcher'))),
        repository: repository,
        scope: state.scope,
        boundary: state.container.read(_identity),
      );
      await tester.pumpAndSettle();
      final departments = find.byKey(
        const Key('uten-employee-picker-departments'),
      );
      if (!tester.any(departments)) {
        await tester.tap(find.byIcon(Icons.account_tree_rounded));
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.descendant(of: departments, matching: find.text('历史部门')),
      );
      await tester.pumpAndSettle();
      expect(repository.queries.last, (
        departmentId: 'historical-department',
        includeSubtree: false,
      ));
      final row = find.byKey(
        const ValueKey('employee-picker-item-historical-account'),
      );
      expect(row, findsOneWidget);
      await tester.tap(row);
      await tester.pump();
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      await tester.pumpAndSettle();
      expect((await result)?.id, 'historical-account');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'library principal picker completes the account query and confirms the last account identity without scroll reads',
    (tester) async {
      final state = await _mount(tester);
      final repository = _PagedPrincipals();
      final result = showCompanyFilePrincipalPicker(
        tester.element(find.byKey(const ValueKey('dialog-launcher'))),
        repository: repository,
        scope: state.scope,
        boundary: state.container.read(_identity),
      );
      await tester.pumpAndSettle();
      expect(repository.pages, [1, 2]);
      final table = find.byKey(const Key('uten-employee-picker-candidates'));
      final rows = tester
          .widget<MasterDataTableView<UtenEmployeePickerItem>>(table)
          .items;
      expect(rows, hasLength(101));
      expect(rows.last.id, 'account-100');
      final last = find.byKey(
        const ValueKey('employee-picker-item-account-100'),
      );
      final scrollable = find
          .descendant(
            of: table,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .last;
      await tester.scrollUntilVisible(
        last,
        500,
        scrollable: scrollable,
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(repository.pages, [1, 2]);
      await tester.tap(last);
      await tester.pump();
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      await tester.pumpAndSettle();
      final principal = await result;
      expect(principal?.id, 'account-100');
      expect(principal?.type, 'USER');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library identity change rejects a pending principal continuation',
    (tester) async {
      final state = await _mount(tester);
      final repository = _PagedPrincipals()
        ..continuation = Completer<PagedResult<CompanyFilePrincipal>>();
      final result = showCompanyFilePrincipalPicker(
        tester.element(find.byKey(const ValueKey('dialog-launcher'))),
        repository: repository,
        scope: state.scope,
        boundary: state.container.read(_identity),
      );
      for (var frame = 0; frame < 30 && repository.pages.length < 2; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(repository.pages, [1, 2]);
      state.container.read(_identity.notifier).state = _boundary('B');
      await tester.pump();
      repository.continuation!.complete(_PagedPrincipals.response(2));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('employee-picker-item-account-100')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('uten-employee-picker-candidates')),
        findsNothing,
      );
      await tester.tap(find.byType(UtenCloseButton).last);
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(repository.pages, [1, 2]);
      expect(tester.takeException(), isNull);
    },
  );
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'))).load();
  });

  testWidgets('upload starts with folder inheritance and no everyone grant', (
    tester,
  ) async {
    final state = await _mount(tester);
    final result = _show<CompanyFileInitialAccessDraft>(
      tester,
      CompanyFileUploadAccessDialog(
        repository: _Repository(),
        scope: state.scope,
        boundary: state.container.read(_identity),
        selectedNames: const ['部门资料.pdf'],
      ),
    );
    await tester.pumpAndSettle();
    final inherited = tester.widget<UtenDialogSettingTile>(
      find.byKey(const Key('initial-access-inherit')),
    );
    expect(inherited.selected, isTrue);
    await _capture(tester, 'upload-default-inherit');
    await _tap(
      tester,
      find.byKey(const ValueKey('company-initial-access-confirm')),
    );
    final access = (await result)!;
    expect(access.inheritPermissions, isTrue);
    expect(access.rules, isEmpty);
  });

  for (final compact in [false, true]) {
    testWidgets(
      'removing a permission rule keeps other drafts isolated and cancel discards it compact=$compact',
      (tester) async {
        final state = await _mount(
          tester,
          size: compact ? const Size(390, 844) : const Size(1200, 1000),
          dark: compact,
          scale: compact ? 1.5 : 1,
        );
        final repo = _Repository()
          ..existing = const CompanyFileAccess(
            inheritPermissions: false,
            version: 4,
            rules: [
              CompanyFileAccessRule(
                subjectType: 'USER',
                subjectId: 'alice',
                subjectName: '张明',
              ),
              CompanyFileAccessRule(
                subjectType: 'DEPARTMENT',
                subjectId: 'hr',
                subjectName: '人事部',
              ),
            ],
          );
        CompanyFileAccessDialog dialog() => CompanyFileAccessDialog(
          entry: const CompanyFile(
            id: 'folder',
            name: '财务操作手册',
            kind: 'FOLDER',
            version: 4,
            allowedActions: {'view', 'manage_permissions'},
          ),
          repository: repo,
          scope: state.scope,
          boundary: state.container.read(_identity),
        );
        final result = _show<bool>(tester, dialog());
        await tester.pumpAndSettle();
        final l = AppLocalizations.of(
          tester.element(find.byType(CompanyFileAccessDialog)),
        );
        await _tap(tester, find.text('张明'));
        expect(find.byType(FilterChip).hitTestable(), findsWidgets);
        await _tap(tester, find.byTooltip(l.companyFilesRemoveRule).first);
        expect(find.byType(CompanyFileAccessDialog), findsOneWidget);
        expect(find.text('张明'), findsNothing);
        expect(find.text('人事部'), findsOneWidget);
        expect(find.byType(FilterChip).hitTestable(), findsNothing);
        expect(repo.saves, 0);
        await _tap(
          tester,
          find.widgetWithText(TextButton, l.companyFilesCancel),
        );
        expect(await result, isNull);
        expect(repo.saves, 0);
        _show<bool>(tester, dialog());
        await tester.pumpAndSettle();
        expect(find.text('张明'), findsOneWidget);
        expect(find.text('人事部'), findsOneWidget);
        await _tap(tester, find.byTooltip(l.companyFilesRemoveRule).first);
        await _tap(tester, find.text(l.companyFilesSave));
        expect(repo.savedRules!.map((rule) => rule.subjectId), ['hr']);
        expect(repo.savedRules!.single.actions, {'view', 'download'});
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'permission details collapse without losing edits compact=$compact',
      (tester) async {
        final state = await _mount(
          tester,
          size: compact ? const Size(390, 844) : const Size(1200, 1000),
          dark: compact,
          scale: compact ? 1.5 : 1,
        );
        final repo = _Repository()
          ..existing = const CompanyFileAccess(
            inheritPermissions: false,
            version: 4,
            rules: [
              CompanyFileAccessRule(
                subjectType: 'USER',
                subjectId: 'alice',
                subjectName: '张明',
              ),
              CompanyFileAccessRule(
                subjectType: 'DEPARTMENT',
                subjectId: 'hr',
                subjectName: '人事部',
              ),
            ],
          );
        _show<bool>(
          tester,
          CompanyFileAccessDialog(
            entry: const CompanyFile(
              id: 'folder',
              name: '财务操作手册',
              kind: 'FOLDER',
              version: 4,
              allowedActions: {'view', 'manage_permissions'},
            ),
            repository: repo,
            scope: state.scope,
            boundary: state.container.read(_identity),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(FilterChip).hitTestable(), findsNothing);
        await _capture(tester, 'permission-collapsed-$compact');
        await _tap(tester, find.byKey(const Key('entry-access-everyone')));
        await _tap(tester, find.byKey(const Key('entry-access-specific')));
        await _tap(tester, find.text('张明'));
        expect(find.byType(FilterChip).hitTestable(), findsWidgets);
        await _tap(tester, find.widgetWithText(FilterChip, '下载原件').first);
        await _tap(tester, find.text('张明'));
        expect(find.byType(FilterChip).hitTestable(), findsNothing);
        await _tap(tester, find.text('张明'));
        expect(
          tester
              .widget<FilterChip>(find.widgetWithText(FilterChip, '下载原件').first)
              .selected,
          isFalse,
        );
        await _capture(tester, 'permission-expanded-$compact');
        await _tap(tester, find.text('保存'));
        expect(repo.savedRules!.first.actions, {'view'});
        expect(repo.savedRules!.last.actions, {'view', 'download'});
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final layout in [
    (name: 'desktop', size: const Size(1200, 1000), scale: 1.0, dark: false),
    (name: 'mobile-200', size: const Size(360, 780), scale: 2.0, dark: true),
    (
      name: 'landscape-200',
      size: const Size(844, 390),
      scale: 2.0,
      dark: false,
    ),
  ]) {
    testWidgets(
      'upload selected-file icons fit ${layout.name} without a top hint',
      (tester) async {
        final mounted = await _mount(
          tester,
          size: layout.size,
          scale: layout.scale,
          dark: layout.dark,
        );
        final result = _show<CompanyFileInitialAccessDraft>(
          tester,
          CompanyFileUploadAccessDialog(
            repository: _Repository(),
            scope: mounted.scope,
            boundary: _boundary('A'),
            selectedNames: const [
              '公司公文模板.docx',
              '宣传图片.jpg',
              '培训演示.mp4',
              '包装结构与品牌设计原件-保留完整文件名和扩展名.cdr',
            ],
            onRemoveFile: (_) {},
            onAddFiles: () async => ['追加设计文件.step'],
          ),
        );
        await tester.pumpAndSettle();
        final fileList = find.byKey(
          const ValueKey('company-upload-selected-files'),
        );
        expect(fileList, findsOneWidget);
        final visibleKinds = tester
            .widgetList<AttachmentKindIcon>(
              find.descendant(
                of: fileList,
                matching: find.byType(AttachmentKindIcon),
              ),
            )
            .map((icon) => icon.kind);
        expect(visibleKinds, isNotEmpty);
        expect(visibleKinds.first, AttachmentFileKind.word);
        if (layout.name == 'desktop') {
          final listRect = tester.getRect(fileList);
          final lastRemove = tester.getRect(
            find.byKey(const ValueKey('company-upload-remove-3')),
          );
          expect(lastRemove.top, greaterThanOrEqualTo(listRect.top));
          expect(lastRemove.bottom, lessThanOrEqualTo(listRect.bottom));
        }
        expect(find.textContaining('支持所有格式上传'), findsNothing);
        expect(find.text('仅影响这份文件或文件夹，不会修改系统总权限。'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(tester, 'upload-selected-icons-${layout.name}');
        await _reveal(tester, fileList);
        await tester.scrollUntilVisible(
          find.text('包装结构与品牌设计原件-保留完整文件名和扩展名.cdr'),
          80,
          scrollable: find.descendant(
            of: fileList,
            matching: find.byType(Scrollable),
          ),
        );
        expect(find.text('包装结构与品牌设计原件-保留完整文件名和扩展名.cdr'), findsOneWidget);
        await _tap(
          tester,
          find.byKey(const ValueKey('company-upload-remove-3')),
        );
        expect(find.text('已选文件 (3)'), findsOneWidget);
        await _tap(
          tester,
          find.byKey(const ValueKey('company-upload-add-files')),
        );
        expect(find.text('已选文件 (4)'), findsOneWidget);
        await _tap(
          tester,
          find.byKey(const ValueKey('company-initial-access-confirm')),
        );
        expect(await result, isA<CompanyFileInitialAccessDraft>());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'upload selection removes exact rows and re-adds after empty or cancelled selection',
    (tester) async {
      final state = await _mount(tester), repo = _Repository();
      final source = ['原件一.cdr', '原件二.step', '原件三.docx'];
      final removed = <String>[];
      var additions = 0;
      final result = _show<CompanyFileInitialAccessDraft>(
        tester,
        CompanyFileUploadAccessDialog(
          repository: repo,
          scope: state.scope,
          boundary: _boundary('A'),
          selectedNames: source,
          onRemoveFile: (index) => removed.add(source.removeAt(index)),
          onAddFiles: () async {
            if (++additions == 1) return [];
            source.add('重新选择的原件.blend');
            return ['重新选择的原件.blend'];
          },
        ),
      );
      await tester.pumpAndSettle();
      final staleRemove = tester
          .widget<UtenCloseButton>(
            find.byKey(const ValueKey('company-upload-remove-2')),
          )
          .onPressed!;
      await _tap(tester, find.byKey(const ValueKey('company-upload-remove-1')));
      await Future<void>.sync(staleRemove);
      expect(source, ['原件一.cdr', '原件三.docx']);
      expect(removed, ['原件二.step']);
      await _tap(tester, find.byKey(const ValueKey('company-upload-remove-0')));
      await _tap(tester, find.byKey(const ValueKey('company-upload-remove-0')));
      expect(source, isEmpty);
      expect(find.text('尚未选择文件'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('company-initial-access-confirm')),
            )
            .onPressed,
        isNull,
      );
      await _capture(tester, 'upload-selection-empty');
      await _tap(
        tester,
        find.byKey(const ValueKey('company-upload-add-files')),
      );
      expect(find.text('尚未选择文件'), findsOneWidget);
      expect(source, isEmpty);
      await _tap(
        tester,
        find.byKey(const ValueKey('company-upload-add-files')),
      );
      expect(find.text('已选文件 (1)'), findsOneWidget);
      expect(source, ['重新选择的原件.blend']);
      expect(repo.saves, 0);
      await _tap(
        tester,
        find.byKey(const ValueKey('company-initial-access-confirm')),
      );
      expect(await result, isA<CompanyFileInitialAccessDraft>());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'adding files preserves edited ACL and password while fencing selection and dismissal',
    (tester) async {
      final state = await _mount(tester);
      final added = Completer<List<String>>();
      var removeCount = 0, addCount = 0;
      final result = _show<CompanyFileInitialAccessDraft>(
        tester,
        CompanyFileUploadAccessDialog(
          repository: _Repository(),
          scope: state.scope,
          boundary: _boundary('A'),
          selectedNames: const ['保留的原件.cdr'],
          onRemoveFile: (_) => removeCount++,
          onAddFiles: () {
            addCount++;
            return added.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('initial-access-specific')));
      await _tap(tester, find.byKey(const Key('initial-access-add-allow')));
      await _tap(
        tester,
        find.byKey(const ValueKey('employee-picker-item-alice')),
      );
      await _tap(tester, find.text('确定').hitTestable());
      await _tap(
        tester,
        find.byKey(const Key('initial-access-password-switch')),
      );
      const password = 'Synthetic-selected-password!';
      await tester.enterText(_input('initial-access-password'), password);
      await tester.enterText(
        _input('initial-access-password-repeat'),
        password,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final addButton = find.byKey(const ValueKey('company-upload-add-files'));
      await _reveal(tester, addButton);
      await tester.tap(addButton);
      await tester.pump();
      expect(addCount, 1);
      expect(tester.widget<UtenButton>(addButton).onPressed, isNull);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const ValueKey('company-initial-access-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<UtenCloseButton>(
              find.byKey(const ValueKey('company-upload-remove-0')),
            )
            .onPressed,
        isNull,
      );
      final cancel = find.widgetWithText(TextButton, '取消');
      expect(tester.widget<TextButton>(cancel).onPressed, isNull);
      final context = tester.element(addButton);
      expect(await Navigator.of(context).maybePop(), isTrue);
      await tester.pump();
      expect(find.byType(CompanyFileUploadAccessDialog), findsOneWidget);
      expect(removeCount, 0);
      added.complete(['新增的文件.docx']);
      await tester.pumpAndSettle();
      expect(find.text('已选文件 (2)'), findsOneWidget);
      expect(
        tester
            .widget<EditableText>(_input('initial-access-password'))
            .controller
            .text,
        password,
      );
      expect(
        tester
            .widget<EditableText>(_input('initial-access-password-repeat'))
            .controller
            .text,
        password,
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('company-initial-access-confirm')),
      );
      final draft = (await result)!;
      expect(draft.inheritPermissions, isFalse);
      expect(draft.password, password);
      expect(draft.rules.single.subjectId, 'alice');
      expect(draft.rules.single.actions, {'view', 'download'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed additions keep selected files and protected access drafts',
    (tester) async {
      final state = await _mount(tester);
      final access = CompanyFileInitialAccessDraft(
        inheritPermissions: false,
        rules: const [
          CompanyFileAccessRule(
            subjectType: 'DEPARTMENT',
            subjectId: 'hr',
            subjectName: '人事部',
          ),
        ],
        password: 'Synthetic-file-password!',
      );
      final result = _show<CompanyFileInitialAccessDraft>(
        tester,
        CompanyFileUploadAccessDialog(
          repository: _Repository(),
          scope: state.scope,
          boundary: _boundary('A'),
          selectedNames: const ['未丢失的原件.cdr'],
          initialAccess: access,
          onRemoveFile: (_) {},
          onAddFiles: () async => throw ApiException(
            'PICK_FAILED',
            '文件读取失败，请重新选择。',
            httpStatus: 400,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(
        tester,
        find.byKey(const ValueKey('company-upload-add-files')),
      );
      expect(
        state.container
            .read(appNotificationProvider)
            .map((notice) => notice.message),
        contains('文件读取失败，请重新选择。'),
      );
      expect(find.text('未丢失的原件.cdr'), findsOneWidget);
      expect(find.text('已选文件 (1)'), findsOneWidget);
      await _tap(
        tester,
        find.byKey(const ValueKey('company-initial-access-confirm')),
      );
      expect((await result)!.toJson(), access.toJson());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'identity A B A retires late file additions and stale remove actions',
    (tester) async {
      final state = await _mount(tester), added = Completer<List<String>>();
      var removes = 0;
      final result = _show<CompanyFileInitialAccessDraft>(
        tester,
        CompanyFileUploadAccessDialog(
          repository: _Repository(),
          scope: state.scope,
          boundary: _boundary('A'),
          selectedNames: const ['旧身份私有文件.cdr'],
          onRemoveFile: (_) => removes++,
          onAddFiles: () => added.future,
        ),
      );
      await tester.pumpAndSettle();
      final staleRemove = tester
          .widget<UtenCloseButton>(
            find.byKey(const ValueKey('company-upload-remove-0')),
          )
          .onPressed!;
      await tester.tap(find.byKey(const ValueKey('company-upload-add-files')));
      await tester.pump();
      state.container.read(_identity.notifier).state = _boundary('B');
      await tester.pump();
      state.container.read(_identity.notifier).state = _boundary('A');
      added.complete(['不应出现的晚到原件.step']);
      await Future<void>.sync(staleRemove);
      await tester.pumpAndSettle();
      expect(removes, 0);
      expect(find.text('旧身份私有文件.cdr'), findsNothing);
      expect(find.text('不应出现的晚到原件.step'), findsNothing);
      expect(
        find.byKey(const ValueKey('company-initial-access-confirm')),
        findsNothing,
      );
      expect(find.text('访问权限已变化，请刷新后重试'), findsOneWidget);
      await _tap(tester, find.byType(UtenCloseButton).last);
      expect(await result, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new folder defaults to everyone-visible draft without system actions',
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
      expect(find.byType(FilterChip).hitTestable(), findsNothing);
      expect(find.text('谁可以查看'), findsOneWidget);
      expect(find.text('所有人可以看'), findsOneWidget);
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
        'rules': <Map<String, dynamic>>[
          {
            'subjectType': 'ALL',
            'subjectId': '00000000-0000-0000-0000-000000000000',
            'effect': 'ALLOW',
            'actions': ['view', 'download'],
          },
        ],
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
      await _capture(tester, 'permission-person-selector');
      expect(
        tester.getRect(find.byKey(const Key('uten-adaptive-panel'))).right,
        1200,
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('employee-picker-item-alice')),
      );
      await _tap(tester, find.text('确定').hitTestable());
      await _tap(
        tester,
        find.byKey(const Key('initial-access-add-deny-department')),
      );
      await _capture(tester, 'permission-department-selector');
      expect(
        tester.getRect(find.byKey(const Key('uten-adaptive-panel'))).right,
        1200,
      );
      await _tap(tester, find.text('人事部'));
      await _tap(tester, find.text('确定').hitTestable());
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

  testWidgets('everyone mode keeps the marker rule with deny exceptions', (
    tester,
  ) async {
    final state = await _mount(tester);
    final result = _show<CompanyFileInitialAccessDraft>(
      tester,
      CompanyFileUploadAccessDialog(
        repository: _Repository(),
        scope: state.scope,
        boundary: state.container.read(_identity),
        selectedNames: const ['公开通知.docx'],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('所有人可以看'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('initial-access-everyone')));
    await _tap(tester, find.byKey(const Key('initial-access-add-deny')));
    await _tap(
      tester,
      find.byKey(const ValueKey('employee-picker-item-alice')),
    );
    await _tap(tester, find.text('确定').hitTestable());
    await _tap(
      tester,
      find.byKey(const ValueKey('company-initial-access-confirm')),
    );
    final draft = (await result)!;
    expect(draft.inheritPermissions, true);
    expect(draft.rules, hasLength(2));
    expect(draft.rules.first.isEveryoneRule, isTrue);
    expect(draft.rules.first.actions, {'view', 'download'});
    expect(draft.rules.last.subjectType, 'USER');
    expect(draft.rules.last.effect, 'DENY');
    expect(draft.rules.last.actions, {'view', 'download'});
  });

  testWidgets('entry access radio drives the everyone marker rule', (
    tester,
  ) async {
    final state = await _mount(tester);
    const everyoneAccess = CompanyFileAccess(
      inheritPermissions: true,
      version: 4,
      rules: [
        CompanyFileAccessRule(
          subjectType: 'ALL',
          subjectId: '00000000-0000-0000-0000-000000000000',
          subjectName: '所有人',
        ),
        CompanyFileAccessRule(
          subjectType: 'USER',
          subjectId: 'alice',
          subjectName: '张明',
          effect: 'DENY',
        ),
      ],
    );
    Future<void> openAndSave(_EntrySwitch step) async {
      final repo = _Repository()..existing = everyoneAccess;
      _show<bool>(
        tester,
        CompanyFileAccessDialog(
          entry: const CompanyFile(
            id: 'folder',
            name: '公共制度',
            kind: 'FOLDER',
            version: 4,
            allowedActions: {'view', 'manage_permissions'},
          ),
          repository: repo,
          scope: state.scope,
          boundary: state.container.read(_identity),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('所有人'), findsNothing); // ALL 规则不进规则列表
      await step(tester, repo);
    }

    await openAndSave((tester, repo) async {
      final save = find.text('保存');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(repo.savedInheritance, true);
      expect(repo.savedRules!.map((r) => r.subjectType), ['ALL', 'USER']);
      expect(repo.savedRules!.first.isEveryoneRule, isTrue);
    });
    await openAndSave((tester, repo) async {
      await _tap(tester, find.byKey(const Key('entry-access-inherit')));
      final save = find.text('保存');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(repo.savedInheritance, true);
      expect(
        repo.savedRules!.map((r) => r.subjectType),
        isNot(contains('ALL')),
      );
    });
    await openAndSave((tester, repo) async {
      await _tap(tester, find.byKey(const Key('entry-access-specific')));
      final save = find.text('保存');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(repo.savedInheritance, false);
      expect(
        repo.savedRules!.map((r) => r.subjectType),
        isNot(contains('ALL')),
      );
    });
  });

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
