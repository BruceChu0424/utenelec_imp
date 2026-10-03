package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

class StockDrawIssueReviewContractTest {
    @Test void legacyHashIsUnchangedAndV2OwnsEveryFrozenReviewToken() {
        UUID id=UUID.randomUUID();var old=request(id);String original=StockDrawIssueBatchReceipts.normalize(old).hash();
        old.setProtocolVersion(1);assertEquals(original,StockDrawIssueBatchReceipts.normalize(old).hash());
        old.setProtocolVersion(2);old.setReviews(List.of(new StockDocIssueBatchRequest.DocumentReview(id,"a".repeat(64))));
        String reviewed=StockDrawIssueBatchReceipts.normalize(old).hash();assertNotEquals(original,reviewed);
        old.setReviews(List.of(new StockDocIssueBatchRequest.DocumentReview(id,"b".repeat(64))));
        assertNotEquals(reviewed,StockDrawIssueBatchReceipts.normalize(old).hash());
    }
    @Test void missingExtraDuplicateAndInvalidVersionsFailBeforeAnyCommandIsClaimed() {
        UUID id=UUID.randomUUID();var request=request(id);request.setProtocolVersion(2);
        assertThrows(ApiException.class,()->StockDrawIssueBatchReceipts.normalize(request));
        request.setReviews(List.of(new StockDocIssueBatchRequest.DocumentReview(UUID.randomUUID(),"a".repeat(64))));
        assertThrows(ApiException.class,()->StockDrawIssueBatchReceipts.normalize(request));
        var review=new StockDocIssueBatchRequest.DocumentReview(id,"a".repeat(64));request.setReviews(List.of(review,review));
        assertThrows(ApiException.class,()->StockDrawIssueBatchReceipts.normalize(request));
        request.setReviews(List.of(review));request.setProtocolVersion(3);
        assertThrows(ApiException.class,()->StockDrawIssueBatchReceipts.normalize(request));
        request.setProtocolVersion(1);assertThrows(ApiException.class,()->StockDrawIssueBatchReceipts.normalize(request));
    }
    private StockDocIssueBatchRequest request(UUID id){var request=new StockDocIssueBatchRequest();request.setIdempotencyKey("closeout-review-key");request.setDocIds(List.of(id));return request;}
}
