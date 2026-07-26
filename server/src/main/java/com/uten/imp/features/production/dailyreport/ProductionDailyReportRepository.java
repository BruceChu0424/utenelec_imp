package com.uten.imp.features.production.dailyreport;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

public interface ProductionDailyReportRepository
        extends JpaRepository<ProductionDailyReport, UUID>, JpaSpecificationExecutor<ProductionDailyReport> {

    Optional<ProductionDailyReport> findByLegacyId(Integer legacyId);
}
