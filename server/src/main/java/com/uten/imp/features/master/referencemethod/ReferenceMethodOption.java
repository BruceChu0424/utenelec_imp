package com.uten.imp.features.master.referencemethod;

import java.util.UUID;

public record ReferenceMethodOption(
        UUID id,
        Integer legacyId,
        String code,
        String legacyCode,
        String name,
        boolean legacyNameConfirmed) {}
