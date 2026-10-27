package com.uten.imp.application.port;

import com.uten.imp.common.export.TableColumnProjection;
import java.util.Map;

/** Immutable query contract shared with the authority that owns each report. */
public interface ReportExportQuery {
    String domain();
    String report();
    Map<String, String> parameters();
    String sort();
    String order();
    TableColumnProjection columnProjection();
}
