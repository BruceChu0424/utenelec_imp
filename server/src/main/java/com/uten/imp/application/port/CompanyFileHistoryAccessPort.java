package com.uten.imp.application.port;

import java.util.Collection;
import java.util.Set;
import java.util.UUID;

/** Current company-library visibility, resolved inside the caller's read transaction. */
public interface CompanyFileHistoryAccessPort {
    Set<UUID> readableHistoryNodes(Collection<UUID> ids, boolean accessSettings);
}
