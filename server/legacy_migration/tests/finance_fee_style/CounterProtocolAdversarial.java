import java.nio.file.*;
import java.sql.*;
import java.util.*;
import java.math.BigDecimal;
import com.fasterxml.jackson.databind.*;
import com.fasterxml.jackson.databind.node.*;
import org.flywaydb.core.Flyway;

class CounterProtocolAdversarial {
  static final ObjectMapper JSON=new ObjectMapper();
  static String url,user,password;
  static final String runtimePassword=UUID.randomUUID().toString();
  static JsonNode fixtures;
  static final List<Map<String,Object>> results=new ArrayList<>();
  static final List<Map<String,Object>> benchmarks=new ArrayList<>();
  static int identity=980000;
  interface Checked {void run() throws Exception;}
  interface InTx {void run(Tx tx) throws Exception;}
  record Family(String kind,String table,String counter,boolean receipt){}
  static final List<Family> families=List.of(
    new Family("PURCHASE_ORDER_ITEM","purchase_order_items","received_qty",false),
    new Family("PURCHASE_ORDER_ITEM","purchase_order_items","returned_qty",false),
    new Family("SALES_ORDER_ITEM","sales_order_items","shipped_qty",false),
    new Family("SALES_ORDER_ITEM","sales_order_items","returned_qty",false),
    new Family("SALES_SHIPMENT_ITEM","sales_shipment_items","returned_qty",false),
    new Family("PURCHASE_ITEM","purchase_receipt_items","returned_qty",true));
  static class Tx implements AutoCloseable {
    final Connection c; UUID run;
    Tx() throws Exception {c=DriverManager.getConnection(url,user,password);c.setAutoCommit(false);}
    public void close() throws Exception {c.rollback();c.close();}
    void sql(String sql,Object...p)throws Exception {try(PreparedStatement s=c.prepareStatement(sql)){bind(s,p);s.execute();}}
    Object scalar(String sql,Object...p)throws Exception {try(PreparedStatement s=c.prepareStatement(sql)){bind(s,p);try(ResultSet r=s.executeQuery()){return r.next()?r.getObject(1):null;}}}
    String text(String sql,Object...p)throws Exception {Object v=scalar(sql,p);return v==null?null:v.toString();}
    long count(String table)throws Exception {return ((Number)scalar("SELECT count(*) FROM public."+table)).longValue();}
  }
  static void bind(PreparedStatement s,Object[] p)throws Exception {for(int i=0;i<p.length;i++)s.setObject(i+1,p[i]);}
  static void require(boolean b,String m){if(!b)throw new AssertionError(m);}
  static SQLException denied(Tx t,Checked action)throws Exception {
    Savepoint point=t.c.setSavepoint();
    try {action.run();throw new AssertionError("operation unexpectedly accepted");}
    catch(SQLException expected){require(!"25P02".equals(expected.getSQLState()),"test used aborted transaction");return expected;}
    finally {t.c.rollback(point);}
  }
  static void test(String name,InTx action) {
    Map<String,Object> row=new LinkedHashMap<>();row.put("test",name);long start=System.nanoTime();
    try(Tx t=new Tx()){context(t);seed(t);action.run(t);row.put("status","PASS");}
    catch(Throwable e){row.put("status","FAIL");row.put("type",e.getClass().getSimpleName());row.put("message",e.getMessage());}
    row.put("milliseconds",(System.nanoTime()-start)/1000000);results.add(row);
    System.out.println(JSON.valueToTree(row));
  }
  static void context(Tx t)throws Exception {
    context(t,true);
  }
  static void context(Tx t,boolean lock)throws Exception {
    t.run=UUID.randomUUID();
    t.sql("SET LOCAL uten.legacy_reference_import='synthetic-counter-adversarial'");
    t.sql("SET LOCAL app.legacy_import='on'");
    t.sql("INSERT INTO legacy_migration_runs(run_id,target,status,migration_mode,mapping_version,migration_repository_commit,export_manifest_sha256,checksum_manifest_sha256,migration_script_sha256,source_backup_sha256,export_approval_reference,reconciliation_summary) VALUES(?,'--bootstrap-all','RUNNING','BOOTSTRAP','bootstrap-v11',repeat('a',40),repeat('b',64),repeat('c',64),repeat('d',64),repeat('e',64),'synthetic-reviewed-source',jsonb_build_object('importAtomicity','single-transaction-v1','targetDatabase',current_database(),'targetApprovalReference','synthetic-reviewed-target','sourceSnapshotAsOfUtc','2025-01-31T15:59:59Z','targetSystemIdentifier',(SELECT system_identifier::text FROM pg_control_system())))",t.run);
    for(String f:List.of("purchase_order_items.csv","sales_order_items.csv","sales_shipment_items.csv","purchase_receipts.csv","purchase_receipt_items.csv"))t.sql("INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size) VALUES(?,?,repeat('f',64),500)",t.run,f);
    t.scalar("SELECT set_config('uten.bootstrap_run_id',?,true)",t.run.toString());
    t.sql("SET LOCAL uten.bootstrap_mapping_version='bootstrap-v11'");
    t.scalar("SELECT set_config('uten.bootstrap_repository_commit',?,true)","a".repeat(40));
    t.scalar("SELECT set_config('uten.bootstrap_manifest_sha',?,true)","b".repeat(64));
    if(lock)t.scalar("SELECT pg_advisory_xact_lock(hashtextextended('uten:legacy-bootstrap:'||current_database(),0))");
  }
  static void seed(Tx t)throws Exception {
    if(((Number)t.scalar("SELECT count(*) FROM clients WHERE legacy_id=900501")).intValue()>0)return;
    t.sql("INSERT INTO clients(legacy_id,code,name,status,code_sequence) VALUES(900501,'SYN-COUNT-C','Synthetic counter client','禁用',1)");
    t.sql("INSERT INTO suppliers(legacy_id,code,name,status,code_sequence) VALUES(900601,'SYN-COUNT-S','Synthetic counter supplier','禁用',1)");
    t.sql("INSERT INTO units(legacy_id,code,name) VALUES(900301,'SYN-COUNT-U','Synthetic unit')");
    t.sql("INSERT INTO colors(legacy_id,code,name) VALUES(900401,'SYN-COUNT-COLOR','Synthetic color')");
    t.sql("INSERT INTO warehouses(legacy_id,code,name) VALUES(900201,'SYN-COUNT-W','Synthetic warehouse')");
    t.sql("INSERT INTO goods(legacy_id,code,name,unit_id,code_sequence) SELECT 900102,'SYN-COUNT-G2','Synthetic goods 2',id,100102 FROM units WHERE legacy_id=900301");
    t.sql("INSERT INTO goods(legacy_id,code,name,unit_id,code_sequence) SELECT 900101,'SYN-COUNT-G1','Synthetic goods 1',id,100101 FROM units WHERE legacy_id=900301");
    t.sql("INSERT INTO purchase_orders(legacy_id,bill_no,bill_date,supplier_id,currency_id,exchange_rate,status) SELECT 901003,'SYN-PO','2025-01-02',s.id,c.id,1,0 FROM suppliers s CROSS JOIN currencies c WHERE s.legacy_id=900601 AND c.legacy_id=1");
    t.sql("INSERT INTO sales_orders(legacy_id,bill_no,bill_date,client_id,currency_id,exchange_rate,status) SELECT 903001,'SYN-SO','2025-01-02',s.id,c.id,1,0 FROM clients s CROSS JOIN currencies c WHERE s.legacy_id=900501 AND c.legacy_id=1");
    t.sql("INSERT INTO sales_shipments(legacy_id,bill_no,bill_date,client_id,currency_id,exchange_rate,status,finance_gate_version,warehouse_work_status,shipment_kind) SELECT 903003,'SYN-SS','2025-01-02',s.id,c.id,1,1,0,'SHIPPED','ORDER' FROM clients s CROSS JOIN currencies c WHERE s.legacy_id=900501 AND c.legacy_id=1");
  }
  static ObjectNode source(Tx t,Family f)throws Exception {
    String function=f.receipt?"fn_legacy_receipt_import_kind":"fn_legacy_quantity_counter_kind";
    String file=t.text("SELECT source_file FROM "+function+"(?)",f.kind);
    ObjectNode source=JSON.createObjectNode();
    try(PreparedStatement s=t.c.prepareStatement("SELECT unnest(source_keys) FROM "+function+"(?)")){s.setString(1,f.kind);try(ResultSet r=s.executeQuery()){while(r.next())source.putNull(r.getString(1));}}
    ObjectNode old=(ObjectNode)fixtures.get(file).get(0);old.fields().forEachRemaining(e->{if(source.has(e.getKey()))source.set(e.getKey(),e.getValue());});
    source.put("legacy_id",++identity);source.put("qty",10);source.put("price",new BigDecimal("2.5"));source.put("amount_original",25);
    if(source.has("request_item_legacy_id"))source.putNull("request_item_legacy_id");
    if(source.has("order_item_legacy_id"))source.putNull("order_item_legacy_id");
    if(source.has("order_item_legacy"))source.putNull("order_item_legacy");
    if(source.has("received_qty"))source.put("received_qty",f.counter.equals("returned_qty")?2:20);
    if(source.has("shipped_qty"))source.put("shipped_qty",f.counter.equals("returned_qty")?2:20);
    source.put("returned_qty",f.counter.equals("returned_qty")?20:0);
    if(f.receipt){
      ObjectNode header=JSON.createObjectNode();
      try(PreparedStatement s=t.c.prepareStatement("SELECT unnest(source_keys) FROM fn_legacy_receipt_import_kind('PURCHASE_HEADER')");ResultSet r=s.executeQuery()){while(r.next())header.putNull(r.getString(1));}
      ObjectNode h=(ObjectNode)fixtures.get("purchase_receipts.csv").get(0);h.fields().forEachRemaining(e->{if(header.has(e.getKey()))header.set(e.getKey(),e.getValue());});
      header.put("legacy_id",++identity);header.put("bill_no","SYN-PR-"+identity);header.putNull("salesman_legacy");header.putNull("receiver_legacy");header.putNull("settlement_style_legacy");
      UUID id=(UUID)t.scalar("SELECT fn_register_legacy_receipt_import_source(?,'PURCHASE_HEADER',?::jsonb)",t.run,header.toString());
      ObjectNode payload=project(t,"PURCHASE_HEADER",true,header);payload.put("id",id.toString());payload.put("legacy_import_run_id",t.run.toString());insert(t,"purchase_receipts",payload);
      source.put("bill_legacy_id",identity);
    }
    return source;
  }
  static ObjectNode project(Tx t,String kind,boolean receipt,ObjectNode source)throws Exception{return (ObjectNode)JSON.readTree(t.text("SELECT "+(receipt?"fn_legacy_receipt_source_projection":"fn_legacy_quantity_counter_source_projection")+"(?,?::jsonb)::text",kind,source.toString()));}
  static UUID register(Tx t,Family f,ObjectNode source)throws Exception{return (UUID)t.scalar("SELECT "+(f.receipt?"fn_register_legacy_receipt_import_source":"fn_register_legacy_quantity_counter_source")+"(?,?,?::jsonb)",t.run,f.kind,source.toString());}
  static ObjectNode payload(Tx t,Family f,ObjectNode source,UUID id)throws Exception {
    ObjectNode p=project(t,f.kind,f.receipt,source);p.put("id",id.toString());p.put(f.receipt?"legacy_import_run_id":"legacy_counter_import_run_id",t.run.toString());
    p.put("line_no",1);UUID goods=UUID.fromString(p.get("goods_id").asText());
    p.put("goods_code_snapshot",t.text("SELECT code FROM goods WHERE id=?",goods));p.put("goods_name_snapshot",t.text("SELECT name FROM goods WHERE id=?",goods));p.put("goods_snapshot_source","LEGACY_IMPORT");p.put("goods_snapshot_locked_at","2025-01-02T00:00:00Z");
    return p;
  }
  static void insert(Tx t,String table,ObjectNode p)throws Exception {List<String> fields=new ArrayList<>();p.fieldNames().forEachRemaining(fields::add);Collections.sort(fields);String columns=String.join(",",fields.stream().map(k->"\""+k+"\"").toList());t.sql("INSERT INTO public."+table+"("+columns+") SELECT "+columns+" FROM jsonb_populate_record(NULL::public."+table+",?::jsonb)",p.toString());}
  static UUID accept(Tx t,Family f,ObjectNode source)throws Exception {UUID id=register(t,f,source);insert(t,f.table,payload(t,f,source,id));return id;}
  static void runTests()throws Exception {
    for(Family f:families){String prefix=f.table+"."+f.counter;
      test(prefix+".exact_first_insert",t->{ObjectNode source=source(t,f);long stock=t.count("stock_movements"),ap=t.count("ar_ap_ledger"),arrival=t.count("procurement_arrival_exceptions"),approval=t.count("sales_shipment_finance_release_events");UUID id=accept(t,f,source);t.sql("SET CONSTRAINTS ALL IMMEDIATE");require(new BigDecimal(t.text("SELECT qty FROM "+f.table+" WHERE id=?",id)).compareTo(BigDecimal.TEN)==0,"original qty changed");require(new BigDecimal(t.text("SELECT price FROM "+f.table+" WHERE id=?",id)).compareTo(new BigDecimal("2.5"))==0,"price changed");require(new BigDecimal(t.text("SELECT amount_original FROM "+f.table+" WHERE id=?",id)).compareTo(new BigDecimal("25"))==0,"amount changed");require(new BigDecimal(t.text("SELECT "+f.counter+" FROM "+f.table+" WHERE id=?",id)).compareTo(new BigDecimal(source.get(f.counter).asText()))==0,"original cumulative counter changed");require(t.count("stock_movements")==stock&&t.count("ar_ap_ledger")==ap&&t.count("procurement_arrival_exceptions")==arrival&&t.count("sales_shipment_finance_release_events")==approval,"invented stock/finance/arrival");});
      test(prefix+".legacy_flags_without_proof_rejected",t->{ObjectNode source=source(t,f);ObjectNode p=payload(t,f,source,UUID.randomUUID());p.putNull(f.receipt?"legacy_import_run_id":"legacy_counter_import_run_id");denied(t,()->insert(t,f.table,p));});
      test(prefix+".later_increase_rejected",t->{UUID id=accept(t,f,source(t,f));denied(t,()->t.sql("UPDATE "+f.table+" SET "+f.counter+"="+f.counter+"+1 WHERE id=?",id));});
      test(prefix+".after_commit_increase_rejected",t->{UUID id=accept(t,f,source(t,f));t.sql("SET CONSTRAINTS ALL IMMEDIATE");t.c.commit();denied(t,()->t.sql("UPDATE "+f.table+" SET "+f.counter+"="+f.counter+"+1 WHERE id=?",id));});
      test(prefix+".corrective_decrease_preserved",t->{UUID id=accept(t,f,source(t,f));t.sql("UPDATE "+f.table+" SET "+f.counter+"="+f.counter+"-1 WHERE id=?",id);});
      test(prefix+".negative_rejected",t->{ObjectNode source=source(t,f);source.put(f.counter,-1);denied(t,()->accept(t,f,source));});
      test(prefix+".wrong_target_uuid_rejected",t->{ObjectNode source=source(t,f);register(t,f,source);denied(t,()->insert(t,f.table,payload(t,f,source,UUID.randomUUID())));});
      test(prefix+".wrong_run_rejected",t->{ObjectNode source=source(t,f);UUID id=register(t,f,source);ObjectNode p=payload(t,f,source,id);p.put(f.receipt?"legacy_import_run_id":"legacy_counter_import_run_id",UUID.randomUUID().toString());denied(t,()->insert(t,f.table,p));});
      for(String field:List.of("qty","price","amount_original",f.counter,"unit_rate","legacy_id"))test(prefix+".target_"+field+"_tamper_rejected",t->{ObjectNode source=source(t,f);UUID id=register(t,f,source);ObjectNode p=payload(t,f,source,id);p.put(field,new BigDecimal(p.get(field).asText()).add(BigDecimal.ONE));denied(t,()->insert(t,f.table,p));});
      test(prefix+".different_parent_rejected",t->{ObjectNode source=source(t,f);UUID id=register(t,f,source);ObjectNode p=payload(t,f,source,id);String parent=f.table.equals("sales_shipment_items")?"shipment_id":f.receipt?"receipt_id":"order_id";p.put(parent,UUID.randomUUID().toString());denied(t,()->insert(t,f.table,p));});
      test(prefix+".registered_file_sha_changed_rejected",t->{ObjectNode source=source(t,f);UUID id=register(t,f,source);String function=f.receipt?"fn_legacy_receipt_import_kind":"fn_legacy_quantity_counter_kind";String file=t.text("SELECT source_file FROM "+function+"(?)",f.kind);t.sql("UPDATE legacy_migration_run_files SET sha256=repeat('0',64) WHERE run_id=? AND file_name=?",t.run,file);denied(t,()->insert(t,f.table,payload(t,f,source,id)));});
      test(prefix+".source_shape_extra_key_rejected",t->{ObjectNode source=source(t,f);source.put("forged_capacity",999);denied(t,()->register(t,f,source));});
      test(prefix+".source_shape_missing_key_rejected",t->{ObjectNode source=source(t,f);source.remove("qty");denied(t,()->register(t,f,source));});
      test(prefix+".provenance_clear_rejected",t->{UUID id=accept(t,f,source(t,f));String column=f.receipt?"legacy_import_run_id":"legacy_counter_import_run_id";denied(t,()->t.sql("UPDATE "+f.table+" SET "+column+"=NULL WHERE id=?",id));});
      test(prefix+".provenance_rebind_rejected",t->{UUID id=accept(t,f,source(t,f));String column=f.receipt?"legacy_import_run_id":"legacy_counter_import_run_id";denied(t,()->t.sql("UPDATE "+f.table+" SET "+column+"=? WHERE id=?",UUID.randomUUID(),id));});
      test(prefix+".target_identity_rebind_rejected",t->{UUID id=accept(t,f,source(t,f));denied(t,()->t.sql("UPDATE "+f.table+" SET legacy_id=legacy_id+1000000 WHERE id=?",id));});
      test(prefix+".target_delete_replay_rejected",t->{UUID id=accept(t,f,source(t,f));denied(t,()->t.sql("DELETE FROM "+f.table+" WHERE id=?",id));});
      test(prefix+".new_online_row_counter_still_guarded",t->{ObjectNode source=source(t,f);ObjectNode p=payload(t,f,source,UUID.randomUUID());p.putNull("legacy_id");p.putNull(f.receipt?"legacy_import_run_id":"legacy_counter_import_run_id");denied(t,()->insert(t,f.table,p));});
      test(prefix+".evidence_delete_rejected",t->{ObjectNode source=source(t,f);UUID id=register(t,f,source);String table=f.receipt?"legacy_procurement_receipt_import_sources":"legacy_quantity_counter_import_sources";denied(t,()->t.sql("DELETE FROM "+table+" WHERE target_id=?",id));});
      test(prefix+".evidence_update_rejected",t->{ObjectNode source=source(t,f);UUID id=register(t,f,source);String table=f.receipt?"legacy_procurement_receipt_import_sources":"legacy_quantity_counter_import_sources";denied(t,()->t.sql("UPDATE "+table+" SET source_row_sha256=repeat('0',64) WHERE target_id=?",id));});
      for(String change:List.of("status='SUCCESS'","migration_mode='STANDARD'","finished_at=now()","mapping_version='bootstrap-v999'","migration_repository_commit=repeat('0',40)","export_manifest_sha256=repeat('0',64)","reconciliation_summary=jsonb_set(reconciliation_summary,'{targetDatabase}','\"wrong_database\"'::jsonb)","reconciliation_summary=jsonb_set(reconciliation_summary,'{targetSystemIdentifier}','\"wrong_system\"'::jsonb)"))test(prefix+".context_changed_"+change.split("=")[0]+"_rejected",t->{ObjectNode source=source(t,f);UUID id=register(t,f,source);denied(t,()->{t.sql("UPDATE legacy_migration_runs SET "+change+" WHERE run_id=?",t.run);insert(t,f.table,payload(t,f,source,id));});});
      List<String> newer=f.table.equals("purchase_order_items")?List.of("gift_qty","gift_received_qty","gift_returned_qty","arrival_overage_posted_qty","allowed_over_receipt_pct"):f.table.equals("sales_order_items")?List.of("reserved_qty","planned_qty","produced_qty"):f.receipt?List.of("gift_qty","gift_returned_qty","charged_base_qty","gift_base_qty"):List.of();
      for(String field:newer)test(prefix+".modern_"+field+"_tamper_rejected",t->{ObjectNode source=source(t,f);UUID id=register(t,f,source);ObjectNode p=payload(t,f,source,id);p.put(field,99);denied(t,()->insert(t,f.table,p));});
      if(f.table.startsWith("purchase_"))test(prefix+".modern_quantity_semantics_rejected",t->{ObjectNode source=source(t,f);UUID id=register(t,f,source);ObjectNode p=payload(t,f,source,id);p.put("quantity_semantics","CHARGED_PLUS_GIFT_V1");denied(t,()->insert(t,f.table,p));});
      if(!f.receipt){
        for(String change:List.of("target_fields=ARRAY['id']::text[]","issued_txid=issued_txid+1","source_file_sha256=repeat('0',64)","source_kind='UNKNOWN_KIND'","target_table='goods'"))test(prefix+".forged_evidence_"+change.split("=")[0]+"_rejected",t->{ObjectNode source=source(t,f);UUID id=register(t,f,source);String targetExpression="gen_random_uuid()";String changes=change;List<String> cols=List.of("id","run_id","source_kind","source_legacy_id","target_table","target_id","source_file","source_row_sha256","source_file_sha256","target_fields","target_snapshot_sha256","issued_txid");List<String> expr=new ArrayList<>();for(String col:cols){if(col.equals("id")||col.equals("target_id"))expr.add(targetExpression);else if(col.equals("source_legacy_id"))expr.add("source_legacy_id+1000000");else if(changes.startsWith(col+"="))expr.add(changes.substring(col.length()+1));else expr.add(col);}denied(t,()->t.sql("INSERT INTO legacy_quantity_counter_import_sources("+String.join(",",cols)+") SELECT "+String.join(",",expr)+" FROM legacy_quantity_counter_import_sources WHERE target_id=?",id));});
      }
      test(prefix+".proof_same_transaction_required",t->{ObjectNode source=source(t,f);UUID id=register(t,f,source);ObjectNode p=payload(t,f,source,id);t.c.commit();t.scalar("SELECT set_config('uten.bootstrap_run_id',?,true)",t.run.toString());t.sql("SET LOCAL uten.bootstrap_mapping_version='bootstrap-v11'");t.scalar("SELECT set_config('uten.bootstrap_repository_commit',?,true)","a".repeat(40));t.scalar("SELECT set_config('uten.bootstrap_manifest_sha',?,true)","b".repeat(64));t.scalar("SELECT pg_advisory_xact_lock(hashtextextended('uten:legacy-bootstrap:'||current_database(),0))");denied(t,()->insert(t,f.table,p));});
    }
    test("metadata.immutable_always_audit_none_reset_preserve",t->{require("PRESERVE".equals(t.text("SELECT disposition FROM fn_business_reset_table_policy() WHERE table_name='legacy_quantity_counter_import_sources'")),"reset policy must preserve proof");require(((Number)t.scalar("SELECT count(*) FROM pg_trigger WHERE tgrelid='legacy_quantity_counter_import_sources'::regclass AND tgname='trg_guard_legacy_quantity_counter_evidence' AND tgenabled='A'")).intValue()==1,"proof guard must be ALWAYS");require(((Number)t.scalar("SELECT count(*) FROM pg_trigger WHERE tgrelid='legacy_quantity_counter_import_sources'::regclass AND tgfoid='fn_audit()'::regprocedure")).intValue()==0,"current legacy/NONE policy must not create per-row audit");});
    test("runtime.login_cannot_mint_even_with_execute_granted",t->{Family f=families.get(0);ObjectNode source=source(t,f);try(Connection c=DriverManager.getConnection(url,"counter_runtime",runtimePassword)){c.setAutoCommit(false);try(PreparedStatement s=c.prepareStatement("SELECT fn_register_legacy_quantity_counter_source(?,?,?::jsonb)")){s.setObject(1,t.run);s.setString(2,f.kind);s.setString(3,source.toString());try{s.execute();throw new AssertionError("runtime login minted proof");}catch(SQLException expected){require(expected.getMessage().contains("dedicated migration identity"),"runtime refusal did not establish trusted-login boundary: "+expected.getSQLState());}finally{c.rollback();}}}});
    test("bootstrap.without_exclusive_lock_rejected",t->{t.c.commit();context(t,false);Family f=families.get(0);ObjectNode source=source(t,f);denied(t,()->register(t,f,source));});
    for(String setting:List.of("uten.bootstrap_run_id","uten.bootstrap_mapping_version","uten.bootstrap_repository_commit","uten.bootstrap_manifest_sha"))test("bootstrap.guc_"+setting+"_rejected",t->{Family f=families.get(0);ObjectNode source=source(t,f);UUID id=register(t,f,source);t.scalar("SELECT set_config(?,?,true)",setting,setting.endsWith("run_id")?UUID.randomUUID().toString():"wrong");denied(t,()->insert(t,f.table,payload(t,f,source,id)));});
    for(Family f:List.of(families.get(0),families.get(2)))test(f.table+".return_reversal_original_capacity_rule",t->{ObjectNode source=source(t,f);source.put("returned_qty",15);UUID id=accept(t,f,source);t.sql("UPDATE "+f.table+" SET returned_qty=14 WHERE id=?",id);denied(t,()->t.sql("UPDATE "+f.table+" SET returned_qty=0 WHERE id=?",id));});
  }
  static void benchmark(int size)throws Exception {
    try(Tx t=new Tx()) {
      context(t);seed(t);t.sql("SET LOCAL track_functions='all'");
      Family f=families.get(0);ObjectNode source=source(t,f);
      t.sql("CREATE TEMP TABLE counter_bench_source ON COMMIT DROP AS SELECT n,jsonb_set(?::jsonb,'{legacy_id}',to_jsonb(2000000+n)) source FROM generate_series(1,?::integer) n",source.toString(),size);
      long start=System.nanoTime();
      long registered=((Number)t.scalar("SELECT count(fn_register_legacy_quantity_counter_source(?,'PURCHASE_ORDER_ITEM',source)) FROM counter_bench_source",t.run)).longValue();
      long registerMillis=(System.nanoTime()-start)/1000000;
      ObjectNode prototype=payload(t,f,source,UUID.randomUUID());
      List<String> fields=new ArrayList<>();prototype.fieldNames().forEachRemaining(fields::add);Collections.sort(fields);
      String columns=String.join(",",fields.stream().map(k->"\""+k+"\"").toList());
      String selected=String.join(",",fields.stream().map(k->"projected.\""+k+"\"").toList());
      start=System.nanoTime();
      t.sql("INSERT INTO purchase_order_items("+columns+") SELECT "+selected+" FROM counter_bench_source staged JOIN legacy_quantity_counter_import_sources proof ON proof.run_id=? AND proof.source_kind='PURCHASE_ORDER_ITEM' AND proof.source_legacy_id=(staged.source->>'legacy_id')::integer CROSS JOIN LATERAL jsonb_populate_record(NULL::purchase_order_items, fn_legacy_quantity_counter_source_projection('PURCHASE_ORDER_ITEM',staged.source)||jsonb_build_object('id',proof.target_id,'legacy_counter_import_run_id',proof.run_id,'line_no',staged.n,'goods_code_snapshot','SYN-COUNT-G2','goods_name_snapshot','Synthetic goods 2','goods_snapshot_source','LEGACY_IMPORT','goods_snapshot_locked_at','2025-01-02T00:00:00Z')) projected ORDER BY staged.n",t.run);
      t.sql("SET CONSTRAINTS ALL IMMEDIATE");
      long insertMillis=(System.nanoTime()-start)/1000000;
      require(registered==size,"not all benchmark sources registered");
      require(((Number)t.scalar("SELECT count(*) FROM purchase_order_items WHERE legacy_counter_import_run_id=? AND qty=10 AND received_qty=20 AND returned_qty=0 AND gift_qty=0 AND gift_received_qty=0 AND gift_returned_qty=0 AND arrival_overage_posted_qty=0 AND allowed_over_receipt_pct IS NULL",t.run)).longValue()==size,"benchmark original/default quantities changed");
      require(((Number)t.scalar("SELECT count(*) FROM pg_trigger WHERE tgrelid IN('purchase_order_items'::regclass,'legacy_quantity_counter_import_sources'::regclass) AND tgenabled='D'")).intValue()==0,"benchmark disabled a production trigger");
      UUID id=(UUID)t.scalar("SELECT target_id FROM legacy_quantity_counter_import_sources WHERE run_id=? LIMIT 1",t.run);
      int legacy=((Number)t.scalar("SELECT source_legacy_id FROM legacy_quantity_counter_import_sources WHERE target_id=?",id)).intValue();
      Map<String,Object> result=new LinkedHashMap<>();result.put("rows",size);result.put("register_milliseconds",registerMillis);result.put("insert_and_deferred_milliseconds",insertMillis);result.put("all_production_guards_enabled",true);
      result.put("exact_proof_lookup_plan",JSON.readTree(t.text("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT * FROM legacy_quantity_counter_import_sources WHERE run_id=? AND target_id=? AND target_table='purchase_order_items' AND source_legacy_id=?",t.run,id,legacy)));
      result.put("target_identity_lookup_plan",JSON.readTree(t.text("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT EXISTS(SELECT 1 FROM purchase_order_items WHERE id=? OR legacy_id=?)",id,legacy)));
      result.put("tracked_function_calls",JSON.readTree(t.text("SELECT coalesce(jsonb_agg(jsonb_build_object('function',funcname,'calls',calls,'total_ms',total_time,'self_ms',self_time) ORDER BY total_time DESC),'[]'::jsonb)::text FROM pg_stat_xact_user_functions WHERE calls>0")));
      benchmarks.add(result);System.out.println("SYNTHETIC_COUNTER_BENCHMARK rows="+size+" register_ms="+registerMillis+" insert_ms="+insertMillis);
    }
  }

  static void financeSeed(Tx t)throws Exception {
    t.sql("INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size) VALUES(?,'m_get.csv',repeat('f',64),500)",t.run);
    if(((Number)t.scalar("SELECT count(*) FROM payment_styles WHERE legacy_id=906010")).intValue()>0){t.sql("SET LOCAL uten.payment_style_reference_import='off'");return;}
    t.sql("SET LOCAL uten.payment_style_reference_import='legacy-finance-v1'");
    t.sql("INSERT INTO payment_styles(legacy_id,code,name,category,status,is_receipt,is_payment) VALUES(906010,'SYN-V912-ACC','Synthetic finance account leaf','ACCOUNT','使用',true,true)");
    t.sql("INSERT INTO accounts(legacy_id,code,name,account_type,currency_id,style_id,status) SELECT 906001,'SYN-V912-ACCOUNT','Synthetic cash account','CASH',c.id,s.id,'使用' FROM currencies c CROSS JOIN payment_styles s WHERE c.legacy_id=1 AND s.legacy_id=906010");
    t.sql("INSERT INTO payment_styles(legacy_id,code,name,category,status,is_receipt,is_payment) VALUES(1,'SYN-M1','Synthetic original sales income','INCOME','使用',true,false),(4,'SYN-M4','Synthetic original other income','INCOME','使用',true,false),(20,'SYN-M20','Synthetic original expense','EXPENSE','使用',false,true),(23,'SYN-M23','Synthetic original expense two','EXPENSE','使用',false,true)");
    t.sql("SET LOCAL uten.payment_style_reference_import='off'");
  }
  static ObjectNode financeSource(Tx t,Integer style)throws Exception {
    ObjectNode s=JSON.createObjectNode();
    try(PreparedStatement q=t.c.prepareStatement("SELECT unnest(source_keys) FROM fn_legacy_finance_kind('RECEIPT')");ResultSet r=q.executeQuery()){while(r.next())s.putNull(r.getString(1));}
    ObjectNode template=(ObjectNode)fixtures.get("m_get.csv").get(0);template.fields().forEachRemaining(e->{if(s.has(e.getKey()))s.set(e.getKey(),e.getValue());});
    s.put("legacy_id",++identity);s.put("bill_no","SYN-V912-R-"+identity);s.put("client_legacy_id",900501);s.put("rec_acc",906001);s.put("cur_id",1);s.put("crate",1);s.put("total",10);s.put("mtotal",10);s.put("qtfy",2);s.put("slf",0);
    if(style==null)s.putNull("qtfymc");else s.put("qtfymc",style);
    return s;
  }
  static UUID financeImport(Tx t,ObjectNode s)throws Exception {return (UUID)t.scalar("SELECT fn_import_legacy_finance_source(?,'RECEIPT',?::jsonb,NULL)",t.run,s.toString());}
  static ObjectNode financePayload(Tx t,ObjectNode s,UUID id)throws Exception {ObjectNode p=(ObjectNode)JSON.readTree(t.text("SELECT fn_legacy_finance_cash_projection('RECEIPT',?::jsonb,NULL)::text",s.toString()));p.put("id",id.toString());p.put("legacy_import_run_id",t.run.toString());return p;}
  static UUID mintFinanceProof(Tx t,ObjectNode s,boolean old)throws Exception {
    UUID id=UUID.randomUUID();ObjectNode p=financePayload(t,s,id);if(old)p.remove("other_fee_style_legacy_id");List<String> fields=new ArrayList<>();p.fieldNames().forEachRemaining(fields::add);Collections.sort(fields);
    t.sql("INSERT INTO legacy_finance_import_sources(run_id,source_kind,source_legacy_id,target_table,target_id,source_file,source_row_sha256,source_file_sha256,target_fields,target_snapshot_sha256,initial_state,issued_txid) SELECT ?,'RECEIPT',?,'finance_receipts',?,'m_get.csv',encode(digest(?::jsonb::text,'sha256'),'hex'),sha256,?::text[],encode(digest(fn_legacy_finance_snapshot(?::jsonb,?::text[])::text,'sha256'),'hex'),'{}'::jsonb,txid_current() FROM legacy_migration_run_files WHERE run_id=? AND file_name='m_get.csv'",t.run,s.get("legacy_id").asInt(),id,s.toString(),t.c.createArrayOf("text",fields.toArray()),p.toString(),t.c.createArrayOf("text",fields.toArray()),t.run);
    return id;
  }
  static void focused()throws Exception {
    for(int ref:List.of(1,4,99999))test("V912.original_nonexpense_or_missing_"+ref+"_preserved_pending",t->{financeSeed(t);long gl=t.count("gl_entries"),ar=t.count("ar_ap_ledger"),flows=t.count("finance_reconciliations");UUID id=financeImport(t,financeSource(t,ref));t.sql("SET CONSTRAINTS ALL IMMEDIATE");require(Integer.toString(ref).equals(t.text("SELECT other_fee_style_legacy_id FROM finance_receipts WHERE id=?",id)),"raw ID lost");require(t.scalar("SELECT other_fee_style_id FROM finance_receipts WHERE id=?",id)==null,"wrong expense invented");require(new BigDecimal(t.text("SELECT other_fee FROM finance_receipts WHERE id=?",id)).compareTo(new BigDecimal("2"))==0,"fee changed");require(t.count("gl_entries")==gl&&t.count("ar_ap_ledger")==ar&&t.count("finance_reconciliations")==flows,"new finance facts invented");});
    for(Integer ref:Arrays.asList(null,0))test("V912.zero_null_"+ref,t->{financeSeed(t);UUID id=financeImport(t,financeSource(t,ref));require(t.scalar("SELECT other_fee_style_legacy_id FROM finance_receipts WHERE id=?",id)==null,"empty original ID converted to identity");});
    test("V912.original_expense_uuid_retained",t->{financeSeed(t);UUID id=financeImport(t,financeSource(t,20));require(t.scalar("SELECT other_fee_style_id FROM finance_receipts WHERE id=?",id).equals(t.scalar("SELECT id FROM payment_styles WHERE legacy_id=20")),"expense UUID replaced");});
    test("V912.historical_inactive_nonleaf_expense_still_exact",t->{financeSeed(t);t.sql("SET LOCAL uten.payment_style_reference_import='legacy-finance-v1'");t.sql("UPDATE payment_styles SET status='禁用' WHERE legacy_id=20");t.sql("INSERT INTO payment_styles(legacy_id,code,name,category,status,parent_id) SELECT 990020,'SYN-V912-CHILD','Synthetic child','EXPENSE','使用',id FROM payment_styles WHERE legacy_id=20");UUID id=financeImport(t,financeSource(t,20));require(t.scalar("SELECT other_fee_style_id FROM finance_receipts WHERE id=?",id).equals(t.scalar("SELECT id FROM payment_styles WHERE legacy_id=20")),"historical parent/inactive expense was replaced");});
    test("V912.negative_original_ref_requires_review",t->{financeSeed(t);denied(t,()->financeImport(t,financeSource(t,-1)));});
    for(String field:List.of("other_fee_style_legacy_id","other_fee","amount_original","amount_local"))test("V912.signed_"+field+"_tamper",t->{financeSeed(t);ObjectNode s=financeSource(t,1);UUID id=mintFinanceProof(t,s,false);ObjectNode p=financePayload(t,s,id);p.put(field,999);denied(t,()->insert(t,"finance_receipts",p));});
    test("V912.signed_null_typed_cannot_be_income_or_unrelated_expense",t->{financeSeed(t);ObjectNode s=financeSource(t,1);UUID id=mintFinanceProof(t,s,false);ObjectNode p=financePayload(t,s,id);for(int ref:List.of(1,20)){p.put("other_fee_style_id",t.text("SELECT id FROM payment_styles WHERE legacy_id=?",ref));denied(t,()->insert(t,"finance_receipts",p));}});
    test("V912.signed_positive_raw_cannot_be_cleared",t->{financeSeed(t);ObjectNode s=financeSource(t,1);UUID id=mintFinanceProof(t,s,false);ObjectNode p=financePayload(t,s,id);p.putNull("other_fee_style_legacy_id");denied(t,()->insert(t,"finance_receipts",p));});
    test("V912.legacy_flags_without_proof_cannot_add_raw",t->{financeSeed(t);ObjectNode p=financePayload(t,financeSource(t,1),UUID.randomUUID());p.putNull("legacy_id");p.putNull("legacy_import_run_id");p.put("receipt_kind","AR_SETTLEMENT");p.put("status",0);denied(t,()->insert(t,"finance_receipts",p));});
    test("V912.old_proof_accepts_only_null_new_column",t->{financeSeed(t);ObjectNode s=financeSource(t,0);UUID id=mintFinanceProof(t,s,true);ObjectNode p=financePayload(t,s,id);insert(t,"finance_receipts",p);});
    test("V912.old_proof_cannot_add_unsigned_raw",t->{financeSeed(t);ObjectNode s=financeSource(t,0);UUID id=mintFinanceProof(t,s,true);ObjectNode p=financePayload(t,s,id);p.put("other_fee_style_legacy_id",1);denied(t,()->insert(t,"finance_receipts",p));});
    for(String value:List.of("NULL","4"))test("V912.persisted_raw_cannot_change_"+value,t->{financeSeed(t);UUID id=financeImport(t,financeSource(t,1));t.c.commit();denied(t,()->t.sql("UPDATE finance_receipts SET other_fee_style_legacy_id="+value+" WHERE id=?",id));});
    test("V912.wrong_file_sha_rejected",t->{financeSeed(t);ObjectNode s=financeSource(t,1);UUID id=mintFinanceProof(t,s,false);t.sql("UPDATE legacy_migration_run_files SET sha256=repeat('0',64) WHERE run_id=? AND file_name='m_get.csv'",t.run);denied(t,()->insert(t,"finance_receipts",financePayload(t,s,id)));});
    test("V912.proof_cross_transaction_rejected",t->{financeSeed(t);ObjectNode s=financeSource(t,1);UUID id=mintFinanceProof(t,s,false);ObjectNode p=financePayload(t,s,id);t.c.commit();denied(t,()->insert(t,"finance_receipts",p));});
    test("V912.ordinary_runtime_expense_guard_unchanged",t->{financeSeed(t);ObjectNode p=financePayload(t,financeSource(t,0),UUID.randomUUID());p.putNull("legacy_id");p.putNull("legacy_import_run_id");p.put("receipt_kind","AR_SETTLEMENT");p.put("status",0);p.put("other_fee_style_id",t.text("SELECT id FROM payment_styles WHERE legacy_id=1"));denied(t,()->insert(t,"finance_receipts",p));});
    test("V912.historical_commercial_amounts_still_immutable",t->{financeSeed(t);UUID id=financeImport(t,financeSource(t,1));denied(t,()->t.sql("UPDATE finance_receipts SET other_fee=0 WHERE id=?",id));denied(t,()->t.sql("DELETE FROM finance_receipts WHERE id=?",id));});
  }

  public static void main(String[] args)throws Exception {
    url=args[0];user=args[1];password=args[2];fixtures=JSON.readTree(Files.readString(Path.of(args[4])));
    var migrated=Flyway.configure().dataSource(url,user,password).locations("filesystem:"+args[3]).initSql("SET client_min_messages = WARNING").cleanDisabled(true).load().migrate();
    System.out.println("SYNTHETIC_FULL_FLYWAY_READY count="+migrated.migrationsExecuted+" version="+migrated.targetSchemaVersion);
    try(Connection setup=DriverManager.getConnection(url,user,password);Statement s=setup.createStatement()){s.execute("CREATE ROLE counter_runtime LOGIN NOSUPERUSER NOINHERIT PASSWORD '"+runtimePassword+"'");s.execute("GRANT USAGE ON SCHEMA public TO counter_runtime");s.execute("GRANT EXECUTE ON FUNCTION fn_register_legacy_quantity_counter_source(uuid,text,jsonb) TO counter_runtime");}
    focused();
    if(args.length>6&&args[6].equals("--benchmark")){benchmark(1000);benchmark(5000);}
    Map<String,Object> receipt=new LinkedHashMap<>();receipt.put("synthetic_only",true);receipt.put("business_candidate_connected",false);receipt.put("full_flyway_version",migrated.targetSchemaVersion);receipt.put("migration_count",migrated.migrationsExecuted);receipt.put("tests",results);receipt.put("benchmarks",benchmarks);receipt.put("passed",results.stream().filter(r->r.get("status").equals("PASS")).count());receipt.put("failed",results.stream().filter(r->r.get("status").equals("FAIL")).count());
    Files.writeString(Path.of(args[5]),JSON.writerWithDefaultPrettyPrinter().writeValueAsString(receipt));
    if(results.stream().anyMatch(r->r.get("status").equals("FAIL")))System.exit(2);
  }
}
