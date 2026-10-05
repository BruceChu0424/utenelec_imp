-- The inline inventory count form allows an omitted explanation. V766 still
-- required one, so otherwise valid submissions failed at the database boundary.
-- Preserve all existing evidence and the 500-character limit; rejection reasons
-- remain mandatory in the decision service.
ALTER TABLE stock_count_requests
    DROP CONSTRAINT stock_count_requests_reason_check;
ALTER TABLE stock_count_requests
    ADD CONSTRAINT stock_count_requests_reason_check
    CHECK (length(btrim(reason)) <= 500);
