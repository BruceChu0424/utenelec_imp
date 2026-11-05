package com.uten.imp.application.port;

import java.util.List;
import java.util.UUID;

/** Finance owns monetary-fund correspondence; account masters only select its proved posting UUIDs. */
public interface FundingAccountStylePort {
    record Choice(UUID id,Integer legacyId,String code,String name,String path) { }
    List<Choice> choices();
    /** Only new selections are checked here; existing account identities are never rewritten. */
    void requireSelectable(UUID styleId);
}
