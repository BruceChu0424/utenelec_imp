package com.uten.imp.common.history;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Public history projection; private snapshots never leave domain services. */
public final class RecordHistory {
  private RecordHistory() {}
  public record Change(
      String table,
      UUID rowId,
      String field,
      String label,
      String beforeValue,
      String afterValue) {}

  public record Entry(
      String id,
      UUID recordId,
      String recordLabel,
      String action,
      String actorName,
      OffsetDateTime recordedAt,
      String expectedHead,
      int affectedCount,
      List<Change> changes,
      boolean canRestoreBefore,
      boolean canRestoreAfter,
      String blockedReason,
      String entityType,
      String sourceType,
      String recordCode,
      UUID categoryId,
      String categoryName,
      String summary,
      UUID actorId,
      String recordName) {}

  public record Page(List<Entry> entries, String nextCursor) {}

}
