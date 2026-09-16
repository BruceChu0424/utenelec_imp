package com.uten.imp.features.master.party;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface PartyContactMethodRepository
        extends JpaRepository<PartyContactMethod, UUID> {

    List<PartyContactMethod> findByPartyTypeAndPartyIdOrderByKindAscPrimaryDescCreatedAtAsc(
            String partyType, UUID partyId);

    long countByPartyTypeAndPartyIdAndKindAndValueIgnoreCase(
            String partyType, UUID partyId, String kind, String value);
}
