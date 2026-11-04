import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import '../inputs/uten_field_hint_icon.dart';

/// Preview the actual generated source-paper bytes. Geometry, pagination,
/// merges and footers belong to the source renderer, never a second UI table.
class SourcePaperPdfPreview extends StatelessWidget {
  const SourcePaperPdfPreview({
    super.key,
    required this.bytes,
    required this.filename,
  });
  final Uint8List bytes;
  final String filename;
  @override
  Widget build(BuildContext context) => PdfViewer(
    PdfDocumentRefData(bytes, sourceName: filename),
    key: const ValueKey('uten-source-paper-pdf-preview'),
    params: PdfViewerParams(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      errorBannerBuilder: (context, error, stack, document) => const Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('原件预览未打开'),
            SizedBox(width: 6),
            UtenFieldHintIcon(info: '关闭后重新预览。只显示同一份已生成PDF，不改用其他版式代替原件。'),
          ],
        ),
      ),
    ),
  );
}
