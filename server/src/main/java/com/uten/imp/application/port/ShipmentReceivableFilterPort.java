package com.uten.imp.application.port;

import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import java.util.UUID;

/** Owning finance predicate for an already authorized shipment query.
 * The caller must retain shipment object scope and require money-view authority.
 * It runs before pagination and never returns an unbounded list of source IDs. */
public interface ShipmentReceivableFilterPort {
    /** OPEN / OVERDUE; null or blank adds no debt restriction. */
    Predicate predicate(CriteriaBuilder builder, CriteriaQuery<?> query,
                        Expression<UUID> shipmentId, String state);
}
