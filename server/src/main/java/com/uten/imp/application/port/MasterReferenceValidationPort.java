package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * Application boundary for validating master-data references supplied by a client.
 *
 * <p>Foreign keys only prove that a row exists. Implementations additionally enforce
 * soft-delete state, the current user's owner scope and document-unit invariants before
 * a business document persists the reference.</p>
 */
public interface MasterReferenceValidationPort {

    /** Requires only existence and owner-scope visibility; inactive rows remain cleanable. */
    void requireVisibleGoods(UUID goodsId);

    /** Visibility probe for redacting an existing relationship without exposing its target. */
    boolean canViewGoods(UUID goodsId);

    void requireVisibleActiveGoods(UUID goodsId);

    void requireVisibleActiveClient(UUID clientId);

    ResolvedLineUnit resolveVisibleActiveGoodsUnit(
            UUID goodsId,
            UUID unitId,
            BigDecimal unitRate,
            int lineNo);

    record ResolvedLineUnit(UUID unitId, BigDecimal unitRate) {
    }
}
