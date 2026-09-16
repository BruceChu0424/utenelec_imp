package com.uten.imp.features.master.party;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface PartyAddressRepository extends JpaRepository<PartyAddress, UUID> {

    List<PartyAddress> findByPartyTypeAndPartyIdOrderByDefaultAddressDescCreatedAtAsc(
            String partyType, UUID partyId);
}
