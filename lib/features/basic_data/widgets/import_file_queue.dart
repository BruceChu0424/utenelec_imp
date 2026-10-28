import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';
import 'basic_data_l10n.dart';

enum ImportFileQueuePhase {
  waiting,
  detecting,
  reviewing,
  committing,
  paused,
  failed,
  done,
}

/// Only the current file is detected. Completing one file releases its bytes
/// before the next file is read, so the next detection sees committed state.
class ImportFileQueue {
  List<PlatformFile> _pending = [];
  final List<({String filename, String summary})> completed = [];
  final List<({String filename, String summary})> partialCompleted = [];
  Uint8List? currentBytes;
  bool approved = false;
  ImportFileQueuePhase phase = ImportFileQueuePhase.waiting;

  PlatformFile? get current => _pending.firstOrNull;
  bool get hasPending => _pending.isNotEmpty;
  int get position => completed.length + (hasPending ? 1 : 0);
  int get total => completed.length + _pending.length;

  void replacePending(List<PlatformFile> files) {
    _pending = List.of(files);
    currentBytes = null;
    approved = false;
    phase = ImportFileQueuePhase.waiting;
  }

  void pause({bool failed = false}) {
    approved = false;
    phase = failed ? ImportFileQueuePhase.failed : ImportFileQueuePhase.paused;
  }

  void succeed(String summary) {
    final file = current!;
    completed.add((filename: file.name, summary: summary));
    _pending.removeAt(0);
    currentBytes = null;
    phase = hasPending
        ? ImportFileQueuePhase.waiting
        : ImportFileQueuePhase.done;
  }

  void recordPartial(String summary) {
    partialCompleted.add((filename: current!.name, summary: summary));
  }
}

/// File outcomes are a readable activity list, rather than another data grid.
class ImportFileQueueSummary extends StatelessWidget {
  const ImportFileQueueSummary({
    super.key,
    required this.queue,
    this.compact = false,
  });
  final ImportFileQueue queue;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = basicDataL10n(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (queue.total > 0 && (!compact || queue.total > 1)) ...[
          const SizedBox(height: UtenSpacing.s8),
          Text(l.importFilesCompleted(queue.completed.length, queue.total)),
        ],
        if (queue.current case final file?) ...[
          const SizedBox(height: UtenSpacing.s8),
          Text(
            compact && queue.total == 1
                ? file.name
                : l.importFilesCurrent(queue.position, queue.total, file.name),
            key: const ValueKey('import-queue-current-file'),
            style: theme.textTheme.titleSmall,
          ),
          if (queue.phase == ImportFileQueuePhase.paused)
            Text(l.importFilesPaused),
          if (queue.phase == ImportFileQueuePhase.failed)
            Text(
              l.importFilesFailed,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          if (!compact)
            Text(l.importFilesCloseNote, style: theme.textTheme.bodySmall),
        ],
        if (queue.completed.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          for (var index = 0; index < queue.completed.length; index++)
            Padding(
              key: ValueKey('import-queue-completed-$index'),
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: Text(
                l.importFilesOutcome(
                  queue.completed[index].filename,
                  queue.completed[index].summary,
                ),
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
        for (final outcome in queue.partialCompleted)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Text(
              l.goodsImportPartialOutcome(outcome.filename, outcome.summary),
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: UtenSpacing.s12),
      ],
    );
  }
}
