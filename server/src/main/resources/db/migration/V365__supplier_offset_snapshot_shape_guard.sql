-- V365: each offset snapshot must consume a negative source and a positive AP
-- target without crossing zero. Service locks are backed by database shape.

ALTER TABLE supplier_open_item_offsets
    ADD CONSTRAINT supplier_open_item_offsets_balance_sign_chk CHECK (
        source_balance_before_original<0
        AND source_balance_after_original<=0
        AND target_balance_before_original>0
        AND target_balance_after_original>=0),
    ADD CONSTRAINT supplier_open_item_offsets_capacity_chk CHECK (
        amount_original<=ABS(source_balance_before_original)
        AND amount_original<=target_balance_before_original);
