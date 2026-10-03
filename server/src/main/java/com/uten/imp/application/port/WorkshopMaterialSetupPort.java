package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/** Explicit, authorized material setup during warehouse fulfilment; joins the caller's transaction. */
public interface WorkshopMaterialSetupPort {
    record Setup(UUID goodsId, Long expectedVersion, String periodicCostBasis) {}

    void setup(List<Setup> materials, String fulfilCommandKey);
}
