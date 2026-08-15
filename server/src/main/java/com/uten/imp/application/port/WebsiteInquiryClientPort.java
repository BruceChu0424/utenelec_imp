package com.uten.imp.application.port;

import java.util.Optional;
import java.util.UUID;

/**
 * Customer-master boundary used when a website inquiry is converted.
 *
 * <p>The website-inquiry feature owns the workflow, while the master-data
 * feature remains authoritative for customer numbering and persistence.</p>
 */
public interface WebsiteInquiryClientPort {

    CreatedClient createFromInquiry(CreateRequest request);

    Optional<String> findName(UUID clientId);

    record CreateRequest(
            String name,
            String contactName,
            String phone,
            String email,
            String market,
            UUID ownerEmployeeId,
            String sourceId) {
    }

    record CreatedClient(UUID id, String name) {
    }
}
