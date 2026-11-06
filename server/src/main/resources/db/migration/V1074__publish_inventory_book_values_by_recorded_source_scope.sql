-- A recorded book value is unavailable while its own original closure is
-- pending. Unrelated rooted work must not hide a known value, including zero.
-- The shared publication predicate retains conservative handling for old work
-- without recorded closure evidence. Values, bounds and source facts stay intact.
CREATE OR REPLACE FUNCTION fn_inventory_value_book_projection(p_node uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN n.pending_parents=0 AND n.bound_revision=n.revision AND n.bound_lower IS NOT NULL
   AND NOT fn_inventory_value_node_revaluation_pending(n.id)
  THEN n.basis_value_local END FROM stock_value_nodes n WHERE n.id=p_node
$$;
