-- Reviewed V854 root identity writes, extracted from the actual pre-V855 source.
-- Validation is performed independently against actual stock-root fixture rows.
UPDATE production_material_analysis_items
SET root_material_id=gen_random_uuid()
WHERE analysis_id=:analysisId AND is_deleted=FALSE
  AND root_material_id IS NULL
  AND source_type IN ('SALES_ORDER_ITEM','REWORK','TRIAL','SAMPLE','STOCK','OTHER');

INSERT INTO production_material_analysis_materials (
  id,analysis_id,analysis_item_id,node_key,parent_node_key,bom_item_id,
  goods_id,color_id,unit_id,depth,path,per_product_qty,
  required_qty,available_qty,allocated_available_qty,reserved_qty,
  safety_stock_qty,inbound_qty,shortage_qty,source_suggestion,active,
  control_stage,consumption_basis,basis_output_qty,allow_partial_package,
  hard_gate,bom_qty,parent_per_product_qty,calculation_mode,node_role,
  allocated_start_qty,allocated_finish_qty,allocated_ship_qty,created_by,updated_by)
SELECT item.root_material_id,item.analysis_id,item.id,'ROOT_SUPPLY',NULL,NULL,
  item.goods_id,item.color_id,goods.unit_id,0,'[]',
  COALESCE(sales.unit_rate,1),
  CEIL(GREATEST(item.requested_qty,0)
    *COALESCE(sales.unit_rate,1)*10000)/10000,
  0,0,0,GREATEST(COALESCE(goods.min_qty,0),0),0,
  CEIL(GREATEST(item.requested_qty,0)
    *COALESCE(sales.unit_rate,1)*10000)/10000,
  'MAKE',TRUE,'START','PER_UNIT',1,TRUE,TRUE,
  COALESCE(sales.unit_rate,1),1,'EDGE_RULE','ROOT_SUPPLY',0,0,0,:actorId,:actorId
FROM production_material_analysis_items item
JOIN goods ON goods.id=item.goods_id
LEFT JOIN sales_order_items sales ON sales.id=item.sales_order_item_id
WHERE item.analysis_id=:analysisId AND item.root_material_id IS NOT NULL
  AND item.is_deleted=FALSE
ON CONFLICT (id) DO NOTHING;
