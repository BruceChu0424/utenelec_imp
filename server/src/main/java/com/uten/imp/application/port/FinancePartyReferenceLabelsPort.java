package com.uten.imp.application.port;

import java.util.Collection;
import java.util.Map;
import java.util.UUID;

/** Minimal labels for server-owned foreign keys of an already authorized financial document.
 * Not a party directory, candidate search, master grant or historical money snapshot.
 */
public interface FinancePartyReferenceLabelsPort {
    Map<UUID,String> clients(Collection<UUID> ids);
    Map<UUID,String> suppliers(Collection<UUID> ids);
}
