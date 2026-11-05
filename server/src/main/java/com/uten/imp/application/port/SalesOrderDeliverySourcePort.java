package com.uten.imp.application.port;

import com.uten.imp.common.delivery.DeliveryBom;
import java.util.Collection;
import java.util.Map;
import java.util.UUID;

/** The caller admits/locks its sales source rows first; this port returns only their frozen delivery evidence. */
public interface SalesOrderDeliverySourcePort {
    Map<UUID,DeliveryBom.AdmittedSource> admittedSources(Collection<UUID> orderItemIds);
}
