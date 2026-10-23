package com.uten.imp.common.validation;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.UUID;

/** Prevent a document-level transaction from silently expanding a row-level task selection. */
public final class ExactDocumentSelection {
    private ExactDocumentSelection() { }

    public static void requireComplete(List<UUID> selected, Collection<UUID> actual) {
        if (selected == null) return;
        if (selected.isEmpty() || selected.size() > RequestLimits.DOCUMENT_LINES
                || selected.stream().anyMatch(java.util.Objects::isNull)
                || new HashSet<>(selected).size() != selected.size()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择有效且不重复的单据明细");
        }
        if (!new HashSet<>(selected).equals(new HashSet<>(actual))) {
            throw new ApiException(ErrorCode.CONFLICT, "该单据需整单确认，请返回任务中心选齐同单明细；本次未办理任何未选明细");
        }
    }
}
