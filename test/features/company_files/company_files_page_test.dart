import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/components/layout/uten_scroll_gutter.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/features/company_files/models/company_file.dart';
import 'package:uten_imp/features/company_files/models/company_file_access_draft.dart';
import 'package:uten_imp/features/company_files/pages/company_files_page.dart';
import 'package:uten_imp/features/company_files/repositories/company_file_repository.dart';
import 'package:uten_imp/features/company_files/widgets/company_file_item.dart';
import 'package:uten_imp/features/company_files/widgets/company_file_dialogs.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/attachments/attachment_preview_dialog.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

final _api = ApiClient(Dio(BaseOptions(baseUrl: 'https://library.test/api')));
SensitiveReadBoundary _identity(String id) => SensitiveReadBoundary(
  identity: AuthenticatedScope(userId: id),
  api: _api,
  permissions: {'company_file:view'},
  superAdmin: false,
);
final _testIdentity = StateProvider<SensitiveReadBoundary>(
  (_) => _identity('A'),
);

const _actions = {
  'view',
  'download',
  'upload',
  'create',
  'edit',
  'move',
  'delete',
  'restore',
  'manage_permissions',
};
const _items = [
  CompanyFile(
    id: 'forms',
    name: '表格模板',
    kind: 'FOLDER',
    version: 1,
    allowedActions: _actions,
    description: '报销、采购及仓库常用表单',
    createdByName: '陈晓(10001)',
    updatedByName: '陈晓(10001)',
    updatedAt: '2026-10-25T04:16:00Z',
  ),
  CompanyFile(
    id: 'hr',
    name: '人事资料',
    kind: 'FOLDER',
    version: 1,
    allowedActions: _actions,
    passwordProtected: true,
    locked: true,
    updatedAt: '2026-10-24T02:30:00Z',
  ),
  CompanyFile(
    id: 'rules',
    name: '公司制度',
    kind: 'FOLDER',
    version: 1,
    allowedActions: _actions,
  ),
  CompanyFile(
    id: 'word',
    name: '公司公文模板.docx',
    kind: 'FILE',
    version: 2,
    sizeBytes: 43008,
    contentType:
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    allowedActions: _actions,
    createdByName: '李文(10008)',
    updatedByName: '李文(10008)',
    updatedAt: '2026-10-25T01:20:00Z',
  ),
  CompanyFile(
    id: 'excel',
    name: '费用报销申请表.xlsx',
    kind: 'FILE',
    version: 1,
    sizeBytes: 18124,
    contentType:
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    allowedActions: {'view', 'download'},
  ),
  CompanyFile(
    id: 'pdf',
    name: '员工手册 2026.pdf',
    kind: 'FILE',
    version: 1,
    sizeBytes: 2456120,
    contentType: 'application/pdf',
    allowedActions: {'view', 'download'},
  ),
];

CompanyFile _textEntry({
  Set<String> actions = _actions,
  bool locked = false,
  bool passwordProtected = false,
  int version = 1,
  String? parentId,
}) => CompanyFile(
  id: 'text',
  parentId: parentId,
  name: '说明.txt',
  kind: 'FILE',
  version: version,
  attachmentId: 'receipt',
  contentType: 'text/plain',
  sizeBytes: 3,
  passwordProtected: locked || passwordProtected,
  locked: locked,
  allowedActions: actions,
);

class _Repository extends CompanyFileRepository {
  _Repository() : super(_api);
  List<CompanyFile> items = _items;
  Set<String> actions = _actions;
  int calls = 0;
  Object? failure;
  Completer<CompanyFileListing>? gate;
  final parents = <String?>[];
  final queries = <({String? parentId, String search})>[];
  final orders = <List<String>>[];
  final renamed = <String>[];
  final moves = <({String id, String? parentId})>[];
  final moveVersions = <int>[];
  final reservations = <({String name, String? parentId, Object? access})>[];
  final createdFolders = <({String name, String? parentId, Object? access})>[];
  final completions = <({String id, String attachmentId})>[];
  final getIds = <String>[];
  final getOverrides = <String, CompanyFile>{};
  final accessIds = <String>[];
  final unlocked = <String>[];
  final reservationRequestIds = <String>[];
  int accessWrites = 0, passwordWrites = 0;
  Object? getFailure;
  Completer<CompanyFile>? getGate;
  final _reserved = <String, CompanyFile>{};

  @override
  Future<CompanyFile> get(String id) async {
    getIds.add(id);
    if (getGate != null) return getGate!.future;
    if (getFailure != null) throw getFailure!;
    return getOverrides[id] ??
        _reserved[id] ??
        items.firstWhere((e) => e.id == id);
  }

  @override
  Future<void> move(CompanyFile file, String? parentId) async {
    moves.add((id: file.id, parentId: parentId));
    moveVersions.add(file.version);
  }

  @override
  Future<CompanyFile> createFolder({
    String? parentId,
    required String name,
    String? description,
    String? requestId,
    Object? access,
  }) async {
    createdFolders.add((name: name, parentId: parentId, access: access));
    return CompanyFile(
      id: 'created-${createdFolders.length}',
      parentId: parentId,
      name: name,
      kind: 'FOLDER',
      version: 0,
      allowedActions: _actions,
    );
  }

  @override
  Future<CompanyFile> reserveFile({
    String? parentId,
    required String name,
    required String requestId,
    Object? access,
  }) async {
    reservations.add((name: name, parentId: parentId, access: access));
    reservationRequestIds.add(requestId);
    final entry = CompanyFile(
      id: 'reserved-${reservations.length}',
      parentId: parentId,
      name: name,
      kind: 'FILE',
      version: 0,
      pending: true,
      allowedActions: _actions,
    );
    _reserved[entry.id] = entry;
    return entry;
  }

  @override
  Future<void> saveAccess(
    String id, {
    required int version,
    required bool inheritPermissions,
    required List<CompanyFileAccessRule> rules,
  }) async {
    accessWrites++;
  }

  @override
  Future<void> setPassword(CompanyFile file, String? password) async {
    passwordWrites++;
  }

  @override
  Future<CompanyFileAccess> access(String id) async {
    accessIds.add(id);
    return const CompanyFileAccess(
      inheritPermissions: true,
      version: 1,
      rules: [],
    );
  }

  @override
  Future<void> unlock(String id, String password) async {
    expect(password, 'Synthetic-document-password!');
    unlocked.add(id);
    final entry = _textEntry(version: 2);
    getOverrides[id] = entry;
    items = [
      for (final item in items)
        if (item.id == id) entry else item,
    ];
  }

  @override
  Future<List<CompanyFilePrincipal>> principals({
    required String type,
    String search = '',
  }) async => [
    CompanyFilePrincipal(
      id: type == 'USER' ? 'person' : 'department',
      name: type == 'USER' ? '查看人(10010)' : '研发部',
      type: type,
    ),
  ];

  @override
  Future<CompanyFile> complete(CompanyFile file, String attachmentId) async {
    completions.add((id: file.id, attachmentId: attachmentId));
    final entry = CompanyFile(
      id: file.id,
      parentId: file.parentId,
      name: file.name,
      kind: file.kind,
      version: file.version + 1,
      attachmentId: attachmentId,
      allowedActions: _actions,
    );
    _reserved[entry.id] = entry;
    return entry;
  }

  @override
  Future<CompanyFile> rename(
    CompanyFile file, {
    required String name,
    required String description,
  }) async {
    renamed.add(name);
    return file;
  }

  @override
  Future<void> reorder(String? parentId, List<CompanyFile> ordered) async {
    orders.add(ordered.map((e) => e.id).toList());
  }

  @override
  Future<CompanyFileListing> list({
    String? parentId,
    String search = '',
    String sort = 'name',
    String direction = 'asc',
    bool trash = false,
    int page = 0,
    int size = 100,
  }) async {
    calls++;
    parents.add(parentId);
    queries.add((parentId: parentId, search: search));
    if (gate != null) return gate!.future;
    if (failure != null) throw failure!;
    final visible = items.where((e) => e.name.contains(search)).toList();
    return CompanyFileListing(
      entries: visible,
      total: visible.length,
      allowedActions: actions,
      canReorder: true,
      folder: parentId == null ? null : _items.first,
      breadcrumbs: parentId == null
          ? []
          : [const CompanyFileBreadcrumb(id: 'forms', name: '表格模板')],
    );
  }
}

const _captureKey = ValueKey('company-files-capture');

class _TextAttachments extends AttachmentService {
  _TextAttachments() : super(_api);
  int downloadCount = 0;
  final reads = <({String ownerType, String ownerId})>[];
  Completer<Uint8List>? downloadGate;
  @override
  Future<List<Attachment>> list({
    required String ownerType,
    required String ownerId,
  }) async {
    reads.add((ownerType: ownerType, ownerId: ownerId));
    expect(ownerType, 'COMPANY_FILE');
    expect(ownerId, 'text');
    return [
      const Attachment(
        id: 'receipt',
        ownerType: 'COMPANY_FILE',
        ownerId: 'text',
        storageKey: 'private/key',
        originalName: '说明.txt',
        contentType: 'text/plain',
        sizeBytes: 3,
      ),
    ];
  }

  @override
  Future<Uint8List> downloadBytes(Attachment attachment) async {
    downloadCount++;
    if (downloadGate != null) return downloadGate!.future;
    return Uint8List.fromList([97, 98, 99]);
  }
}

class _CopyAttachments extends _TextAttachments {
  int presignCount = 0, rawCount = 0, confirmCount = 0;
  final owners = <String>[];
  final receipts = <String, Attachment>{};

  @override
  Future<List<Attachment>> listHistory({
    required String ownerType,
    required String ownerId,
  }) async => [?receipts[ownerId]];

  @override
  Future<PresignResult> presign({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required int sizeBytes,
  }) async {
    presignCount++;
    owners.add(ownerId);
    expect(ownerType, 'COMPANY_FILE');
    expect(sizeBytes, 3);
    expect(contentType, 'text/plain');
    return PresignResult(
      storageKey: 'private/$ownerId',
      url: '/raw/$ownerId',
      method: 'PUT',
      headers: const {},
      contentType: contentType,
      formFields: const {},
      confirmToken: 'confirm-$ownerId',
    );
  }

  @override
  Future<void> uploadBytes(PresignResult upload, Uint8List bytes) async {
    rawCount++;
    expect(bytes, [97, 98, 99]);
  }

  @override
  Future<Attachment> confirm({
    required String storageKey,
    required String confirmToken,
    required String ownerType,
    required String ownerId,
    required String originalName,
    required String contentType,
    required int sizeBytes,
    String? category,
  }) async {
    confirmCount++;
    final receipt = Attachment(
      id: 'copy-$ownerId',
      ownerType: ownerType,
      ownerId: ownerId,
      storageKey: storageKey,
      originalName: originalName,
      contentType: contentType,
      sizeBytes: sizeBytes,
      sha256:
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    receipts[ownerId] = receipt;
    return receipt;
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Repository repository, {
  Size size = const Size(1440, 920),
  bool dark = false,
  double scale = 1,
  AttachmentService? attachments,
  bool pageChrome = false,
  bool inheritedPageInsets = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      companyFileRepositoryProvider.overrideWithValue(repository),
      apiClientProvider.overrideWithValue(_api),
      if (attachments != null)
        attachmentServiceProvider.overrideWithValue(attachments),
      sensitiveReadBoundaryProvider.overrideWith(
        (ref) => ref.watch(_testIdentity),
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
          theme: dark ? buildDarkTheme() : buildLightTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          scrollBehavior: pageChrome ? const UtenScrollBehavior() : null,
          builder: (context, child) => UtenContextMenuPolicy(
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: pageChrome ? UtenPageScrollbarHost(child: child!) : child!,
            ),
          ),
          home: inheritedPageInsets
              ? const UtenContentContainer(
                  selectable: false,
                  child: CompanyFilesPage(),
                )
              : const CompanyFilesPage(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['UI_CAPTURE'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('output/company-files-explorer-ui/previews');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

Finder _input(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(EditableText),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 250));
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

Future<void> _entryMenu(WidgetTester tester, String id) async {
  await tester.tapAt(
    tester.getCenter(find.byKey(ValueKey(id))),
    buttons: kSecondaryButton,
  );
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _blankMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byKey(const ValueKey('company-files-canvas'))),
    buttons: kSecondaryButton,
  );
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _copySource(WidgetTester tester) async {
  await _entryMenu(tester, 'text');
  await tester.tap(find.text('复制文件'));
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _paste(WidgetTester tester) async {
  await _blankMenu(tester);
  await tester.tap(find.text('粘贴').hitTestable());
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _confirmCopy(
  WidgetTester tester, {
  bool requireBothDialogs = true,
}) async {
  final nameDialog = find.byType(CompanyFileNameDialog);
  if (requireBothDialogs) expect(nameDialog, findsOneWidget);
  if (nameDialog.evaluate().isNotEmpty) {
    final name = find
        .descendant(of: nameDialog, matching: find.byType(EditableText))
        .first;
    await tester.enterText(name, '说明副本.txt');
    await _tap(tester, find.text('粘贴').hitTestable());
  }
  final accessDialog = find.byType(CompanyFileUploadAccessDialog);
  if (requireBothDialogs) expect(accessDialog, findsOneWidget);
  if (accessDialog.evaluate().isNotEmpty) {
    await _tap(
      tester,
      find.byKey(const ValueKey('company-initial-access-confirm')),
    );
  }
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
  testWidgets('compact main canvas owns one page end with or without shell', (
    tester,
  ) async {
    for (final inherited in [false, true]) {
      final repository = _Repository();
      await _mount(
        tester,
        repository,
        size: const Size(390, 844),
        pageChrome: true,
        inheritedPageInsets: inherited,
      );
      await tester.pumpAndSettle();
      final canvas = find.byKey(const ValueKey('company-files-canvas'));
      final rect = tester.getRect(canvas);
      final rail = tester.getRect(find.byKey(UtenPageScrollbarHost.railKey));
      expect(
        UtenContentInsetsScope.isPresentOf(tester.element(canvas)),
        isTrue,
      );
      expect(rect.right, closeTo(390 - 24, .01));
      expect(rect.left, closeTo(inherited ? 16 : 0, .01));
      expect(rail.left - rect.right, closeTo(8, .01));
      expect(rail.width, closeTo(14, .01));
      expect(rail.right, closeTo(388, .01));
      expect(repository.reservations, isEmpty);
      expect(repository.accessWrites, 0);
      expect(repository.passwordWrites, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
  for (final layout in [
    (
      name: 'desktop-light',
      size: const Size(1440, 920),
      dark: false,
      scale: 1.0,
    ),
    (name: 'mobile-light', size: const Size(390, 844), dark: false, scale: 1.0),
    (name: 'mobile-360', size: const Size(360, 800), dark: false, scale: 1.0),
    (
      name: 'desktop-dark-200',
      size: const Size(1440, 1050),
      dark: true,
      scale: 2.0,
    ),
    (
      name: 'mobile-dark-200',
      size: const Size(390, 960),
      dark: true,
      scale: 2.0,
    ),
    (
      name: 'landscape-light',
      size: const Size(844, 390),
      dark: false,
      scale: 1.0,
    ),
    (
      name: 'landscape-dark-200',
      size: const Size(844, 390),
      dark: true,
      scale: 2.0,
    ),
  ]) {
    testWidgets(
      '${layout.name} explorer has no overflow and exposes document names',
      (tester) async {
        await _mount(
          tester,
          _Repository(),
          size: layout.size,
          dark: layout.dark,
          scale: layout.scale,
        );
        expect(find.text('公司资料库'), findsWidgets);
        expect(find.text('表格模板'), findsOneWidget);
        if (layout.size.height < 500) {
          await tester.ensureVisible(find.text('表格模板'));
          await tester.pumpAndSettle();
          expect(find.text('表格模板').hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await _capture(tester, layout.name);
      },
    );
  }

  testWidgets(
    'creation actions float at the bottom and refresh belongs to the app bar',
    (tester) async {
      await _mount(tester, _Repository());
      final create = find.byKey(const ValueKey('company-files-create'));
      final upload = find.byKey(const ValueKey('company-files-upload'));
      final refresh = find.byKey(const ValueKey('company-files-refresh'));
      expect(create, findsOneWidget);
      expect(upload, findsOneWidget);
      for (final action in [create, upload]) {
        expect(
          find.ancestor(
            of: action,
            matching: find.byType(UtenFloatingActionGroup),
          ),
          findsOneWidget,
        );
        expect(tester.getCenter(action).dy, greaterThan(460));
        expect(tester.getCenter(action).dx, greaterThan(720));
      }
      expect(
        find.ancestor(of: refresh, matching: find.byType(UtenAppBar)),
        findsOneWidget,
      );
      expect(tester.getCenter(refresh).dy, lessThan(60));
      expect(find.text('新建文件夹'), findsOneWidget);
      expect(find.text('上传文件'), findsOneWidget);
    },
  );

  testWidgets(
    'search shares the explorer function row instead of a white action strip',
    (tester) async {
      await _mount(tester, _Repository());
      final search = find.byKey(const ValueKey('company-files-search'));
      final title = find.descendant(
        of: find.byType(TextButton),
        matching: find.text('公司资料库'),
      );
      expect(search, findsOneWidget);
      expect(
        (tester.getCenter(search).dy - tester.getCenter(title).dy).abs(),
        lessThan(32),
      );
      expect(
        tester.getTopLeft(search).dx,
        greaterThan(tester.getTopRight(find.byIcon(Icons.sort)).dx),
      );
      expect(tester.getBottomRight(search).dx, greaterThan(1380));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'collapsing directories retains the query controller and selected file',
    (tester) async {
      final repository = _Repository();
      await _mount(tester, repository);
      final search = find.byKey(const ValueKey('company-files-search'));
      final field = find.descendant(
        of: search,
        matching: find.byType(TextField),
      );
      final controller = tester.widget<TextField>(field).controller;
      await tester.enterText(field, '公司');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('公司公文模板.docx'));
      await tester.pump();
      final beforeCanvas = tester.getRect(
        find.byKey(const ValueKey('company-files-canvas')),
      );
      final calls = repository.calls;

      final directoryToggle = find.byKey(
        const ValueKey('company-files-toggle-directory'),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('company-files-navigation')),
          matching: directoryToggle,
        ),
        findsOneWidget,
      );
      expect(tester.getCenter(directoryToggle).dy, greaterThan(700));

      await tester.tap(
        find.byKey(const ValueKey('company-files-toggle-directory')),
      );
      await tester.pump(const Duration(milliseconds: 350));

      expect(tester.widget<TextField>(field).controller, same(controller));
      expect(controller!.text, '公司');
      expect(
        repository.calls,
        calls,
        reason: 'a layout preference must not replace the query',
      );
      final selected = tester.widget<CompanyFileItem>(
        find.ancestor(
          of: find.text('公司公文模板.docx'),
          matching: find.byType(CompanyFileItem),
        ),
      );
      expect(selected.selected, isTrue);
      expect(
        tester.getRect(find.byKey(const ValueKey('company-files-canvas'))).left,
        lessThan(beforeCanvas.left - 80),
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, 'desktop-collapsed-directory');
      await tester.tap(
        find.byKey(const ValueKey('company-files-toggle-directory')),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        tester.getRect(find.byKey(const ValueKey('company-files-canvas'))).left,
        closeTo(beforeCanvas.left, 1),
      );
      expect(tester.widget<TextField>(field).controller, same(controller));
      expect(controller.text, '公司');
    },
  );

  testWidgets('blank canvas right click offers its own permission-aware menu', (
    tester,
  ) async {
    await _mount(tester, _Repository()..items = []);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('company-files-canvas'))),
      buttons: kSecondaryButton,
    );
    await tester.pump(const Duration(milliseconds: 250));
    // The other instance is the unique floating action, not another background menu.
    expect(find.text('新建文件夹'), findsNWidgets(2));
    expect(find.text('上传文件'), findsNWidgets(2));
    expect(find.text('粘贴'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'desktop-background-menu');
  });

  testWidgets(
    'row context menu owns the pointer and does not open a background menu too',
    (tester) async {
      await _mount(tester, _Repository());
      await tester.tapAt(
        tester.getCenter(find.byType(CompanyFileItem).first),
        buttons: kSecondaryButton,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('重命名').hitTestable(), findsOneWidget);
      expect(
        find.text('新建文件夹'),
        findsOneWidget,
        reason: 'the only create label is still the floating action',
      );
      expect(find.text('上传文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final label in ['详情', '复制文件']) {
    testWidgets('a stale row menu cannot run $label after an identity change', (
      tester,
    ) async {
      final repository = _Repository()..items = [_textEntry()];
      final attachments = _CopyAttachments();
      final container = await _mount(
        tester,
        repository,
        attachments: attachments,
      );
      await _entryMenu(tester, 'text');
      expect(find.text(label).hitTestable(), findsOneWidget);
      repository.items = [];
      container.read(_testIdentity.notifier).state = _identity('B');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text(label).hitTestable());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('说明.txt'), findsNothing);
      expect(find.byType(AttachmentPreviewDialog), findsNothing);
      expect(repository.getIds, isEmpty);
      expect(repository.reservations, isEmpty);
      expect(attachments.downloadCount, 0);
      await _blankMenu(tester);
      final paste = find.text('粘贴');
      expect(
        tester
            .widget<InkWell>(
              find.ancestor(of: paste, matching: find.byType(InkWell)),
            )
            .onTap,
        isNull,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('navigation cancels a search that is still within its debounce', (
    tester,
  ) async {
    final repository = _Repository();
    await _mount(tester, repository);
    final field = find.descendant(
      of: find.byKey(const ValueKey('company-files-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '公司');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('forms')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('forms')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(repository.parents.last, 'forms');
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(repository.queries.last, (parentId: 'forms', search: ''));
    expect(repository.queries.any((query) => query.search == '公司'), false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('identity changes cancel a search within its debounce', (
    tester,
  ) async {
    final repository = _Repository();
    final container = await _mount(tester, repository);
    final field = find.descendant(
      of: find.byKey(const ValueKey('company-files-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '公司');
    await tester.pump(const Duration(milliseconds: 100));
    container.read(_testIdentity.notifier).state = _identity('B');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(repository.queries.last.search, isEmpty);
    expect(repository.queries.any((query) => query.search == '公司'), false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only capability omits creating and uploading', (
    tester,
  ) async {
    await _mount(tester, _Repository()..actions = {'view'});
    expect(find.text('新建文件夹'), findsNothing);
    expect(find.text('上传文件'), findsNothing);
    expect(find.byType(CompanyFileItem), findsNWidgets(6));
  });

  testWidgets('compact directories open and close without losing a search', (
    tester,
  ) async {
    final repository = _Repository();
    await _mount(tester, repository, size: const Size(360, 800));
    final field = find.descendant(
      of: find.byKey(const ValueKey('company-files-search')),
      matching: find.byType(TextField),
    );
    final controller = tester.widget<TextField>(field).controller;
    await tester.enterText(field, '公司');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(
      find.byKey(const ValueKey('company-files-toggle-directory')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('全部资料').hitTestable(), findsOneWidget);
    expect(find.text('回收站').hitTestable(), findsOneWidget);
    await _capture(tester, 'mobile-directory-open');
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.widget<TextField>(field).controller, same(controller));
    expect(controller!.text, '公司');
    expect(find.text('公司公文模板.docx'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the last narrow-screen file scrolls above floating actions', (
    tester,
  ) async {
    final repository = _Repository()
      ..items = [
        for (var i = 0; i < 24; i++)
          CompanyFile(
            id: 'file-$i',
            name: '第${i + 1}份资料.txt',
            kind: 'FILE',
            version: 1,
            allowedActions: _actions,
          ),
      ];
    await _mount(
      tester,
      repository,
      size: const Size(360, 900),
      scale: 2,
      dark: true,
    );
    final canvas = find.byKey(const ValueKey('company-files-canvas'));
    final scrollable = find
        .descendant(of: canvas, matching: find.byType(Scrollable))
        .last;
    await tester.scrollUntilVisible(
      find.text('第24份资料.txt'),
      500,
      scrollable: scrollable,
    );
    await tester.drag(scrollable, const Offset(0, -1500));
    await tester.pump(const Duration(milliseconds: 350));
    final last = find.byKey(const ValueKey('file-23'));
    final group = find.byType(UtenFloatingActionGroup);
    expect(last.hitTestable(), findsOneWidget);
    expect(
      tester.getBottomRight(last).dy,
      lessThan(tester.getTopLeft(group).dy),
    );
    expect(tester.takeException(), isNull);
    await _capture(tester, 'mobile-360-dark-200-last-row');
  });

  testWidgets(
    'a created folder sends people department and password in the first command',
    (tester) async {
      final repository = _Repository();
      await _mount(tester, repository);
      await _tap(tester, find.byKey(const ValueKey('company-files-create')));
      expect(find.byType(CompanyFileCreateFolderDialog), findsOneWidget);
      await tester.enterText(_input('company-folder-name'), '受限模板');
      await _tap(tester, find.byKey(const Key('initial-access-specific')));
      await _tap(tester, find.byKey(const Key('initial-access-add-allow')));
      await _tap(tester, find.text('查看人(10010)'));
      await _tap(tester, find.byKey(const Key('initial-access-add-allow')));
      await _tap(tester, find.text('部门'));
      await _tap(tester, find.text('研发部'));
      await _tap(
        tester,
        find.byKey(const Key('initial-access-password-switch')),
      );
      await tester.enterText(
        _input('initial-access-password'),
        'Synthetic-initial-password!',
      );
      await tester.enterText(
        _input('initial-access-password-repeat'),
        'Synthetic-initial-password!',
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('company-initial-access-confirm')),
      );

      expect(repository.createdFolders, hasLength(1));
      final command = repository.createdFolders.single;
      expect(command.name, '受限模板');
      final access = command.access! as CompanyFileInitialAccessDraft;
      expect(access.inheritPermissions, false);
      expect(access.rules.map((rule) => rule.subjectType), [
        'USER',
        'DEPARTMENT',
      ]);
      expect(access.rules.map((rule) => rule.subjectId), [
        'person',
        'department',
      ]);
      for (final rule in access.rules) {
        expect(rule.actions, {'view', 'download'});
      }
      expect(access.password, 'Synthetic-initial-password!');
      expect(repository.accessWrites, 0);
      expect(repository.passwordWrites, 0);
      expect(find.byType(CompanyFileCreateFolderDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('file entries expose their own access and password settings', (
    tester,
  ) async {
    final repository = _Repository()..items = [_textEntry()];
    await _mount(tester, repository);
    await _entryMenu(tester, 'text');
    expect(find.text('访问权限'), findsOneWidget);
    expect(find.text('访问密码'), findsOneWidget);
    await _tap(tester, find.text('访问权限'));
    expect(repository.accessIds, ['text']);
    expect(find.byType(CompanyFileAccessDialog), findsOneWidget);
    expect(find.text('仅影响这份文件或文件夹，不会修改系统总权限。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'copying bytes uses the normal upload protocol with independent destination access',
    (tester) async {
      final repository = _Repository()
        ..items = [_items.first, _textEntry(passwordProtected: true)];
      final attachments = _CopyAttachments();
      await _mount(tester, repository, attachments: attachments);
      await _copySource(tester);
      expect(attachments.downloadCount, 0);
      await tester.tap(find.byKey(const ValueKey('forms')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('forms')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(repository.parents.last, 'forms');
      repository.getIds.clear();
      await _paste(tester);
      await _confirmCopy(tester);

      expect(repository.getIds, contains('text'));
      expect(attachments.downloadCount, 1);
      expect(attachments.reads, [(ownerType: 'COMPANY_FILE', ownerId: 'text')]);
      expect(repository.reservations, hasLength(1));
      expect(repository.reservations.single.parentId, 'forms');
      expect(repository.reservations.single.name, '说明副本.txt');
      final access =
          repository.reservations.single.access!
              as CompanyFileInitialAccessDraft;
      expect(access.inheritPermissions, true);
      expect(access.password, isNull);
      expect(attachments.owners, ['reserved-1']);
      expect(attachments.rawCount, 1);
      expect(attachments.confirmCount, 1);
      expect(repository.completions, [
        (id: 'reserved-1', attachmentId: 'copy-reserved-1'),
      ]);
      expect(repository.moves, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('paste rechecks source access before reading private content', (
    tester,
  ) async {
    final repository = _Repository()..items = [_textEntry()];
    final attachments = _CopyAttachments();
    await _mount(tester, repository, attachments: attachments);
    await _copySource(tester);
    repository.getIds.clear();
    repository.getOverrides['text'] = _textEntry(actions: {'view'}, version: 2);
    await _paste(tester);
    await _confirmCopy(tester, requireBothDialogs: false);
    expect(repository.getIds, contains('text'));
    expect(attachments.downloadCount, 0);
    expect(attachments.reads, isEmpty);
    expect(attachments.rawCount, 0);
    expect(repository.reservations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('identity change fences a late source lookup before copying', (
    tester,
  ) async {
    final repository = _Repository()..items = [_textEntry()];
    final attachments = _CopyAttachments();
    final container = await _mount(
      tester,
      repository,
      attachments: attachments,
    );
    await _copySource(tester);
    repository.getGate = Completer<CompanyFile>();
    await _paste(tester);
    await _confirmCopy(tester, requireBothDialogs: false);
    expect(repository.getIds, contains('text'));
    container.read(_testIdentity.notifier).state = _identity('B');
    await tester.pump();
    repository.getGate!.complete(_textEntry());
    await tester.pump(const Duration(milliseconds: 350));
    expect(attachments.downloadCount, 0);
    expect(repository.reservations, isEmpty);
    expect(find.byType(CompanyFileUploadAccessDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an A B A identity change rejects a late private copy read', (
    tester,
  ) async {
    final repository = _Repository()..items = [_textEntry()];
    final attachments = _CopyAttachments()
      ..downloadGate = Completer<Uint8List>();
    final container = await _mount(
      tester,
      repository,
      attachments: attachments,
    );
    await _copySource(tester);
    await _paste(tester);
    await _confirmCopy(tester);
    expect(attachments.downloadCount, 1);
    expect(repository.reservations, isEmpty);
    container.read(_testIdentity.notifier).state = _identity('B');
    await tester.pump();
    container.read(_testIdentity.notifier).state = _identity('A');
    await tester.pump();
    attachments.downloadGate!.complete(Uint8List.fromList([97, 98, 99]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.reservations, isEmpty);
    expect(repository.completions, isEmpty);
    expect(attachments.rawCount, 0);
    expect(find.byType(CompanyFileUploadAccessDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final change in ['identity', 'permissions', 'server']) {
    testWidgets('a $change boundary clears the private clipboard', (
      tester,
    ) async {
      final repository = _Repository()..items = [_textEntry()];
      final attachments = _CopyAttachments();
      final container = await _mount(
        tester,
        repository,
        attachments: attachments,
      );
      await _copySource(tester);
      final before = container.read(_testIdentity);
      container.read(_testIdentity.notifier).state = SensitiveReadBoundary(
        identity: change == 'identity'
            ? const AuthenticatedScope(userId: 'B')
            : before.identity,
        api: change == 'server'
            ? ApiClient(Dio(BaseOptions(baseUrl: 'https://other.test/api')))
            : before.api,
        permissions: change == 'permissions' ? {} : before.permissions,
        superAdmin: false,
      );
      await tester.pump(const Duration(milliseconds: 350));
      repository.getIds.clear();
      await _blankMenu(tester);
      final paste = find.text('粘贴');
      final ink = find.ancestor(of: paste, matching: find.byType(InkWell));
      expect(paste, findsOneWidget);
      expect(tester.widget<InkWell>(ink).onTap, isNull);
      await tester.tap(paste);
      await tester.pump(const Duration(milliseconds: 250));
      expect(repository.getIds, isEmpty);
      expect(repository.reservations, isEmpty);
      expect(attachments.downloadCount, 0);
      expect(find.byType(CompanyFileNameDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a destination without upload permission cannot accept a copy', (
    tester,
  ) async {
    final repository = _Repository()..items = [_textEntry()];
    final attachments = _CopyAttachments();
    await _mount(tester, repository, attachments: attachments);
    await _copySource(tester);
    repository.actions = {'view'};
    await tester.tap(find.byKey(const ValueKey('company-files-refresh')));
    await tester.pump(const Duration(milliseconds: 350));
    await _blankMenu(tester);
    final paste = find.text('粘贴');
    expect(
      tester
          .widget<InkWell>(
            find.ancestor(of: paste, matching: find.byType(InkWell)),
          )
          .onTap,
      isNull,
    );
    await tester.tap(paste);
    await tester.pump(const Duration(milliseconds: 250));
    expect(repository.reservations, isEmpty);
    expect(attachments.downloadCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cut and paste moves an existing folder with no upload', (
    tester,
  ) async {
    final repository = _Repository()..items = [_items[0], _items[2]];
    final attachments = _CopyAttachments();
    await _mount(tester, repository, attachments: attachments);
    await _entryMenu(tester, 'rules');
    expect(find.text('复制文件'), findsNothing);
    await _tap(tester, find.text('剪切'));
    await tester.tap(find.byKey(const ValueKey('forms')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('forms')));
    await tester.pump(const Duration(milliseconds: 350));
    repository.getOverrides['rules'] = const CompanyFile(
      id: 'rules',
      name: '公司制度',
      kind: 'FOLDER',
      version: 9,
      allowedActions: _actions,
    );
    await _paste(tester);
    expect(repository.getIds, contains('rules'));
    expect(repository.moves, [(id: 'rules', parentId: 'forms')]);
    expect(repository.moveVersions, [9]);
    expect(repository.reservations, isEmpty);
    expect(attachments.downloadCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a password protected file unlocks before its content is previewed',
    (tester) async {
      final repository = _Repository()..items = [_textEntry(locked: true)];
      final attachments = _TextAttachments();
      await _mount(tester, repository, attachments: attachments);
      final card = find.byType(CompanyFileItem);
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(CompanyFilePasswordDialog), findsOneWidget);
      expect(find.byType(AttachmentPreviewDialog), findsNothing);
      expect(attachments.downloadCount, 0);
      await tester.enterText(
        find.descendant(
          of: find.byType(CompanyFilePasswordDialog),
          matching: find.byType(EditableText),
        ),
        'Synthetic-document-password!',
      );
      await _tap(
        tester,
        find.descendant(
          of: find.byType(CompanyFilePasswordDialog),
          matching: find.byType(UtenButton),
        ),
      );
      expect(repository.unlocked, ['text']);
      expect(find.byType(AttachmentPreviewDialog), findsOneWidget);
      expect(attachments.downloadCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact folder tap navigates and preserves UUID', (
    tester,
  ) async {
    final repository = _Repository();
    await _mount(tester, repository, size: const Size(390, 844));
    await tester.tap(find.text('表格模板'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.parents.last, 'forms');
  });

  testWidgets('more menu exposes allowed actions without navigating', (
    tester,
  ) async {
    final repository = _Repository();
    await _mount(tester, repository, size: const Size(390, 844));
    final first = find.byType(CompanyFileItem).first;
    await tester.tap(
      find.descendant(
        of: first,
        matching: find.byIcon(Icons.more_horiz_rounded),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.calls, 1);
    expect(find.text('访问权限'), findsOneWidget);
    expect(find.text('移到回收站'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('error state offers retry and recovers without stale items', (
    tester,
  ) async {
    final repository = _Repository()
      ..failure = ApiException('BUSINESS', '服务器容量检查失败', httpStatus: 400);
    await _mount(tester, repository);
    expect(find.text('服务器容量检查失败'), findsOneWidget);
    repository.failure = null;
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(find.text('表格模板'), findsOneWidget);
  });

  testWidgets(
    'identity change clears private rows and rejects an old response',
    (tester) async {
      final repository = _Repository();
      final container = await _mount(tester, repository);
      repository.gate = Completer<CompanyFileListing>();
      await tester.tap(find.byKey(const ValueKey('company-files-refresh')));
      await tester.pump();
      container.read(_testIdentity.notifier).state = _identity('B');
      await tester.pump();
      expect(find.text('公司公文模板.docx'), findsNothing);
      repository.gate!.complete(const CompanyFileListing());
      await tester.pump();
      expect(find.text('公司公文模板.docx'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a modal editor is hidden on identity change', (tester) async {
    final repository = _Repository();
    final container = await _mount(tester, repository);
    await tester.tap(find.text('新建文件夹'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('名称'), findsOneWidget);
    container.read(_testIdentity.notifier).state = _identity('B');
    await tester.pump();
    expect(find.text('访问权限已变化，请刷新后重试'), findsOneWidget);
    expect(find.text('名称'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('details view reflows at narrow widths', (tester) async {
    await _mount(tester, _Repository(), size: const Size(390, 844));
    await tester.tap(find.byIcon(Icons.grid_view_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.text('公司公文模板.docx'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'mobile-details');
  });

  testWidgets('desktop tile and details views expose the same documents', (
    tester,
  ) async {
    await _mount(tester, _Repository());
    await tester.tap(find.byIcon(Icons.grid_view_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('平铺'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, 'desktop-tiles');
    await tester.tap(find.byIcon(Icons.view_agenda_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.text('公司公文模板.docx'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'desktop-details');
  });

  testWidgets('deleted password folder retains an unlock action', (
    tester,
  ) async {
    final repository = _Repository()
      ..items = [
        const CompanyFile(
          id: 'deleted',
          name: '已删受保护目录',
          kind: 'FOLDER',
          version: 2,
          deleted: true,
          passwordProtected: true,
          locked: true,
          allowedActions: {'view', 'restore'},
        ),
      ];
    await _mount(tester, repository);
    await tester.tap(find.text('回收站'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('解锁'), findsOneWidget);
    expect(find.text('还原'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop right-click works under the shared context-menu policy',
    (tester) async {
      await _mount(tester, _Repository());
      await tester.tapAt(
        tester.getCenter(find.byType(CompanyFileItem).first),
        buttons: kSecondaryButton,
      );
      await tester.pump();
      expect(find.text('访问权限'), findsOneWidget);
      expect(find.text('移到回收站'), findsOneWidget);
    },
  );

  testWidgets(
    'manual dragging a folder onto another folder reorders their positions',
    (tester) async {
      final repository = _Repository()..items = [_items[0], _items[2]];
      await _mount(tester, repository);
      await tester.tap(find.byIcon(Icons.sort));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动排序'));
      await tester.pumpAndSettle();
      final source = tester.getCenter(find.byKey(const ValueKey('forms')));
      final target = tester.getCenter(find.byKey(const ValueKey('rules')));
      final gesture = await tester.startGesture(source);
      await tester.pump(const Duration(milliseconds: 650));
      await gesture.moveTo(target);
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 350));
      expect(repository.orders, [
        ['rules', 'forms'],
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'file renaming rejects another extension and accepts a new basename',
    (tester) async {
      final repository = _Repository()..items = [_items[3]];
      await _mount(tester, repository);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('重命名'));
      await tester.pump(const Duration(milliseconds: 350));
      final field = find
          .descendant(
            of: find.byType(CompanyFileNameDialog),
            matching: find.byType(TextField),
          )
          .first;
      await tester.enterText(field, '危险.cmd');
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(repository.renamed, isEmpty);
      expect(find.byType(CompanyFileNameDialog), findsOneWidget);
      await tester.enterText(field, '新版公司公文模板.DOCX');
      await tester.tap(find.text('保存'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(repository.renamed, ['新版公司公文模板.DOCX']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing an original preview revalidates the retained folder', (
    tester,
  ) async {
    final repository = _Repository()
      ..items = [
        const CompanyFile(
          id: 'text',
          name: '说明.txt',
          kind: 'FILE',
          version: 1,
          attachmentId: 'receipt',
          contentType: 'text/plain',
          sizeBytes: 3,
          allowedActions: {'view', 'download'},
        ),
      ];
    await _mount(tester, repository, attachments: _TextAttachments());
    final card = find.byType(CompanyFileItem);
    await tester.tap(card);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(card);
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(AttachmentPreviewDialog), findsOneWidget);
    final before = repository.calls;
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump(const Duration(milliseconds: 350));
    expect(repository.calls, before + 1);
    expect(find.byType(AttachmentPreviewDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
