package com.uten.imp.features.master.party;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface PartyActivityRecordRepository
        extends JpaRepository<PartyActivityRecord, UUID> {

    List<PartyActivityRecord> findByPartyTypeAndPartyIdOrderByCreatedAtDesc(
            String partyType, UUID partyId);
}
