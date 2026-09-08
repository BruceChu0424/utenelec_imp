package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/** Exact value is the existing source/edge/revision expression, never its decimal cache. */
public interface InventoryValueAuthorityPort {
    record ValueReference(UUID nodeId,long revision) {}
    enum Readiness { READY, PENDING_DEPENDENCIES, LEGACY_UNVERIFIED }
    record Authority(ValueReference reference,BigDecimal lowerKnownValue,BigDecimal upperKnownValue,
                     int boundScale,boolean costComplete,Readiness readiness,List<ValueReference> dependencies) {}
    /** Constant-size lookup; no ancestry expansion or physical write. */
    Authority authority(ValueReference reference);
    /** One bounded expression step, called by valuation work, never a recursive inventory write. */
    Authority refine(ValueReference reference,int boundScale);
}
