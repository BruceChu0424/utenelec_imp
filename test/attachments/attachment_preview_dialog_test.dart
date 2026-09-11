import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:uten_imp/shared/attachments/attachment_file_rules.dart';
import 'package:uten_imp/shared/attachments/attachment_preview_dialog.dart';

Uint8List _utf8(String value) => Uint8List.fromList(utf8.encode(value));

Future<void> _pumpPreview(
  WidgetTester tester, {
  required Uint8List bytes,
  required String name,
  String? contentType,
  Size size = const Size(900, 700),
  double textScale = 1.0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: AttachmentPreviewDialog(
            bytes: bytes,
            name: name,
            contentType: contentType,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('能力矩阵（列表图标、提示与弹窗同源）', () {
    test('上传白名单覆盖办公常见类型', () {
      const expected = {
        'jpg': 'image/jpeg',
        'png': 'image/png',
        'tiff': 'image/tiff',
        'heic': 'image/heic',
        'svg': 'image/svg+xml',
        'pdf': 'application/pdf',
        'doc': 'application/msword',
        'rtf': 'application/rtf',
        'odt': 'application/vnd.oasis.opendocument.text',
        'xls': 'application/vnd.ms-excel',
        'ods': 'application/vnd.oasis.opendocument.spreadsheet',
        'ppt': 'application/vnd.ms-powerpoint',
        'pptx':
            'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'odp': 'application/vnd.oasis.opendocument.presentation',
        'csv': 'text/csv',
        'md': 'text/markdown',
        'log': 'text/plain',
        'json': 'application/json',
        'xml': 'text/xml',
        'zip': 'application/zip',
        '7z': 'application/x-7z-compressed',
        'rar': 'application/vnd.rar',
      };
      expected.forEach((extension, contentType) {
        expect(
          guessAttachmentContentType('文件.$extension'),
          contentType,
          reason: '$extension 应可上传',
        );
      });
      expect(guessAttachmentContentType('木马.exe'), isNull);
      expect(guessAttachmentContentType('无扩展名'), isNull);
      expect(
        guessAttachmentContentType('报价.PPTX'),
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        reason: '扩展名大小写不敏感',
      );
    });

    test('每种类型落在唯一的预览通道上', () {
      expect(
        attachmentPreviewKind('照片.png', 'image/png'),
        AttachmentPreviewKind.image,
      );
      expect(attachmentPreviewKind('合同.pdf', null), AttachmentPreviewKind.pdf);
      expect(attachmentPreviewKind('说明.md', null), AttachmentPreviewKind.text);
      expect(attachmentPreviewKind('导出.csv', null), AttachmentPreviewKind.csv);
      expect(
        attachmentPreviewKind('附件.zip', null),
        AttachmentPreviewKind.archive,
      );
      for (final name in ['报价.docx', '方案.pptx', '台账.ods', '说明.rtf', '图标.svg']) {
        expect(
          attachmentPreviewKind(name, null),
          AttachmentPreviewKind.serverPdf,
          reason: '$name 需服务端转换',
        );
      }
      for (final name in ['扫描件.tiff', '照片.heic', '资料.7z', '资料.rar', '未知.bin']) {
        expect(
          attachmentPreviewKind(name, null),
          AttachmentPreviewKind.none,
          reason: '$name 不承诺预览',
        );
      }
    });

    test('三张表是包含关系：服务端转换 ⊂ 可预览 ⊂ 可上传', () {
      const all = [
        'jpg', 'png', 'webp', 'gif', 'bmp', 'tif', 'tiff', 'heic', 'heif', //
        'svg', 'pdf', 'doc', 'docx', 'rtf', 'odt', 'xls', 'xlsx', 'ods',
        'csv', 'ppt', 'pptx', 'odp', 'txt', 'log', 'md', 'json', 'xml',
        'zip', '7z', 'rar',
      ];
      for (final extension in all) {
        final name = '文件.$extension';
        expect(
          guessAttachmentContentType(name),
          isNotNull,
          reason: '$extension 必须可上传',
        );
        if (AttachmentPreviewDialog.isOffice(name, null)) {
          expect(
            AttachmentPreviewDialog.canPreview(name, null),
            isTrue,
            reason: '$extension 能转换就必然可预览',
          );
        }
      }
    });

    test('Content-Type 能兜底判定（历史附件没有扩展名）', () {
      expect(
        AttachmentPreviewDialog.isOffice('无扩展名', 'application/msword'),
        isTrue,
      );
      expect(
        AttachmentPreviewDialog.canPreview('无扩展名', 'application/pdf'),
        isTrue,
      );
      expect(AttachmentPreviewDialog.canPreview('无扩展名', 'text/plain'), isTrue);
      expect(
        AttachmentPreviewDialog.canPreview('无扩展名', 'application/octet-stream'),
        isFalse,
      );
    });

    test('只有能解码的位图才算「图片」（头像选择据此）', () {
      expect(isRenderableImageAttachment('照片.png', 'image/png'), isTrue);
      expect(isRenderableImageAttachment('扫描件.tiff', 'image/tiff'), isFalse);
      expect(isRenderableImageAttachment('图标.svg', 'image/svg+xml'), isFalse);
    });
  });

  group('预览分支', () {
    testWidgets('文本：UTF-8 中文原样显示，编码写在副标题上', (tester) async {
      await _pumpPreview(
        tester,
        bytes: _utf8('客户确认：同意 2026-09-10 发货'),
        name: '客户确认.txt',
        contentType: 'text/plain',
      );
      expect(find.text('客户确认.txt'), findsOneWidget);
      expect(find.text('客户确认：同意 2026-09-10 发货'), findsOneWidget);
      expect(find.text('UTF-8'), findsOneWidget);
      expect(find.text('TXT'), findsOneWidget);
    });

    testWidgets('文本：GBK 老文件不再是乱码', (tester) async {
      await _pumpPreview(
        tester,
        bytes: Uint8List.fromList([0xD6, 0xD0, 0xCE, 0xC4]),
        name: '老系统导出.txt',
        contentType: 'text/plain',
      );
      expect(find.text('中文'), findsOneWidget);
      expect(find.text('GB18030'), findsOneWidget);
    });

    testWidgets('CSV：排成表格，而不是一堵逗号墙', (tester) async {
      await _pumpPreview(
        tester,
        bytes: _utf8('姓名,部门,金额\n张三,生产部,1200.50\n李四,财务部,880.00\n'),
        name: '工资表.csv',
        contentType: 'text/csv',
      );
      expect(find.text('姓名'), findsOneWidget);
      expect(find.text('生产部'), findsOneWidget);
      expect(find.text('880.00'), findsOneWidget);
      expect(find.textContaining('3 行'), findsOneWidget);
      expect(find.textContaining('3 列'), findsOneWidget);
    });

    testWidgets('压缩包：列条目，不解压', (tester) async {
      await _pumpPreview(
        tester,
        bytes: _singleEntryZip('发票/2026.pdf', 4096),
        name: '归档.zip',
        contentType: 'application/zip',
      );
      expect(find.text('2026.pdf'), findsOneWidget);
      expect(find.text('4.0 KB'), findsOneWidget);
      expect(find.text('1 个条目'), findsOneWidget);
    });

    testWidgets('压缩包损坏：给出原因与下载指引，不装作能看', (tester) async {
      await _pumpPreview(
        tester,
        bytes: Uint8List.fromList(List.filled(64, 0x41)),
        name: '坏包.zip',
        contentType: 'application/zip',
      );
      expect(find.textContaining('ZIP'), findsWidgets);
      expect(find.textContaining('下载'), findsWidgets);
    });

    testWidgets('图片：进缩放查看器', (tester) async {
      await _pumpPreview(
        tester,
        bytes: Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
        name: '现场照片.png',
        contentType: 'image/png',
      );
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('PNG'), findsOneWidget);
    });

    testWidgets('PDF：进 PDFium 查看器（服务端转换结果也走这条）', (tester) async {
      await _pumpPreview(
        tester,
        bytes: Uint8List.fromList(utf8.encode('%PDF-1.4 minimal')),
        name: '报价.docx',
        contentType: 'application/pdf',
      );
      expect(
        find.byType(PdfViewer),
        findsOneWidget,
        reason: 'Office 转换结果用原名 + PDF 字节调用，必须走 PDF 分支',
      );
      // 内容本身不是合法 PDF，PDFium 会异步报错并由错误横幅接住，不属于用例断言范围。
      tester.takeException();
    });

    testWidgets('不支持的类型：明说 + 指向下载', (tester) async {
      await _pumpPreview(
        tester,
        bytes: Uint8List.fromList([1, 2, 3]),
        name: '照片.heic',
        contentType: 'image/heic',
      );
      expect(find.textContaining('暂不支持内嵌预览'), findsOneWidget);
      expect(find.textContaining('下载'), findsWidgets);
    });

    testWidgets('375 宽 + 1.5 倍字号不溢出', (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await _pumpPreview(
        tester,
        bytes: _utf8('姓名,部门\n张三,生产部\n'),
        name: '一个名字相当长的导出文件_202609.csv',
        contentType: 'text/csv',
        size: const Size(375, 812),
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Esc 关闭弹窗', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AttachmentPreviewDialog(
                  bytes: _utf8('内容'),
                  name: '说明.txt',
                  contentType: 'text/plain',
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('说明.txt'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('说明.txt'), findsNothing);
  });
}

/// 手搓一个只含一个条目的 stored ZIP（预览只读中央目录）。
Uint8List _singleEntryZip(String name, int size) {
  final nameBytes = utf8.encode(name);
  final out = BytesBuilder();
  void u16(int value) => out.add([value & 0xFF, (value >> 8) & 0xFF]);
  void u32(int value) => out.add([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);

  u32(0x04034b50);
  u16(20);
  u16(0x800);
  u16(0);
  u16(0);
  u16(0);
  u32(0);
  u32(size);
  u32(size);
  u16(nameBytes.length);
  u16(0);
  out.add(nameBytes);
  out.add(List<int>.filled(size, 0x41));

  final directoryOffset = out.length;
  u32(0x02014b50);
  u16(20);
  u16(20);
  u16(0x800);
  u16(0);
  u16(0);
  u16(0);
  u32(0);
  u32(size);
  u32(size);
  u16(nameBytes.length);
  u16(0);
  u16(0);
  u16(0);
  u16(0);
  u32(0);
  u32(0);
  out.add(nameBytes);
  final directorySize = out.length - directoryOffset;

  u32(0x06054b50);
  u16(0);
  u16(0);
  u16(1);
  u16(1);
  u32(directorySize);
  u32(directoryOffset);
  u16(0);
  return out.toBytes();
}
