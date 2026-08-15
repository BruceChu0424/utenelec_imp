package com.uten.imp.common.mastercode;

import java.util.UUID;

/** A server-authoritative business number allocated for a master record. */
public record CategoryCodeAllocation(
        String code,
        long sequence,
        UUID prefixCategoryId,
        boolean managed) {
}
