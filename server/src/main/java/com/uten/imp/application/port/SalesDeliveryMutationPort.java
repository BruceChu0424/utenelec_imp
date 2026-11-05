package com.uten.imp.application.port;

import java.util.UUID;

/** Processing follows the existing sales commercial/inventory/execution lock order. */
public interface SalesDeliveryMutationPort { void lockShipment(UUID shipmentId); }
