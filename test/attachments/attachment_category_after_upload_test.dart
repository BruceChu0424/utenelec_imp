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
import 'package:uten_imp/shared/attachments/attachment_category_control.dart';
import 'package:uten_imp/shared/attachments/attachment_section.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

/// 分类改成「上传之后在文件旁边可选设置」：
/// 上传本身不带分类，也没有任何决定上传归类的芯片；每个文件旁边一个安静的入口。
void main() {
  const categories = ['合同', '客户确认', '图片', '其他'];

  Attachment file(String name, {String? category}) => Attachment(
    id: name,
    ownerType: 'SALES_ORDER',
    ownerId: 'order-1',
    storageKey: 'private/$name',
    originalName: name,
    contentType: 'application/pdf',
    sizeBytes: 12,
    category: category,
  );

  Future<ProviderContainer> pump(
    WidgetTester tester,
    _Files service, {
    required List<Attachment> attachments,
    Set<String> permissions = const {
      Perm.attachmentUpload,
      Perm.attachmentDownload,
      Perm.attachmentDelete,
    },
    double textScale = 1,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          attachmentServiceProvider.overrideWithValue(service),
          currentPermissionsProvider.overrideWithValue(permissions),
          sharedPreferencesProvider.overrideWithValue(preferences),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: SingleChildScrollView(
                  child: AttachmentSection(
                    ownerType: 'SALES_ORDER',
                    ownerId: 'order-1',
                    attachments: attachments,
                    ownerCanUpload: true,
                    ownerCanDelete: true,
                    categories: categories,
                    onChanged: () {},
                  ),
                ),
              ),
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

  testWidgets('上传不问分类，界面上也没有决定上传归类的芯片', (tester) async {
    final service = _Files();
    FilePicker.platform = _Picker([
      PlatformFile(
        name: '销售合同.pdf',
        size: 6,
        bytes: Uint8List.fromList('%PDF-1'.codeUnits),
      ),
    ]);
    await pump(tester, service, attachments: [file('旧附件.pdf')]);

    expect(find.byType(ChoiceChip), findsNothing, reason: '文件太少不出筛选，更没有上传分类开关');
    for (final c in categories) {
      expect(find.text(c), findsNothing);
    }

    await tester.tap(find.text('上传'));
    await tester.pumpAndSettle();
    expect(service.uploaded, [('销售合同.pdf', null)]);
  });

  testWidgets('传完之后在文件旁边设置分类，走新的分类端点并就地生效', (tester) async {
    final service = _Files();
    await pump(tester, service, attachments: [file('销售合同.pdf')]);

    // 未设置时是「＋分类」虚位，不是必填项。
    expect(find.text('分类'), findsOneWidget);
    await tester.tap(find.text('分类'));
    await tester.pumpAndSettle();
    // 菜单给本页词表；没分类时不出「清除」。
    for (final c in categories) {
      expect(
        find.widgetWithText(CheckedPopupMenuItem<String>, c),
        findsOneWidget,
      );
    }
    expect(find.text('清除分类'), findsNothing);

    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '合同'));
    await tester.pumpAndSettle();
    expect(service.categoryCalls, [('销售合同.pdf', '合同')]);
    expect(find.text('合同'), findsOneWidget, reason: '不等整块重新加载就先就地生效');
    expect(find.text('分类'), findsNothing);
  });

  testWidgets('已设置的分类可以清除，也可以换成别的', (tester) async {
    final service = _Files();
    await pump(
      tester,
      service,
      attachments: [file('销售合同.pdf', category: '合同')],
    );

    await tester.tap(find.text('合同'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '图片'));
    await tester.pumpAndSettle();
    expect(service.categoryCalls, [('销售合同.pdf', '图片')]);

    await tester.tap(find.text('图片'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '清除分类'));
    await tester.pumpAndSettle();
    expect(service.categoryCalls.last, ('销售合同.pdf', null));
    expect(find.text('分类'), findsOneWidget);
  });

  testWidgets('保存失败时退回原值并提示，不留下假的分类', (tester) async {
    final service = _Files()..failCategory = true;
    final container = await pump(
      tester,
      service,
      attachments: [file('销售合同.pdf', category: '合同')],
    );

    await tester.tap(find.text('合同'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, '图片'));
    await tester.pumpAndSettle();
    expect(find.text('合同'), findsOneWidget);
    expect(find.text('图片'), findsNothing);
    expect(
      container.read(appNotificationProvider).single.message,
      contains('分类未能保存'),
    );
  });

  testWidgets('没有上传权限时分类只读：有分类就显示标签，没有就不占位', (tester) async {
    final service = _Files();
    await pump(
      tester,
      service,
      attachments: [
        file('合同.pdf', category: '合同'),
        file('照片.pdf'),
      ],
      permissions: const {Perm.attachmentDownload},
    );
    expect(find.text('合同'), findsOneWidget);
    expect(find.text('分类'), findsNothing);
    await tester.tap(find.text('合同'));
    await tester.pumpAndSettle();
    expect(service.categoryCalls, isEmpty);
  });

  testWidgets('375 宽 + 1.5 倍字号：不溢出，设与未设两态同高', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(
      tester,
      _Files(),
      textScale: 1.5,
      attachments: [
        file('一个名字相当长的销售合同扫描件原件.pdf', category: '合同'),
        file('另一个名字也相当长的客户确认回执.pdf'),
      ],
    );
    expect(tester.takeException(), isNull);
    final controls = find.byType(AttachmentCategoryControl);
    expect(controls, findsNWidgets(2));
    expect(
      tester.getSize(controls.at(0)).height,
      tester.getSize(controls.at(1)).height,
    );
  });

  testWidgets('文件多到看不过来才出筛选行，并且明确是「只看」', (tester) async {
    final service = _Files();
    // 三个文件、两种分类：还找得过来，不出筛选。
    await pump(
      tester,
      service,
      attachments: [
        file('a.pdf', category: '合同'),
        file('b.pdf', category: '图片'),
        file('c.pdf'),
      ],
    );
    expect(find.byType(ChoiceChip), findsNothing);

    await pump(
      tester,
      service,
      attachments: [
        file('a.pdf', category: '合同'),
        file('b.pdf', category: '图片'),
        file('c.pdf', category: '图片'),
        file('d.pdf'),
      ],
    );
    expect(find.text('只看'), findsOneWidget);
    expect(find.byIcon(Icons.filter_alt_outlined), findsOneWidget);
    // 只列用上了的分类：「客户确认」「其他」没人用，不进筛选行。
    expect(find.widgetWithText(ChoiceChip, '全部 4'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '合同 1'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '图片 2'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '客户确认'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, '图片 2'));
    await tester.pumpAndSettle();
    expect(find.text('a.pdf'), findsNothing);
    expect(find.text('b.pdf'), findsOneWidget);
    expect(find.text('c.pdf'), findsOneWidget);
    expect(service.categoryCalls, isEmpty, reason: '筛选只是查看，不改任何文件');
  });
}

class _Files extends AttachmentService {
  _Files() : super(ApiClient(Dio()));

  final uploaded = <(String name, String? category)>[];
  final categoryCalls = <(String id, String? category)>[];
  bool failCategory = false;

  @override
  Future<Attachment> upload({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    String? category,
  }) async {
    uploaded.add((fileName, category));
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

  @override
  Future<Attachment> setCategory(String id, String? category) async {
    categoryCalls.add((id, category));
    if (failCategory) throw StateError('单据已锁定');
    return Attachment(
      id: id,
      ownerType: 'SALES_ORDER',
      ownerId: 'order-1',
      storageKey: 'private/$id',
      originalName: id,
      sizeBytes: 12,
      category: category,
    );
  }
}

class _Picker extends FilePicker {
  _Picker(this.files);
  final List<PlatformFile> files;

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
  }) async => FilePickerResult(files);
}
