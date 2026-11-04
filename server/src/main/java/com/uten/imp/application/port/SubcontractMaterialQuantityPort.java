package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.util.UUID;

/** Actual unconsumed custody quantity; caller first authorizes the linked
 * material issue and holds its inventory mutation lock. No price is exposed. */
public interface SubcontractMaterialQuantityPort {
    BigDecimal returnableBaseQuantity(UUID issueItemId);
}
