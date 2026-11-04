package com.uten.imp.application.port;

import com.uten.imp.common.finance.BusinessPrecisionContext.Choice;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Private input provenance, never a balance or an alternative business calculation.
 * Call only after the owning domain validated its current write/read authority. */
public interface BusinessNumericInputEvidencePort {
    record Unit(String kind,String code,UUID referenceId) { }
    record Capture(String ownerKind,UUID ownerId,UUID sourceRowId,String fieldKey,String ownerVersion,
            BigDecimal original,Unit originalUnit,BigDecimal recorded,Unit recordedUnit,Map<String,Choice> usedPolicy) {
        public Capture { usedPolicy=usedPolicy==null?Map.of():Map.copyOf(usedPolicy); }
    }
    record Value(UUID id,String fieldKey,String ownerVersion,String originalDecimal,Unit originalUnit,
            String recordedDecimal,Unit recordedUnit,Map<String,Choice> usedPolicy,UUID actorId,
            UUID requestId,String sourceActionId,OffsetDateTime createdAt) { public Value { usedPolicy=usedPolicy==null?Map.of():Map.copyOf(usedPolicy); } }
    /** Same owner transaction; duplicate action/field must have the identical proof. */
    UUID record(Capture capture);
    /** Internal only: the owning document/field policy must authorize first. No generic HTTP reader. */
    Map<UUID,List<Value>> readForAuthorizedOwner(String ownerKind,UUID ownerId,List<UUID> visibleSourceRows);
}
