package com.uten.imp.common.validation;

/**
 * Hard limits for client-controlled collections.
 *
 * <p>Keep these limits at the HTTP validation boundary so oversized requests are rejected before
 * service code allocates additional collections or starts database work.
 */
public final class RequestLimits {

    public static final int DOCUMENT_LINES = 500;
    /** One aggregate document line can retain many more original BOM source paths. */
    public static final int MATERIAL_AGGREGATE_SOURCE_PATHS = 10_000;
    public static final int BATCH_IDS = 500;
    public static final int LOOKUP_IDS = 200;
    public static final int ADMIN_SCOPE_OWNERS = 1_000;
    public static final int PERMISSION_CODES = 500;
    public static final int NOTICE_ATTACHMENTS = 20;
    public static final int NOTICE_TITLE_LENGTH = 200;
    public static final int NOTICE_CONTENT_LENGTH = 20_000;
    public static final int NOTICE_AUDIENCE_TARGETS = 200;
    public static final int NOTICE_BLESSING_LENGTH = 200;
    public static final int PROFILE_CHANGES = 100;
    public static final int EMPLOYEE_NESTED_ITEMS = 100;
    /**
     * 一行报工最多同时转给多少个上层工单(V736/ADR-127)。一个共享子件批次常要分给十几个成品工单；
     * 再多就明确报错请分行，不悄悄改成送入仓库。
     */
    public static final int DAILY_REPORT_DIRECT_RECEIVERS = 30;
    /** 一行报工的去向条数上限：上面的接收工单数再加一条送入仓库。 */
    public static final int DAILY_REPORT_LINE_DESTINATIONS = DAILY_REPORT_DIRECT_RECEIVERS + 1;

    private RequestLimits() {}
}
