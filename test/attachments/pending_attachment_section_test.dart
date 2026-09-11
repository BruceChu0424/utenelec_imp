import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_controller.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_section.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

/// 记录 flush 时每个文件带走的分类。
class _FlushService extends AttachmentService {
  _FlushService() : super(ApiClient(Dio()));
  final uploads = <(String name, String? category)>[];

  @override
  Future<Attachment> upload({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    String? category,
  }) async {
    uploads.add((fileName, category));
    return Attachment(
      id: fileName,
      ownerType: ownerType,
      ownerId: ownerId,
      storageKey: 'private/$fileName',
      originalName: fileName,
      sizeBytes: bytes.length,
      category: category,
    );
  }
}

class _Picker extends FilePicker {
  _Picker(this.files);
  final List<PlatformFile> files;
  int calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    expect(withData, isTrue, reason: '暂存需要原始字节');
    expect(allowCompression, isFalse, reason: '不得有损改写原件');
    return FilePickerResult(files);
  }
}

PlatformFile _file(String name) =>
    PlatformFile(name: name, size: 4, bytes: Uint8List.fromList([1, 2, 3, 4]));

Future<void> _pump(
  WidgetTester tester,
  PendingAttachmentController controller, {
  required Set<String> permissions,
  bool canManage = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => Stack(
          children: [
            Positioned.fill(child: child!),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppNotificationHost(),
            ),
          ],
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: BusinessAttachmentSection.draft(
              controller: controller,
              canManage: canManage,
              title: '附件（合同/客户确认/图片）',
              categories: const ['合同', '客户确认', '图片', '其他'],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  tearDown(() => FilePicker.platform = _Picker(const []));

  testWidgets('draft area is hidden without upload permission or page write', (
    tester,
  ) async {
    final controller = PendingAttachmentController();
    await _pump(tester, controller, permissions: const {Perm.attachmentView});
    expect(find.text('添加文件'), findsNothing);
    expect(find.text('附件（合同/客户确认/图片）'), findsNothing);

    await _pump(
      tester,
      controller,
      permissions: const {Perm.attachmentUpload},
      canManage: false,
    );
    expect(find.text('添加文件'), findsNothing);
  });

  testWidgets(
    'picked files are listed as pending (not uploaded) and can be removed',
    (tester) async {
      final controller = PendingAttachmentController();
      final picker = _Picker([_file('合同.pdf'), _file('木马.exe')]);
      FilePicker.platform = picker;
      await _pump(
        tester,
        controller,
        permissions: const {Perm.attachmentUpload},
      );
      expect(find.text('添加文件'), findsOneWidget);
      expect(find.textContaining('保存单据后自动上传'), findsNothing, reason: '提示语已删除');
      expect(find.textContaining('保存前可随时移除'), findsNothing);
      // 上传前不再有任何「先选分类」的芯片。
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('客户确认'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('pending-attachment-add')));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      // 「木马.exe」被类型白名单拒绝（提示走通知栈，已自动到期），只留下 PDF。
      expect(controller.items.map((i) => i.name), ['合同.pdf']);
      expect(controller.items.single.category, isNull, reason: '加入时不预设分类');
      expect(find.text('合同.pdf'), findsOneWidget);
      expect(find.textContaining('待保存后上传'), findsOneWidget);
      expect(find.text('上传'), findsNothing, reason: '暂存态没有即时上传按钮');
      expect(find.byTooltip('预览'), findsNothing);

      await tester.tap(find.byTooltip('移除'));
      await tester.pumpAndSettle();
      expect(controller.isEmpty, isTrue);
      expect(find.text('合同.pdf'), findsNothing);
    },
  );

  testWidgets('每个暂存文件旁边可选设置分类，并随 flush 一起上传', (tester) async {
    final controller = PendingAttachmentController();
    FilePicker.platform = _Picker([_file('确认.png'), _file('合同.pdf')]);
    await _pump(tester, controller, permissions: const {Perm.attachmentUpload});
    await tester.tap(find.byKey(const ValueKey('pending-attachment-add')));
    await tester.pumpAndSettle();
    expect(controller.items.map((i) => i.category), [null, null]);

    // 未设置时是安静的「＋分类」虚位，每行一个。
    expect(find.text('分类'), findsNWidgets(2));
    await tester.tap(find.text('分类').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '客户确认'));
    await tester.pumpAndSettle();
    expect(controller.items.first.category, '客户确认');
    expect(controller.items.last.category, isNull, reason: '只改被点的那一行');
    expect(find.text('分类'), findsOneWidget);

    // 再点一次可以换成别的分类，也可以清除。
    await tester.tap(find.text('客户确认'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '清除分类'));
    await tester.pumpAndSettle();
    expect(controller.items.first.category, isNull);
    expect(find.text('分类'), findsNWidgets(2));

    // 分类随文件一起进入上传契约。
    controller.setCategoryAt(1, '合同');
    final service = _FlushService();
    final report = await controller.flush(
      service,
      ownerType: 'SALES_ORDER',
      ownerId: 'order-1',
    );
    expect(report.allSucceeded, isTrue);
    expect(service.uploads, [('确认.png', null), ('合同.pdf', '合同')]);
  });

  testWidgets('加入文件的提示只说加了几个，不再重复「保存后自动上传」', (tester) async {
    final controller = PendingAttachmentController();
    FilePicker.platform = _Picker([_file('确认.png'), _file('合同.pdf')]);
    await _pump(tester, controller, permissions: const {Perm.attachmentUpload});
    final container = ProviderScope.containerOf(
      tester.element(find.byType(PendingAttachmentSection)),
    );
    await tester.tap(find.byKey(const ValueKey('pending-attachment-add')));
    await tester.pumpAndSettle();
    expect(container.read(appNotificationProvider).single.message, '已加入 2 个文件');
  });

  testWidgets('failed retry items show their error and stay removable', (
    tester,
  ) async {
    final controller = PendingAttachmentController();
    FilePicker.platform = _Picker([_file('坏.xlsx')]);
    await _pump(tester, controller, permissions: const {Perm.attachmentUpload});
    await tester.tap(find.byKey(const ValueKey('pending-attachment-add')));
    await tester.pumpAndSettle();
    controller.items.single.lastError = '扫描服务不可用';
    // ignore: invalid_use_of_protected_member
    controller.notifyListeners();
    await tester.pump();
    expect(find.textContaining('上传失败：扫描服务不可用'), findsOneWidget);
    expect(find.byTooltip('移除'), findsOneWidget);
  });
}
