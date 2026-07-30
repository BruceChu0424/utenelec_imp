package com.uten.imp.features.production.dailyreport;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

public interface ProductionDailyReportItemRepository extends JpaRepository<ProductionDailyReportItem, UUID> {

    List<ProductionDailyReportItem> findByReportIdOrderByLineNoAsc(UUID reportId);

    @Modifying
    @Query("DELETE FROM ProductionDailyReportItem i WHERE i.reportId = :rid")
    void deleteByReportId(@Param("rid") UUID reportId);
}
