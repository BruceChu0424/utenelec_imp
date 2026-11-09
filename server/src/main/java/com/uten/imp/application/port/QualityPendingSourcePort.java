package com.uten.imp.application.port;

import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Quality-owned pending reads: material-grain rows (2026-11-09: one IQC inspection
 * item, one FQC sheet lot or one sheet-less FQC task per row) carrying document-grain
 * payloads. Each owning domain retains its visibility predicate, calculations, DTO
 * mapping and action authority.
 */
public interface QualityPendingSourcePort {
    String readAuthority();
    /**
     * Fixed columns: identity, kind, bill_no, party, goods, goods_code,
     * color_name, warehouse, place, pending_qty, entered_at, status_code,
     * sequence_at, goods_names, draft_identity, pre_stocked. draft_identity is the
     * document-grain key local drafts are matched on; pre_stocked flags this row.
     * Dates are timestamptz; quantities retain their unit-grouped display text.
     * No LIMIT or header predicate here.
     */
    List<Plan> pendingPlans();
    /** Returns the original authorized DTOs only for identities selected by the common page. */
    Map<String, Object> pendingPayloads(String planKey, Set<String> identities);

    record Plan(String key, String sql, Map<String, Object> bindings) {
        public Plan { bindings = Map.copyOf(bindings); }
    }
}
