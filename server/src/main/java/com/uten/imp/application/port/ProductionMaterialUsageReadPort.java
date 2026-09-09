package com.uten.imp.application.port;

import java.util.Collection;
import java.util.Map;
import java.util.UUID;

/** Read-only material activity for an already authorized page of execution segments. */
public interface ProductionMaterialUsageReadPort {
    /** The caller applies its exact segment visibility scope before supplying these IDs. */
    Map<UUID, UsageFlags> forVisibleSegments(Collection<UUID> segmentIds);

    record UsageFlags(boolean hasMaterialActivity, boolean hasUnregisteredMaterial) {
        public static final UsageFlags NONE = new UsageFlags(false, false);
    }
}
