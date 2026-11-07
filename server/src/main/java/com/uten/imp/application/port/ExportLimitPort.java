package com.uten.imp.application.port;

/**
 * Historical export-setting compatibility port. Complete-result readers no longer
 * reject a result based on this value; bounded batches and file budgets own resources.
 */
public interface ExportLimitPort {

    /** Retained for existing callers and historical configuration compatibility. */
    int exportMaxRows();
}
