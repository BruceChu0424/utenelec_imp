-- Keep the original recorded book point and its pending/bound guards. A proven
-- modern revaluation publishes by its durable whole-target node closure, exactly
-- like the actual-COGS readers, rather than masking every unrelated goods root.
-- The shared authority includes jobs/edge tasks/production work and dirty input
-- ancestry; its legacy work without an established proof remains conservative.
DO $$ BEGIN
 IF to_regprocedure('fn_inventory_value_node_revaluation_pending(uuid)') IS NULL
    OR fn_inventory_value_revaluation_contract_version()<>1 THEN
  RAISE EXCEPTION 'Review durable inventory publication authority before changing book projection scope';
 END IF;
END $$;

CREATE OR REPLACE FUNCTION fn_inventory_value_book_projection(p_node uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT CASE WHEN n.pending_parents=0 AND n.bound_revision=n.revision AND n.bound_lower IS NOT NULL
   AND NOT fn_inventory_value_node_revaluation_pending(n.id)
  THEN n.basis_value_local END FROM stock_value_nodes n WHERE n.id=p_node
$$;
