package com.uten.imp.features.production.dailyreport.dto;

import com.uten.imp.common.history.DocumentHistoryMetadata;
import lombok.Getter;
import lombok.Setter;
import java.util.List;

/** Append-only approval facts, available to ordinary detail and retained history alike. */
@Getter
@Setter
public abstract class DailyReportMaterialReviewMetadata extends DocumentHistoryMetadata {
    private DailyReportMaterialReview materialReview;
    private List<DailyReportMaterialDecision> materialDecisions = List.of();
}
