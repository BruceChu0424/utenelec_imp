import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List originalPng;

  setUpAll(() {
    // A valid transparent image wider than the former resize limit. The
    // uncompressed PNG exceeds the old 300KB trigger without a huge bitmap.
    final image = img.Image(width: 2200, height: 40, numChannels: 4);
    image.setPixelRgba(0, 0, 17, 83, 219, 91);
    originalPng = Uint8List.fromList(img.encodePng(image, level: 0));
    expect(originalPng.length, greaterThan(300 * 1024));
  });

  setUp(() => FilePicker.platform = _SelectedFilesPicker(() async => null));
  tearDown(() => FilePicker.platform = _SelectedFilesPicker(() async => null));

  Future<ProviderContainer> pumpSection(
    WidgetTester tester,
    _RecordingAttachmentService service, {
    required String ownerType,
    required VoidCallback onChanged,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          attachmentServiceProvider.overrideWithValue(service),
          currentPermissionsProvider.overrideWithValue({Perm.attachmentUpload}),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AttachmentSection(
              ownerType: ownerType,
              ownerId: 'source-owner-id',
              attachments: const [],
              ownerCanUpload: true,
              ownerCanDelete: false,
              categories: ownerType == 'EMPLOYEE' ? const ['照片'] : null,
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(AttachmentSection)),
    );
  }

  for (final ownerType in ['EMPLOYEE', 'EMPLOYEE_CONTRACT', 'EXPENSE_CLAIM']) {
    testWidgets(
      '$ownerType uploads original image and documents without rewriting bytes',
      (tester) async {
        final pdf = Uint8List.fromList(
          '%PDF-1.7\noriginal invoice\n%%EOF'.codeUnits,
        );
        final files = [
          PlatformFile(
            name: '合同 扫描原图.PNG',
            size: originalPng.length,
            bytes: originalPng,
          ),
          PlatformFile(name: '原始发票.pdf', size: pdf.length, bytes: pdf),
        ];
        final picker = _SelectedFilesPicker(
          () async => FilePickerResult(files),
        );
        FilePicker.platform = picker;
        final service = _RecordingAttachmentService();
        var refreshes = 0;
        final container = await pumpSection(
          tester,
          service,
          ownerType: ownerType,
          onChanged: () => refreshes++,
        );

        await tester.tap(find.text('上传'));
        await tester.pumpAndSettle();

        expect(picker.allowCompression, isFalse);
        expect(picker.calls, 1);
        expect(service.uploads, hasLength(2));
        expect(service.uploads[0].bytes, same(originalPng));
        expect(service.uploads[0].fileName, '合同 扫描原图.PNG');
        expect(service.uploads[0].contentType, 'image/png');
        expect(service.uploads[1].bytes, same(pdf));
        expect(service.uploads[1].fileName, '原始发票.pdf');
        expect(service.uploads[1].contentType, 'application/pdf');
        for (final upload in service.uploads) {
          expect(upload.ownerType, ownerType);
          expect(upload.ownerId, 'source-owner-id');
          // 上传从不带分类：分类改成传完之后在文件旁边可选设置。
          expect(upload.category, isNull);
        }
        expect(refreshes, 1);
        final messages = container.read(appNotificationProvider);
        expect(messages.single.message, '已上传 2 个文件');
        expect(find.textContaining('压缩'), findsNothing);
      },
    );
  }

  testWidgets('partial success names the uploaded file and refreshes once', (
    tester,
  ) async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    FilePicker.platform = _SelectedFilesPicker(
      () async => FilePickerResult([
        PlatformFile(name: '不支持.exe', size: bytes.length, bytes: bytes),
        PlatformFile(name: '成功的发票.pdf', size: bytes.length, bytes: bytes),
      ]),
    );
    final service = _RecordingAttachmentService();
    var refreshes = 0;
    final container = await pumpSection(
      tester,
      service,
      ownerType: 'EXPENSE_CLAIM',
      onChanged: () => refreshes++,
    );

    await tester.tap(find.text('上传'));
    await tester.pumpAndSettle();

    expect(service.uploads.single.fileName, '成功的发票.pdf');
    expect(refreshes, 1);
    expect(
      container
          .read(appNotificationProvider)
          .where((message) => message.kind == AppNotificationKind.success)
          .single
          .message,
      '已上传 成功的发票.pdf',
    );
  });

  testWidgets(
    'closing the section while selecting files never starts an upload',
    (tester) async {
      final selection = Completer<FilePickerResult?>();
      final picker = _SelectedFilesPicker(() => selection.future);
      FilePicker.platform = picker;
      final service = _RecordingAttachmentService();
      var refreshes = 0;
      await pumpSection(
        tester,
        service,
        ownerType: 'EMPLOYEE',
        onChanged: () => refreshes++,
      );
      await tester.tap(find.text('上传'));
      await tester.pump();
      expect(picker.calls, 1);
      expect(
        tester
            .widget<FilledButton>(
              find.byWidgetPredicate((widget) => widget is FilledButton),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      selection.complete(
        FilePickerResult([
          PlatformFile(
            name: '照片.png',
            size: originalPng.length,
            bytes: originalPng,
          ),
        ]),
      );
      await tester.pumpAndSettle();
      expect(service.uploads, isEmpty);
      expect(refreshes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

class _SelectedFilesPicker extends FilePicker {
  _SelectedFilesPicker(this.select);
  final Future<FilePickerResult?> Function() select;
  int calls = 0;
  bool? allowCompression;

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
  }) {
    calls++;
    this.allowCompression = allowCompression;
    expect(withData, isTrue);
    expect(allowMultiple, isTrue);
    return select();
  }
}

typedef _Upload = ({
  String ownerType,
  String ownerId,
  String fileName,
  String contentType,
  Uint8List bytes,
  String? category,
});

class _RecordingAttachmentService extends AttachmentService {
  _RecordingAttachmentService() : super(ApiClient(Dio()));
  final uploads = <_Upload>[];

  @override
  Future<Attachment> upload({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    String? category,
  }) async {
    uploads.add((
      ownerType: ownerType,
      ownerId: ownerId,
      fileName: fileName,
      contentType: contentType,
      bytes: bytes,
      category: category,
    ));
    return Attachment(
      id: 'uploaded-${uploads.length}',
      ownerType: ownerType,
      ownerId: ownerId,
      storageKey: 'opaque-object-${uploads.length}',
      originalName: fileName,
      contentType: contentType,
      sizeBytes: bytes.length,
      category: category,
    );
  }
}
