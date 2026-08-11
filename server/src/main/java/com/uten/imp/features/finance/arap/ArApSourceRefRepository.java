package com.uten.imp.features.finance.arap;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.UUID;

/** Repository for immutable AR/AP business-source snapshots. */
public interface ArApSourceRefRepository extends JpaRepository<ArApSourceRef, UUID> {
}
