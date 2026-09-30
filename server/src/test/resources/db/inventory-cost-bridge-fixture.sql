CREATE TABLE users(id uuid PRIMARY KEY);
CREATE TABLE units(id uuid PRIMARY KEY,name text);
CREATE TABLE goods(id uuid PRIMARY KEY,code text,name text,unit_id uuid,c_total numeric);
ALTER TABLE units ADD COLUMN legacy_id int;
ALTER TABLE goods ADD COLUMN is_deleted boolean DEFAULT false,ADD COLUMN spec text,ADD COLUMN model text,ADD COLUMN unit_legacy_id int,
 ADD COLUMN source_e numeric,ADD COLUMN work_e numeric,ADD COLUMN make_e numeric,ADD COLUMN lacquer_e numeric,
 ADD COLUMN plating_e numeric,ADD COLUMN machining_e numeric,ADD COLUMN polish_e numeric,ADD COLUMN electric_e numeric,
 ADD COLUMN incidental_e numeric,ADD COLUMN manage_e numeric,ADD COLUMN lost_e numeric,ADD COLUMN rent_e numeric,
 ADD COLUMN casing_e numeric,ADD COLUMN total numeric;
CREATE TABLE clients(id uuid PRIMARY KEY,code text,name text,region text,owner_employee_id uuid,emp_id text);
CREATE TABLE employees(id uuid PRIMARY KEY,legacy_id int,full_name text);
CREATE VIEW client_director_v AS SELECT id client_id,NULL::text director FROM clients;
CREATE TABLE ar_ap_ledger(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),client_id uuid,direction text,source_doc_type text,
 status int DEFAULT 1,is_deleted boolean DEFAULT false,bill_date date,amount_original_local numeric,amount_original numeric,currency_id uuid);
CREATE TABLE production_execution_segments(id uuid PRIMARY KEY,bill_no text);
CREATE TABLE sales_shipments(id uuid PRIMARY KEY,client_id uuid,bill_date date,status int,is_deleted boolean DEFAULT false);
CREATE TABLE sales_shipment_items(id uuid PRIMARY KEY,shipment_id uuid,goods_id uuid,is_deleted boolean DEFAULT false);
CREATE TABLE stock_value_pools(id uuid PRIMARY KEY,warehouse_id uuid,goods_id uuid,color_id uuid);
CREATE TABLE stock_value_events(id uuid PRIMARY KEY,operation text,source_doc_type text,source_doc_id uuid,source_item_id uuid,occurred_at timestamptz,movement_id uuid,result_node_id uuid);
CREATE TABLE stock_value_nodes(id uuid PRIMARY KEY,pool_id uuid,creation_event_id uuid,kind text,owner_kind text,owner_id uuid,
 quantity_basis numeric,returned_consumption_qty numeric DEFAULT 0,basis_value_local numeric,pending_parents int DEFAULT 0,
 revision bigint DEFAULT 1,value_model text DEFAULT 'EXACT_SOURCE_SHARES',bound_lower numeric,bound_upper numeric,
 initial_bound_lower numeric,initial_bound_upper numeric,bound_revision bigint DEFAULT 1,movement_id uuid);
CREATE TABLE stock_value_jobs(event_id uuid PRIMARY KEY,status text);
CREATE TABLE stock_value_position_transfers(event_id uuid,source_root_id uuid,target_node_id uuid);
CREATE TABLE stock_value_edges(parent_node_id uuid,child_node_id uuid,interval_from numeric DEFAULT 0,interval_to numeric DEFAULT 1);
CREATE TABLE stock_document_items(id uuid PRIMARY KEY,goods_id uuid,goods_code_snapshot text,goods_name_snapshot text,goods_snapshot_source text,goods_snapshot_locked_at timestamptz,unit_id uuid,unit_rate numeric);
CREATE TABLE stock_value_tasks(id uuid PRIMARY KEY,event_id uuid,status text);
CREATE TABLE stock_value_postings(id uuid PRIMARY KEY,event_id uuid,node_id uuid,task_id uuid,owner_kind text,owner_id uuid,amount_delta_local numeric,created_at timestamptz DEFAULT now());
CREATE TABLE stock_movements(id uuid PRIMARY KEY,goods_id uuid,warehouse_id uuid,color_id uuid,transaction_date timestamptz,movement_type int,direction int,qty numeric,source_doc_type text,source_doc_id uuid,source_item_id uuid);
CREATE TABLE stock_value_production_cost_objects(execution_segment_id uuid PRIMARY KEY,product_pool_id uuid,source_kind text,version bigint,state text,current_revision_id uuid,business_refresh_pending boolean DEFAULT false,created_at timestamptz DEFAULT now());
CREATE TABLE stock_value_production_cost_inputs(input_node_id uuid PRIMARY KEY,execution_segment_id uuid,approved_posting_id uuid,input_kind text,created_at timestamptz DEFAULT now());
CREATE TABLE stock_value_production_cost_outputs(source_node_id uuid PRIMARY KEY,execution_segment_id uuid,movement_id uuid,qty_base numeric,withdrawn_movement_id uuid,output_sequence bigint GENERATED ALWAYS AS IDENTITY);
CREATE TABLE stock_value_production_cost_revisions(id uuid PRIMARY KEY,execution_segment_id uuid,version bigint,target_qty_base numeric,output_qty_base numeric,scope_complete boolean,input_snapshot jsonb,output_snapshot jsonb,occurred_at timestamptz,source_doc_type text,source_doc_id uuid,source_item_id uuid);
CREATE TABLE stock_value_production_cost_tasks(id uuid PRIMARY KEY,execution_segment_id uuid,revision_id uuid,input_node_id uuid,output_source_node_id uuid,desired_value_local numeric,status text,input_pending int DEFAULT 0,value_event_id uuid);
CREATE TABLE stock_value_production_cost_dirty(input_node_id uuid,execution_segment_id uuid,observed_revision bigint,cleared_revision bigint);
CREATE TABLE stock_value_node_revisions(node_id uuid,revision bigint,event_id uuid,task_id uuid,after_bound_lower numeric,after_bound_upper numeric);
CREATE TABLE payment_styles(id uuid PRIMARY KEY,role_key text UNIQUE);
CREATE TABLE gl_vouchers(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),voucher_no text,period char(7),voucher_date date,source text,source_type text,source_doc_id uuid,remark text,status int DEFAULT 1,is_deleted boolean DEFAULT false,created_by uuid,updated_by uuid,UNIQUE(voucher_no,source_type));
CREATE TABLE gl_entries(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),voucher_id uuid REFERENCES gl_vouchers(id),line_no int,style_id uuid,direction int,amount numeric,entry_date date,period char(7),source_doc_type text,source_doc_id uuid,source_bill_no text,summary text,is_deleted boolean DEFAULT false,created_by uuid,updated_by uuid);
CREATE FUNCTION fn_finance_period_is_valid(text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$ SELECT $1 ~ '^[0-9]{4}-(0[1-9]|1[0-2])$' $$;
CREATE FUNCTION system_posting_style_id(text) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT id FROM payment_styles WHERE role_key=$1 $$;
CREATE FUNCTION fn_production_execution_cost_scope(uuid) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT $1 $$;
CREATE FUNCTION fn_stock_value_append_only() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'immutable'; END $$;
CREATE FUNCTION fn_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$;
CREATE FUNCTION fn_audit_track_table(text,text,text,boolean) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
CREATE FUNCTION business_data_reset() RETURNS TABLE(table_name text,policy text) LANGUAGE sql AS $$ VALUES ('stock_value_postings', 'CLEAR') $$;
