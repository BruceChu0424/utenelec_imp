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
import 'package:uten_imp/features/company_files/models/company_file.dart';
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

class _Repository extends CompanyFileRepository {
  _Repository() : super(_api);
  List<CompanyFile> items = _items;
  Set<String> actions = _actions;
  int calls = 0;
  Object? failure;
  Completer<CompanyFileListing>? gate;
  final parents = <String?>[];
  final orders = <List<String>>[];
  final renamed = <String>[];
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
  @override
  Future<List<Attachment>> list({
    required String ownerType,
    required String ownerId,
  }) async => [
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
  @override
  Future<Uint8List> downloadBytes(Attachment attachment) async =>
      Uint8List.fromList([97, 98, 99]);
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Repository repository, {
  Size size = const Size(1440, 920),
  bool dark = false,
  double scale = 1,
  AttachmentService? attachments,
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
      child: MaterialApp(
        theme: dark ? buildDarkTheme() : buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => UtenContextMenuPolicy(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
        ),
        home: const RepaintBoundary(
          key: _captureKey,
          child: CompanyFilesPage(),
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
    final directory = Directory('output/company-files/previews');
    await directory.create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
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
  for (final layout in [
    (
      name: 'desktop-light',
      size: const Size(1440, 920),
      dark: false,
      scale: 1.0,
    ),
    (name: 'mobile-light', size: const Size(390, 844), dark: false, scale: 1.0),
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

  testWidgets('read-only capability omits creating and uploading', (
    tester,
  ) async {
    await _mount(tester, _Repository()..actions = {'view'});
    expect(find.text('新建文件夹'), findsNothing);
    expect(find.text('上传文件'), findsNothing);
    expect(find.byType(CompanyFileItem), findsNWidgets(6));
  });

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
    expect(find.text('文件夹权限'), findsOneWidget);
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
      await tester.tap(find.text('刷新'));
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
      expect(find.text('文件夹权限'), findsOneWidget);
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
