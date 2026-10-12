package com.uten.imp.common.report;

/** Presentation metadata shared by report tables and their result-set totals. */
public interface ReportValueUnit {
    String key();
    String unitLabel();
    String unitKey();
}
