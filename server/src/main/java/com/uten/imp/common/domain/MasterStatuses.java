package com.uten.imp.common.domain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.Set;

/** Values accepted by explicit master enable/disable commands. Historical values stay readable. */
public final class MasterStatuses {
    public static final Set<String> VALUES = Set.of("使用", "禁用");

    private MasterStatuses() {}

    public static void requireValid(String status) {
        if (status == null || !VALUES.contains(status)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "状态只能是「使用」或「禁用」，不能清空");
        }
    }
}
