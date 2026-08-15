package com.uten.imp.features.master;

import java.util.UUID;

/** Stable identities and display contracts for protected system master-data roots. */
public final class SystemMasterCategories {

    /** Stable UUID identity of the registry row. */
    public static final UUID REGISTRY_ID =
            UUID.fromString("27500000-0000-4000-8000-000000000001");

    public static final int UNCATEGORIZED_LEGACY_ID = -1;
    public static final String UNCATEGORIZED_NAME = "未分类";
    public static final String SYSTEM_REMARK = "SYSTEM_UNCATEGORIZED";
    public static final String CLIENT_CODE = "SYS_UNCATEGORIZED_CLIENT";
    public static final String MOULD_CODE = "SYS_UNCATEGORIZED_MOULD";
    public static final String SUPPLIER_CODE = "SYS_UNCATEGORIZED_SUPPLIER";

    private SystemMasterCategories() {
    }

}
