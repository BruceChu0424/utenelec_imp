package com.uten.imp.features.production.fulfillment;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.UUID;

public interface ProductionMaterialDemandRepository
        extends JpaRepository<ProductionMaterialDemand, UUID> {
}
