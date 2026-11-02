package com.uten.imp.features.master.reference;

import java.util.UUID;

/** Identity and terms needed to select a document party; no contacts, bank, tax or credit fields. */
public record PartyReference(UUID id, String code, String name, UUID categoryId, String status,
        UUID defaultSettlementMethodId, boolean selectable) { }
