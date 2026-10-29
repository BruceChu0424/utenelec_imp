import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/company_files/models/company_file_upload_rules.dart';
import 'package:uten_imp/shared/attachments/attachment_file_rules.dart';

void main() {
  test(
    'design, model and unregistered originals use the opaque library type',
    () {
      for (final name in [
        '品牌设计.CDR',
        '零件.dwg',
        '装配.step',
        '打印模型.stl',
        '场景.blend',
        '结构.sldprt',
        '项目.custom-format',
        '无扩展名原件',
      ]) {
        expect(companyFileUploadContentType(name), 'application/octet-stream');
        expect(guessAttachmentContentType(name), isNull);
        expect(canPreviewAttachment(name, 'application/octet-stream'), isFalse);
      }
    },
  );

  test('known files keep the shared upload and preview contract', () {
    for (final name in ['照片.jpg', '手册.pdf', '制度.docx', '报价.xlsx', '说明.txt']) {
      expect(
        companyFileUploadContentType(name),
        guessAttachmentContentType(name),
      );
      expect(
        canPreviewAttachment(name, companyFileUploadContentType(name)),
        isTrue,
      );
    }
  });

  test('library media support does not widen business attachment uploads', () {
    for (final entry in {
      '培训.mp4': 'video/mp4',
      '演示.m4v': 'video/mp4',
      '讲解.webm': 'video/webm',
      '相机.mov': 'video/quicktime',
      '录音.mp3': 'audio/mpeg',
      '配音.wav': 'audio/wav',
      '语音.ogg': 'audio/ogg',
      '旁白.oga': 'audio/ogg',
    }.entries) {
      expect(companyFileUploadContentType(entry.key), entry.value);
      expect(guessAttachmentContentType(entry.key), isNull);
    }
    for (final name in ['录像.mkv', '录像.avi', '音轨.flac']) {
      expect(companyFileUploadContentType(name), 'application/octet-stream');
      expect(guessAttachmentMediaContentType(name), isNull);
      expect(canPreviewAttachment(name, 'application/octet-stream'), isFalse);
    }
  });
}
