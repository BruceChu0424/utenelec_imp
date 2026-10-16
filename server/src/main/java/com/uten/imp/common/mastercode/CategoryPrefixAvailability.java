package com.uten.imp.common.mastercode;

/** Read-only result; saving still claims the prefix atomically in the database. */
public record CategoryPrefixAvailability(
        String normalizedPrefix, boolean available, String message) {

    public static final String OCCUPIED_MESSAGE = "该编号开头已被占用，请继续输入或更换，直到不再重复后再保存";
}
