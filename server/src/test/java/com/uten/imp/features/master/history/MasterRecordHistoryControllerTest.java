package com.uten.imp.features.master.history;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.UUID;
import org.junit.jupiter.api.Test;

class MasterRecordHistoryControllerTest {
  @Test
  void resolvedHistoryRecordsOneSpecificDetailViewForItsBusinessObjectAndRevision() {
    var service = mock(MasterRecordHistoryService.class);
    var audit = mock(AuditDetailViewRecorder.class);
    var entry = mock(MasterRecordHistoryService.Entry.class);
    var recordId = UUID.randomUUID();
    when(entry.id()).thenReturn("101");
    when(entry.recordId()).thenReturn(recordId);
    when(entry.recordCode()).thenReturn("C001");
    when(entry.recordLabel()).thenReturn("本色");
    when(service.detail("colors", 101)).thenReturn(entry);

    assertSame(entry, new MasterRecordHistoryController(service, audit).detail("colors", 101));

    verify(audit)
        .record(
            "view_master_record_history_detail",
            "master_record_history",
            recordId,
            "C001",
            null,
            "基础资料历史 · 本色 · 版本 101");
    verifyNoMoreInteractions(audit);
  }

  @Test
  void deniedOrMissingHistoryNeverRecordsASuccessfulDetailView() {
    var service = mock(MasterRecordHistoryService.class);
    var audit = mock(AuditDetailViewRecorder.class);
    when(service.detail("colors", 101)).thenThrow(new ApiException(ErrorCode.FORBIDDEN));

    assertThrows(
        ApiException.class,
        () -> new MasterRecordHistoryController(service, audit).detail("colors", 101));

    verifyNoInteractions(audit);
  }
}
