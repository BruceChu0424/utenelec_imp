-- V1108 added same-sales private-stock adoption but replaced V1056's public
-- root entry independently of its delta entry. Keep one source curve for reads,
-- newly captured output credit and reversal previews. Existing append-only
-- output/source-credit rows and all physical reservations remain unchanged.
CREATE OR REPLACE FUNCTION public.fn_root_fulfilled_source_qty_with_delta(item_id uuid,delta_base numeric)
RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT LEAST(GREATEST(item.requested_qty-item.submitted_qty-item.approved_qty,0),
   CASE WHEN item.delivery_plan_snapshot->>'mode'='BOM' THEN
      -- BOM order quantities come only from their original component-delivery
      -- fulfillment ledger. A finished-product output/adoption is not proof
      -- that those separately owned components have been delivered.
      GREATEST(COALESCE((SELECT sum(CASE WHEN event.event_type='FULFILL' THEN event.order_qty ELSE -event.order_qty END)
        FROM public.sales_delivery_fulfillment_events event
        JOIN public.sales_delivery_fulfillment_allocations allocation ON allocation.id=event.allocation_id
        WHERE allocation.analysis_item_id=item.id),0),0)
   ELSE GREATEST(TRUNC((COALESCE((SELECT sum(CASE WHEN output.event_kind='FULFILL'
          THEN output.qty_base ELSE -output.qty_base END)
          FROM public.preplan_root_output_events output WHERE output.analysis_item_id=item.id),0)
        +public.fn_preplan_adopted_sales_stock_base(item.id)+delta_base)
      /COALESCE(NULLIF(root.per_product_qty,0),1),4),0) END)
 FROM public.production_material_analysis_items item
 LEFT JOIN public.production_material_analysis_materials root ON root.id=item.root_material_id
 WHERE item.id=item_id;
$$;

CREATE OR REPLACE FUNCTION public.fn_root_fulfilled_source_qty(item_id uuid)
RETURNS numeric LANGUAGE sql STABLE AS $$
 SELECT public.fn_root_fulfilled_source_qty_with_delta(item_id,0)
$$;
