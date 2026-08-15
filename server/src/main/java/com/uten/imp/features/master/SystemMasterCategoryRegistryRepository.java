package com.uten.imp.features.master;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.UUID;

interface SystemMasterCategoryRegistryRepository
        extends JpaRepository<SystemMasterCategoryRegistryEntry, UUID> {
}
