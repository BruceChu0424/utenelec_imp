-- Current and previous category membership are independent history facts.
-- Match the previous-category candidate branch without scanning every JSON
-- snapshot before the final authorised, ordered page can be selected.
CREATE INDEX IF NOT EXISTS ix_master_versions_before_category
    ON public.master_record_versions
       (entity_type, (NULLIF(before_row->>'category_id', '')::uuid), id DESC);
