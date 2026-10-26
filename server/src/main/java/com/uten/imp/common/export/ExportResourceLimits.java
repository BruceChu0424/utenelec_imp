package com.uten.imp.common.export;

/** One resource contract for the reproducible file copies, independent of business row limits. */
public final class ExportResourceLimits {
    private ExportResourceLimits() { }
    public static final long ARTIFACT_BYTES=256L*1024*1024;
    public static final long LEGACY_ARTIFACT_BYTES=32L*1024*1024;
    public static final long SHEET_TEMP_BYTES=512L*1024*1024;
    public static final long FREE_RESERVE_BYTES=2L*1024*1024*1024;
    /** Raw source evidence decoded in one batch; originals are never altered. */
    public static final long SOURCE_BATCH_BYTES=32L*1024*1024;
}
