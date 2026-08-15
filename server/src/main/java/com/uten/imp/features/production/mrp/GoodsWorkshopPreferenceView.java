package com.uten.imp.features.production.mrp;

import java.util.UUID;

/**
 * Learned workshop default for planning UI prefill.
 *
 * <p>This is a convenience projection only. Confirmed execution segments stay
 * the authority for the workshop that was actually scheduled.</p>
 */
public record GoodsWorkshopPreferenceView(
        UUID goodsId,
        UUID departmentId,
        String departmentName) {
}
