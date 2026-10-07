package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/** Authoritative initial handoff eligibility, separate from residual demand in an existing analysis. */
public interface SalesPlanningNoticeReadPort {
    boolean needsInitialHandoff(UUID orderId);
    List<UUID> initialHandoffOrdersAfter(UUID afterId, int limit);
}
