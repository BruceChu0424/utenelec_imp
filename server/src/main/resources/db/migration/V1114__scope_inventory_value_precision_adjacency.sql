-- Discover the same actual and pending edges from the walked node first.
-- Keep the closure traversal, pre/post-claim comparison and forecast unchanged.
CREATE OR REPLACE FUNCTION fn_inventory_value_precision_successors(p_node uuid)
RETURNS TABLE(node_id uuid) LANGUAGE sql STABLE AS $$
    WITH source_postings AS MATERIALIZED (
        SELECT DISTINCT event.source_event_id AS posting_id
        FROM stock_value_events event
        WHERE event.result_node_id=p_node
    ), pending_inputs AS MATERIALIZED (
        SELECT candidate.member_segment_id
        FROM source_postings source
        CROSS JOIN LATERAL (
            -- The canonical view joins either approved posting to its source
            -- event. Use that identity before expanding the candidate view.
            SELECT candidate.member_segment_id
            FROM v_production_cost_input_candidates candidate
            WHERE candidate.result_node_id=p_node
              AND candidate.approved_posting_id=source.posting_id
              AND candidate.node_active
              AND NOT EXISTS (
                  SELECT 1 FROM stock_value_production_cost_inputs registered
                  WHERE registered.approved_posting_id=candidate.approved_posting_id
              )
            OFFSET 0
        ) candidate
    )
    SELECT edge.child_node_id FROM stock_value_edges edge WHERE edge.parent_node_id=p_node
    UNION
    SELECT output.source_node_id
    FROM stock_value_production_cost_inputs input
    JOIN stock_value_production_cost_outputs output USING(execution_segment_id)
    WHERE input.input_node_id=p_node
    UNION
    SELECT output.source_node_id
    FROM pending_inputs candidate
    JOIN stock_value_production_cost_objects object
      ON object.execution_segment_id=fn_production_execution_cost_scope(candidate.member_segment_id)
    JOIN stock_value_production_cost_outputs output USING(execution_segment_id)
    WHERE object.business_refresh_pending
$$;

CREATE OR REPLACE FUNCTION fn_inventory_value_precision_predecessors(p_node uuid)
RETURNS TABLE(node_id uuid) LANGUAGE sql STABLE AS $$
    WITH pending_scopes AS MATERIALIZED (
        SELECT output.execution_segment_id
        FROM stock_value_production_cost_outputs output
        JOIN stock_value_production_cost_objects object USING(execution_segment_id)
        WHERE output.source_node_id=p_node AND object.business_refresh_pending
    )
    SELECT edge.parent_node_id FROM stock_value_edges edge WHERE edge.child_node_id=p_node
    UNION
    SELECT input.input_node_id
    FROM stock_value_production_cost_outputs output
    JOIN stock_value_production_cost_inputs input USING(execution_segment_id)
    WHERE output.source_node_id=p_node
    UNION
    SELECT candidate.result_node_id
    FROM pending_scopes pending
    CROSS JOIN LATERAL (
        -- A node without a pending production output has no pending inputs to
        -- look up. The member reader retains the canonical split/supplement scope.
        SELECT candidate.result_node_id
        FROM fn_production_execution_cost_members(pending.execution_segment_id) member
        JOIN v_production_cost_input_candidates candidate
          ON candidate.member_segment_id=member.segment_id
        WHERE candidate.node_active
          AND NOT EXISTS (
              SELECT 1 FROM stock_value_production_cost_inputs registered
              WHERE registered.approved_posting_id=candidate.approved_posting_id
          )
        OFFSET 0
    ) candidate
$$;
