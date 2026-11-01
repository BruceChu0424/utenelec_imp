package com.uten.imp.features.sales;

@lombok.Getter
@lombok.Setter
public class SalesReviewDocumentMetadata extends com.uten.imp.common.history.DocumentHistoryMetadata {
    private SalesManagerReview managerReview;
    private String managerApprovedByName;
    private String managerRejectedByName;
}
