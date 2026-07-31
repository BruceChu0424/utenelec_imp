package com.uten.imp.common.validation;

/**
 * Hard limits for client-controlled collections.
 *
 * <p>Keep these limits at the HTTP validation boundary so oversized requests are rejected before
 * service code allocates additional collections or starts database work.
 */
public final class RequestLimits {

    public static final int DOCUMENT_LINES = 500;
    public static final int BATCH_IDS = 500;
    public static final int LOOKUP_IDS = 200;
    public static final int ADMIN_SCOPE_OWNERS = 1_000;
    public static final int PERMISSION_CODES = 500;
    public static final int NOTICE_ATTACHMENTS = 20;
    public static final int NOTICE_TITLE_LENGTH = 200;
    public static final int NOTICE_CONTENT_LENGTH = 20_000;
    public static final int NOTICE_AUDIENCE_TARGETS = 200;
    public static final int PROFILE_CHANGES = 100;
    public static final int EMPLOYEE_NESTED_ITEMS = 100;

    private RequestLimits() {}
}
