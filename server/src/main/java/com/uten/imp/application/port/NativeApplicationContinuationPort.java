package com.uten.imp.application.port;

import com.uten.imp.security.AuthUser;
import java.util.Map;
import java.util.UUID;

/** Internal, reviewed source handoff. Implemented by the target's owning
 * feature; it creates/updates a draft only and cannot approve or pay. */
public interface NativeApplicationContinuationPort {
    String targetType();
    record Draft(UUID targetId,String businessKind,String title,String amount,
            Map<String,String> fields,UUID expenseClaimId,Long expectedExpenseVersion,
            String expectedExpenseFingerprint,String applicationKind,UUID travelApplicationId,
            String travelApplicationSourceKind) {
        public Draft {fields=fields==null?Map.of():java.util.Collections.unmodifiableMap(new java.util.LinkedHashMap<>(fields));}
    }
    record Result(String targetType,UUID id,String location,Map<String,Object> current) {
        public Result {current=current==null?Map.of():java.util.Collections.unmodifiableMap(new java.util.LinkedHashMap<>(current));}
    }
    boolean canContinueDraft(Draft draft,AuthUser actor);
    default void validateDraft(Draft draft) { }
    Result continueDraft(Draft draft);
    Result read(UUID id);
    /** Current native ownership/department/stage/history scope only. */
    boolean mayRead(UUID id,AuthUser actor);
}
