package com.uten.imp.features.production.fulfillment;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface ProductionExecutionSegmentRepository
        extends JpaRepository<ProductionExecutionSegment, UUID> {

    List<ProductionExecutionSegment> findByPackageIdAndDeletedFalseOrderBySegmentNoAsc(
            UUID packageId);
}
