package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

/** Output-only memory/body budget; never changes a business mutation or import batch. */
public final class ExportSelectionBudget {
    public static final int MAX_BYTES = 16 * 1024 * 1024;
    private ExportSelectionBudget() { }

    public static void requireRows(List<Map<String,String>> rows) {
        if (rows == null) return;
        if (rows.isEmpty()) throw invalid();
        requireSnapshotBudget(rows);
        for (var row : rows) {
            if (row == null || row.isEmpty() || row.size() > 320) throw invalid();
            for (var cell : row.entrySet()) {
                if (cell.getKey() == null || cell.getKey().length() > 120 ||
                        cell.getValue() != null && cell.getValue().length() > 100000) throw invalid();
            }
        }
    }

    /** Check before copying the DTO, while preserving its existing malformed-entry validation contract. */
    public static void requireSnapshotBudget(List<Map<String,String>> rows) {
        if (rows == null) return;
        long bytes = 64L * rows.size();
        if (bytes > MAX_BYTES) throw invalid();
        for (var row : rows) {
            LegacyExportBudget.checkpoint();
            // Include object/index overhead as well as the actual UTF-8 text.
            if (row == null) continue;
            for (var cell : row.entrySet()) {
                bytes += 64L + (cell.getKey() == null ? 0 : cell.getKey().getBytes(StandardCharsets.UTF_8).length)
                        + (cell.getValue() == null ? 0 : cell.getValue().getBytes(StandardCharsets.UTF_8).length);
                if (bytes > MAX_BYTES) throw invalid();
            }
        }
    }
    public static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "选中行输出条件无效或超过请求空间预算，请刷新后重选");
    }
}
