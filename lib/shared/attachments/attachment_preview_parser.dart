import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, kIsWeb;

import '../../core/performance/ui_work_budget.dart';
import 'attachment_archive_listing.dart';
import 'attachment_delimited_text.dart';
import 'attachment_file_rules.dart';
import 'attachment_text_decoder.dart';

class AttachmentPreviewPayload {
  const AttachmentPreviewPayload({
    this.text,
    this.table,
    this.listing,
    this.error,
  });

  final DecodedAttachmentText? text;
  final DelimitedTable? table;
  final ArchiveListing? listing;
  final String? error;
}

/// Native large-file parsing runs in an isolate. Web uses the same parser
/// rules in bounded slices, since compute on Web does not create an isolate.
/// Only the complete result may be published, and closing the preview discards
/// late native results or stops the next Web slice.
Future<AttachmentPreviewPayload> parseAttachmentPreview(
  AttachmentPreviewKind kind,
  Uint8List bytes, {
  bool Function()? isCurrent,
}) async {
  final work = UiWorkBudget(
    isCurrent: isCurrent,
    debugLabel: 'attachment-preview',
  );
  work.ensureCurrent();
  if (kind != AttachmentPreviewKind.text &&
      kind != AttachmentPreviewKind.csv &&
      kind != AttachmentPreviewKind.archive) {
    return const AttachmentPreviewPayload();
  }
  // Small inputs have an explicit work bound and need no worker startup. A
  // large input must allow the opening frame before worker/slice preparation.
  if (bytes.length <= 32768) {
    return _parseInBackground((kind: kind, bytes: bytes));
  }
  await Future<void>.delayed(Duration.zero);
  work.ensureCurrent();
  final AttachmentPreviewPayload result;
  if (kIsWeb) {
    result = await parseAttachmentPreviewInUiSlices(kind, bytes, budget: work);
  } else {
    result = await compute(_parseInBackground, (kind: kind, bytes: bytes));
  }
  work.ensureCurrent();
  return result;
}

AttachmentPreviewPayload _parseInBackground(
  ({AttachmentPreviewKind kind, Uint8List bytes}) input,
) {
  try {
    switch (input.kind) {
      case AttachmentPreviewKind.text:
        return AttachmentPreviewPayload(
          text: decodeAttachmentText(input.bytes),
        );
      case AttachmentPreviewKind.csv:
        final decoded = decodeAttachmentText(input.bytes);
        return AttachmentPreviewPayload(
          text: decoded,
          table: parseDelimitedText(decoded.text),
        );
      case AttachmentPreviewKind.archive:
        return AttachmentPreviewPayload(listing: readZipListing(input.bytes));
      default:
        return const AttachmentPreviewPayload();
    }
  } on ArchiveListingException catch (error) {
    return AttachmentPreviewPayload(error: error.message);
  } catch (_) {
    return const AttachmentPreviewPayload(error: '文件内容无法解析，请下载原件查看');
  }
}

/// Public to exercise the browser scheduling path in deterministic native tests
/// as well as real browser tests. Uses the caller's existing work/identity fence.
Future<AttachmentPreviewPayload> parseAttachmentPreviewInUiSlices(
  AttachmentPreviewKind kind,
  Uint8List bytes, {
  UiWorkBudget? budget,
}) async {
  final work = budget ?? UiWorkBudget(debugLabel: 'attachment-preview');
  try {
    work.ensureCurrent();
    switch (kind) {
      case AttachmentPreviewKind.text:
        return AttachmentPreviewPayload(
          text: await decodeAttachmentTextInUiSlices(bytes, budget: work),
        );
      case AttachmentPreviewKind.csv:
        final decoded = await decodeAttachmentTextInUiSlices(
          bytes,
          budget: work,
        );
        return AttachmentPreviewPayload(
          text: decoded,
          table: await parseDelimitedTextInUiSlices(decoded.text, budget: work),
        );
      case AttachmentPreviewKind.archive:
        return AttachmentPreviewPayload(
          listing: await readZipListingInUiSlices(bytes, budget: work),
        );
      default:
        return const AttachmentPreviewPayload();
    }
  } on UiWorkCancelled {
    rethrow;
  } on ArchiveListingException catch (error) {
    return AttachmentPreviewPayload(error: error.message);
  } catch (_) {
    return const AttachmentPreviewPayload(error: '文件内容无法解析，请下载原件查看');
  }
}
