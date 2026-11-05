package com.uten.imp.application.port;

import java.util.UUID;

/** Reuses the warehouse master's authoritative leaf/quality/use validation. */
public interface WarehouseUseValidationPort { void require(UUID warehouseId,String label,WarehouseUse use); }
