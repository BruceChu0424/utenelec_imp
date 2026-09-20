import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/attachments/attachment_file_rules.dart';

void main() {
  test(
    'OFD original is uploadable and downloadable without claiming PDF preview',
    () {
      final ofd = attachmentTypeRule('电子凭证.OFD', 'application/ofd');
      expect(ofd?.contentType, 'application/ofd');
      expect(ofd?.preview, AttachmentPreviewKind.none);
      final xml = attachmentTypeRule('电子凭证.xml', 'text/xml');
      expect(xml?.contentType, 'text/xml');
      expect(xml?.preview, AttachmentPreviewKind.text);
    },
  );
}
