package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.support.ProcurementReceiptFixtureSupport;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.Query;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Real current-schema query equivalence. Source facts commit with every database guard enabled. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class MaterialAnalysisSupplyWakeupQueryPostgresTest {
    private static final PostgreSQLContainer DB=new PostgreSQLContainer("postgres:16-alpine");
    private static final AtomicInteger NUMBERS=new AtomicInteger(860000);
    private static JdbcTemplate db;
    private static EntityManagerFactory factory;
    private static EntityManager em;
    private static MaterialAnalysisSupplyWakeupService service;
    private static UUID unit,actor,maker;
    private static String lastSql;
    // Freeze the shared normal-receipt selector and the two reversal-only selectors.
    // The approved/reversed/partial/legacy cases below validate the intentional query consolidation.
    private static final Map<String,String> DIMENSION_HASHES=Map.of(
            "resolvedReceiptTargets","2f2c9c4957757402936f3b015814ceec47a4bd30a022a9b9e70ddb6942c634a0",
            "reversedPurchaseTargets","497aa0245220e5b1801cf1120a5221dcb92ffe2ee6042176ff0e41aa639f20d4",
            "reversedSubcontractTargets","2281fb4e6a997716ad7e72db4d756343c99e8d931a65894faa27f1347b7bf354");
    // Independent, pre-change selector. This is intentionally not constructed from the new candidate filter.
    private static final String OLD_SELECTOR="""
            SELECT analysis.id, analysis.maker_id
            FROM production_material_analyses analysis
            WHERE analysis.is_deleted = FALSE
              AND (analysis.status IN ('ACTIVE','PARTIALLY_PLANNED')
                OR analysis.status='COMPLETED'
                  AND fn_material_analysis_fulfillment_status(analysis.id)<>'COMPLETED')
              AND analysis.warehouse_id IS NOT NULL
              AND EXISTS (
                  SELECT 1 FROM production_material_analysis_materials material
                  JOIN dimensions dimension
                    ON fn_warehouse_same_main(dimension.warehouse_id,analysis.warehouse_id)
                   AND dimension.goods_id = material.goods_id
                   AND dimension.color_id IS NOT DISTINCT FROM material.color_id
                  WHERE material.analysis_id = analysis.id AND material.active = TRUE)
            ORDER BY analysis.id
            """;

    @BeforeAll static void start() throws Exception {
        DB.start();
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword())
                .locations("classpath:db/migration").load().migrate();
        var source=new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());db=new JdbcTemplate(source);
        var builder=new LocalContainerEntityManagerFactoryBean();builder.setDataSource(source);
        builder.setJpaVendorAdapter(new HibernateJpaVendorAdapter());builder.setPackagesToScan("com.uten.imp.features.common.taskclaim");
        Properties properties=new Properties();properties.setProperty("hibernate.hbm2ddl.auto","none");builder.setJpaProperties(properties);builder.afterPropertiesSet();
        factory=builder.getObject();em=factory.createEntityManager();
        EntityManager observer=mock(EntityManager.class);
        when(observer.createNativeQuery(anyString())).thenAnswer(call->{lastSql=call.getArgument(0);return em.createNativeQuery(lastSql);});
        // Only query discovery is invoked; no refresh, locking or notification collaborator is mocked out of a write path.
        service=new MaterialAnalysisSupplyWakeupService(observer,null,null,null,
                mock(com.uten.imp.features.notice.ChainNoticeService.class));
        unit=UUID.randomUUID();db.update("INSERT INTO units(id,code,name) VALUES (?,?,'wakeup piece')",unit,"WU-U-"+unit);
        try(var connection=connection()){connection.setAutoCommit(false);actor=ProcurementReceiptFixtureSupport.createActor(connection);connection.commit();}
        maker=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);
    }
    @AfterAll static void stop(){if(em!=null){ em.close(); }if(factory!=null){ factory.close(); }DB.stop();}

    @Test void purchaseAndSubcontractKeepApprovalReverseAndLegacyDimensions() throws Exception {
        for(String type:List.of("PURCHASE","SUBCONTRACT")){
            Scope scope=scope();
            Receipt resolved=receipt(type,scope.leaf(),scope.goods(),null,1,"RESOLVED",false);
            assertReceiptTargets(type,resolved.id(),false,scope.expected());
            assertReceiptTargets(type,resolved.id(),true,List.of());
            Receipt reversed=receipt(type,scope.leaf(),scope.goods(),null,-1,"REVERSED",false);
            assertReceiptTargets(type,reversed.id(),true,scope.expected());
            assertReceiptTargets(type,reversed.id(),false,List.of());
            Receipt legacy=receipt(type,scope.leaf(),scope.goods(),null,-1,null,false);
            assertReceiptTargets(type,legacy.id(),true,scope.expected());
            // Reversed IQC keeps its colored dimension and excludes the null-color analyses.
            Receipt mismatchedLegacy=receipt(type,scope.leaf(),scope.goods(),scope.blue(),-1,"REVERSED",false);
            assertReceiptTargets(type,mismatchedLegacy.id(),true,List.of(scope.colored()));
            db.update("UPDATE "+type.toLowerCase(Locale.ROOT)+"_receipts SET is_deleted=TRUE WHERE id=?",legacy.id());
            assertReceiptTargets(type,legacy.id(),true,List.of());
        }
    }

    @Test void partialIqcUsesOnlyActuallyStockedSelectedRowsOfTheApprovedReceipt() throws Exception {
        for(String type:List.of("PURCHASE","SUBCONTRACT")){
            Scope scope=scope();Receipt partial=receipt(type,scope.leaf(),scope.goods(),null,1,"PARTIAL",true);
            assertEquals("PARTIAL",db.queryForObject("SELECT status FROM procurement_inspection_items WHERE id=?",String.class,partial.inspection()));
            assertEquals(0,new BigDecimal("4").compareTo(db.queryForObject("SELECT warehouse_stocked_base_qty FROM procurement_inspection_items WHERE id=?",BigDecimal.class,partial.inspection())));
            Map<String,Object> params=Map.of("sourceType",type,"sourceDocumentId",partial.id(),"inspectionItemIds",List.of(partial.inspection()));
            assertTargets("inspectionStockInTargets",new Object[]{type,partial.id(),List.of(partial.inspection())},params,scope.expected());
            assertReceiptTargets(type,partial.id(),false,List.of());
            Receipt pendingWarehouse=receipt(type,scope.leaf(),scope.goods(),null,1,"PARTIAL",false);
            assertTargets("inspectionStockInTargets",new Object[]{type,pendingWarehouse.id(),List.of(pendingWarehouse.inspection())},
                    Map.of("sourceType",type,"sourceDocumentId",pendingWarehouse.id(),"inspectionItemIds",List.of(pendingWarehouse.inspection())),List.of());
            assertTargets("inspectionStockInTargets",new Object[]{type,partial.id(),List.of(pendingWarehouse.inspection())},
                    Map.of("sourceType",type,"sourceDocumentId",partial.id(),"inspectionItemIds",List.of(pendingWarehouse.inspection())),List.of());
            String wrongType=type.equals("PURCHASE")?"SUBCONTRACT":"PURCHASE";
            assertTargets("inspectionStockInTargets",new Object[]{wrongType,partial.id(),List.of(partial.inspection())},
                    Map.of("sourceType",wrongType,"sourceDocumentId",partial.id(),"inspectionItemIds",List.of(partial.inspection())),List.of());
        }
    }

    @Test void finishedInboundKeepsStatusNullColorSameMainAndReopenedCompletion() throws Exception {
        Scope scope=scope();
        for(int status:List.of(1,-1,0)){
            UUID document=finished(scope.leaf(),scope.goods(),null,status);
            assertTargets("finishedInboundTargets",new Object[]{document,1},Map.of("sourceDocumentId",document,"requiredStatus",1),status==1?scope.expected():List.of());
            assertTargets("finishedInboundTargets",new Object[]{document,-1},Map.of("sourceDocumentId",document,"requiredStatus",-1),status==-1?scope.expected():List.of());
        }
        UUID colored=finished(scope.leaf(),scope.goods(),scope.blue(),1);
        assertTargets("finishedInboundTargets",new Object[]{colored,1},Map.of("sourceDocumentId",colored,"requiredStatus",1),List.of(scope.colored()));
    }

    @Test void mixedStockInBatchUsesEachApprovedReceiptAndDeduplicatesSharedAnalysis() throws Exception {
        Scope scope = scope();
        Receipt purchase = receipt("PURCHASE", scope.leaf(), scope.goods(), null, 1, "PARTIAL", true);
        Receipt subcontract = receipt("SUBCONTRACT", scope.leaf(), scope.goods(), null, 1, "RESOLVED", false);
        Receipt pending = receipt("PURCHASE", scope.leaf(), scope.goods(), scope.blue(), 1, "PARTIAL", false);
        var batches = List.of(
                new com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn(
                        "PURCHASE", purchase.id(), UUID.randomUUID(), List.of(purchase.inspection())),
                new com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn(
                        "SUBCONTRACT", subcontract.id(), UUID.randomUUID(), List.of(subcontract.inspection())),
                new com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn(
                        "PURCHASE", pending.id(), UUID.randomUUID(), List.of(pending.inspection())));
        var selector = MaterialAnalysisSupplyWakeupService.class.getDeclaredMethod("inspectionStockInTargets", List.class);
        selector.setAccessible(true);
        @SuppressWarnings("unchecked")
        var targets = (List<MaterialAnalysisSupplyWakeupService.AnalysisTarget>) selector.invoke(service, batches);
        assertEquals(scope.expected().stream().sorted(Comparator.comparing(UUID::toString)).toList(),
                targets.stream().map(MaterialAnalysisSupplyWakeupService.AnalysisTarget::analysisId).toList());
        assertFalse(targets.stream().anyMatch(target -> target.analysisId().equals(scope.colored())),
                "Unstocked partial inspection rows must not wake their colored analysis");
    }

    @Test void mixedResolvedReportUsesTheSameReceiptContractAndRejectsPartialReversedOrForeignType() throws Exception {
        Scope scope=scope();
        Receipt purchase=receipt("PURCHASE",scope.leaf(),scope.goods(),null,1,"RESOLVED",false);
        Receipt subcontract=receipt("SUBCONTRACT",scope.leaf(),scope.goods(),null,1,"RESOLVED",false);
        Receipt partial=receipt("PURCHASE",scope.leaf(),scope.goods(),scope.blue(),1,"PARTIAL",false);
        Receipt reversed=receipt("SUBCONTRACT",scope.leaf(),scope.goods(),scope.blue(),-1,"REVERSED",false);
        var refs=List.of(
                new com.uten.imp.application.port.ProductionInspectionStockInPort.ResolvedReceipt("PURCHASE",purchase.id()),
                new com.uten.imp.application.port.ProductionInspectionStockInPort.ResolvedReceipt("PURCHASE",partial.id()),
                new com.uten.imp.application.port.ProductionInspectionStockInPort.ResolvedReceipt("SUBCONTRACT",subcontract.id()),
                new com.uten.imp.application.port.ProductionInspectionStockInPort.ResolvedReceipt("SUBCONTRACT",reversed.id()));
        var params=Map.<String,Object>of("purchaseReceiptIds",joined(List.of(purchase.id(),partial.id())),
                "subcontractReceiptIds",joined(List.of(subcontract.id(),reversed.id())));
        assertTargets("resolvedReceiptTargets",new Object[]{refs},params,scope.expected());
        assertReceiptTargets("SUBCONTRACT",purchase.id(),false,List.of());
    }

    @Test void actualImportedSourceReceiptsKeepTheirImmutableFactsAndNeverWakeNativeAnalyses() throws Exception {
        Map<String,UUID> retained=importRetainedSourceReceipts();
        for(String type:List.of("PURCHASE","SUBCONTRACT")) {
            Scope scope=scope();Receipt nativeReceipt=receipt(type,scope.leaf(),scope.goods(),null,1,"RESOLVED",false);
            String header=type.toLowerCase(Locale.ROOT)+"_receipts",items=type.toLowerCase(Locale.ROOT)+"_receipt_items";
            UUID original=retained.get(type);
            assertFalse(Boolean.TRUE.equals(db.queryForObject("SELECT fn_imported_business_document(?,?)",Boolean.class,header,nativeReceipt.id())));
            assertTrue(Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM pg_constraint WHERE contype='f' AND conrelid=CAST(? AS regclass) AND confrelid=CAST(? AS regclass))",Boolean.class,items,header)));
            assertTrue(Boolean.TRUE.equals(db.queryForObject("SELECT fn_imported_business_document(?,?)",Boolean.class,header,original)));
            assertTrue(Boolean.TRUE.equals(db.queryForObject("SELECT bool_and(fn_imported_business_document(?,item.id)) FROM "+items+" item WHERE receipt_id=?",Boolean.class,items,original)));
            String before=db.queryForObject("SELECT to_jsonb(receipt)::text FROM "+header+" receipt WHERE id=?",String.class,original);
            var denied=assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE "+header+" SET legacy_id=legacy_id+1 WHERE id=?",original));
            assertEquals("55000",((java.sql.SQLException)denied.getMostSpecificCause()).getSQLState());
            assertEquals(before,db.queryForObject("SELECT to_jsonb(receipt)::text FROM "+header+" receipt WHERE id=?",String.class,original));
            // Imported source rows do not acquire fabricated IQC/warehouse decisions.
            assertReceiptTargets(type,original,false,List.of());
            assertReceiptTargets(type,nativeReceipt.id(),false,scope.expected());
            assertReceiptTargets(type,UUID.randomUUID(),false,List.of());
        }
    }

    private static Map<String,UUID> importRetainedSourceReceipts() throws Exception {
        Map<String,UUID> headers=new LinkedHashMap<>();
        try(var connection=connection()) {
            connection.setAutoCommit(false);
            var jdbc=new JdbcTemplate(new org.springframework.jdbc.datasource.SingleConnectionDataSource(connection,true));
            UUID run=com.uten.imp.support.LegacyFinanceImportFixture.context(jdbc);
            com.uten.imp.support.LegacyFinanceImportFixture.seed(jdbc);
            jdbc.update("INSERT INTO units(legacy_id,code,name) VALUES(900301,'WAKEUP-OLD-U','Real source fixture unit')");
            jdbc.update("INSERT INTO warehouses(legacy_id,code,name) VALUES(900201,'WAKEUP-OLD-W','Real source fixture warehouse')");
            for(int legacy:List.of(900101,900102))jdbc.update("INSERT INTO goods(legacy_id,code,name,unit_id,code_sequence) SELECT ?,?,'Source goods',id,(SELECT coalesce(max(code_sequence),0)+1 FROM goods) FROM units WHERE legacy_id=900301",legacy,"WAKEUP-OLD-G-"+legacy);
            var mapper=new ObjectMapper();
            for(String kind:List.of("PURCHASE_HEADER","PURCHASE_ITEM","SUBCONTRACT_HEADER","SUBCONTRACT_ITEM")) {
                String file=jdbc.queryForObject("SELECT source_file FROM fn_legacy_receipt_import_kind(?)",String.class,kind);
                jdbc.update("INSERT INTO legacy_migration_run_files(run_id,file_name,sha256,byte_size) VALUES(?,?,repeat('f',64),500)",run,file);
                var source=mapper.createObjectNode();
                jdbc.queryForList("SELECT unnest(source_keys) FROM fn_legacy_receipt_import_kind(?)",String.class,kind).forEach(source::putNull);
                source.setAll((com.fasterxml.jackson.databind.node.ObjectNode)mapper.readTree(com.uten.imp.support.LegacyFinanceImportFixture.source(file)));
                if(kind.endsWith("_ITEM")){source.putNull("order_item_legacy_id");source.putNull("color_legacy_id");}
                UUID id=jdbc.queryForObject("SELECT fn_register_legacy_receipt_import_source(?,?,?::jsonb)",UUID.class,run,kind,source.toString());
                var payload=(com.fasterxml.jackson.databind.node.ObjectNode)mapper.readTree(jdbc.queryForObject("SELECT fn_legacy_receipt_source_projection(?,?::jsonb)::text",String.class,kind,source.toString()));
                payload.put("id",id.toString());payload.put("legacy_import_run_id",run.toString());
                if(kind.endsWith("_ITEM")) {
                    UUID goods=UUID.fromString(payload.get("goods_id").asText());payload.put("line_no",1);
                    payload.put("goods_code_snapshot",jdbc.queryForObject("SELECT code FROM goods WHERE id=?",String.class,goods));
                    payload.put("goods_name_snapshot",jdbc.queryForObject("SELECT name FROM goods WHERE id=?",String.class,goods));
                    payload.put("goods_snapshot_source","LEGACY_IMPORT");payload.put("goods_snapshot_locked_at","2025-01-02T00:00:00Z");
                } else headers.put(kind.startsWith("PURCHASE")?"PURCHASE":"SUBCONTRACT",id);
                String table=jdbc.queryForObject("SELECT target_table FROM fn_legacy_receipt_import_kind(?)",String.class,kind);
                String columns=java.util.stream.StreamSupport.stream(java.util.Spliterators.spliteratorUnknownSize(payload.fieldNames(),0),false).sorted().map(key->'"'+key+'"').collect(java.util.stream.Collectors.joining(","));
                jdbc.update("INSERT INTO public."+table+"("+columns+") SELECT "+columns+" FROM jsonb_populate_record(NULL::public."+table+",?::jsonb)",payload.toString());
            }
            jdbc.execute("SET CONSTRAINTS ALL IMMEDIATE");connection.commit();
        }
        return headers;
    }

    @Test void finishedInboundBatchCombinesApprovedDocumentsWithoutAdmittingDraftOrReversedRows() throws Exception {
        Scope scope = scope();
        UUID first = finished(scope.leaf(), scope.goods(), null, 1);
        UUID second = finished(scope.leaf(), scope.goods(), null, 1);
        UUID draft = finished(scope.leaf(), scope.goods(), scope.blue(), 0);
        UUID reversed = finished(scope.leaf(), scope.goods(), scope.blue(), -1);
        var selector = MaterialAnalysisSupplyWakeupService.class.getDeclaredMethod(
                "finishedInboundTargets", Collection.class, int.class);
        selector.setAccessible(true);
        @SuppressWarnings("unchecked")
        var targets = (List<MaterialAnalysisSupplyWakeupService.AnalysisTarget>) selector.invoke(
                service, List.of(first, second, first, draft, reversed), 1);
        assertEquals(scope.expected().stream().sorted(Comparator.comparing(UUID::toString)).toList(),
                targets.stream().map(MaterialAnalysisSupplyWakeupService.AnalysisTarget::analysisId).toList());
    }

    @Test void unrelatedHistoryIsExcludedBeforeExpensivePredicatesWithRepeatedExplainEvidence() throws Exception {
        Scope scope=scope();Receipt source=receipt("PURCHASE",scope.leaf(),scope.goods(),null,1,"RESOLVED",false);
        Map<String,Object> params=resolvedReceiptParameters("PURCHASE",source.id());
        assertReceiptTargets("PURCHASE",source.id(),false,scope.expected());
        String candidate=lastSql,legacy=oldQuery(candidate);
        UUID unrelated=goods();
        new TransactionTemplate(new DataSourceTransactionManager(Objects.requireNonNull(db.getDataSource())))
                .executeWithoutResult(status->{for(int i=0;i<800;i++)analysis(scope.main(),unrelated,null,i%2==0?"ACTIVE":"COMPLETED",true,false,true);});
        for(String table:List.of("production_material_analyses","production_material_analysis_items","production_material_analysis_materials","procurement_inspection_items","purchase_receipts"))db.execute("ANALYZE "+table);
        assertReceiptTargets("PURCHASE",source.id(),false,scope.expected());
        // Warm both, alternate order, retain every plan; durations are observations, not a brittle speed assertion.
        explain(legacy,params);explain(candidate,params);
        var oldPlans=new ArrayList<JsonNode>();var newPlans=new ArrayList<JsonNode>();
        for(int i=0;i<5;i++){
            if(i%2==0){oldPlans.add(explain(legacy,params));newPlans.add(explain(candidate,params));}
            else {newPlans.add(explain(candidate,params));oldPlans.add(explain(legacy,params));}
        }
        for(JsonNode plan:newPlans){
            JsonNode dimensions=findPlan(plan.path("Plan"),"Subplan Name","CTE dimensions");
            JsonNode candidates=findPlan(plan.path("Plan"),"Subplan Name","CTE candidates");
            assertNotNull(dimensions);assertEquals(1,dimensions.path("Actual Loops").asInt());
            assertNotNull(candidates);assertTrue(candidates.path("Actual Rows").asInt()<20,"unrelated history never enters warehouse/fulfillment evaluation");
        }
        Path output=Path.of(System.getProperty("uten.wakeup.evidenceDirectory",
                Path.of(System.getProperty("uten.build.directory","target"),"wakeup-query-evidence").toString()));Files.createDirectories(output);
        var mapper=new ObjectMapper();mapper.writerWithDefaultPrettyPrinter().writeValue(output.resolve("old-plans.json").toFile(),oldPlans);
        mapper.writerWithDefaultPrettyPrinter().writeValue(output.resolve("candidate-plans.json").toFile(),newPlans);
        Files.writeString(output.resolve("queries.txt"),"OLD\n"+legacy+"\nCANDIDATE\n"+candidate+"\nPARAMETERS\n"+params);
        String summary="Unrelated analyses added: 800; matching result count: "+scope.expected().size()+"\n"+metrics("old",oldPlans)+metrics("candidate",newPlans);
        Files.writeString(output.resolve("summary.txt"),summary);System.out.println(summary);
    }

    @SuppressWarnings("unchecked")
    private static void assertTargets(String method,Object[] arguments,Map<String,Object> params,List<UUID> expected) throws Exception {
        Class<?>[] types=switch(method){case "inspectionStockInTargets"->new Class[]{List.class};case "resolvedReceiptTargets"->new Class[]{Collection.class};case "finishedInboundTargets"->new Class[]{UUID.class,int.class};default->new Class[]{UUID.class};};
        if (method.equals("inspectionStockInTargets")) {
            String receiptType = (String) arguments[0];
            UUID receiptId = (UUID) arguments[1];
            List<UUID> inspectionIds = List.copyOf((Collection<UUID>) arguments[2]);
            arguments = new Object[]{List.of(new com.uten.imp.application.port.ProductionInspectionStockInPort.ReceiptStockIn(
                    receiptType, receiptId, UUID.randomUUID(), inspectionIds))};
            params = Map.of("purchaseReceiptIds", "PURCHASE".equals(receiptType) ? receiptId.toString() : "",
                    "subcontractReceiptIds", "SUBCONTRACT".equals(receiptType) ? receiptId.toString() : "",
                    "inspectionItemIds", inspectionIds);
        } else if (method.equals("finishedInboundTargets")) {
            params = Map.of("sourceDocumentIds", List.of((UUID) arguments[0]), "requiredStatus", arguments[1]);
        }
        var selector=MaterialAnalysisSupplyWakeupService.class.getDeclaredMethod(method,types);selector.setAccessible(true);
        var actual=(List<MaterialAnalysisSupplyWakeupService.AnalysisTarget>)selector.invoke(service,arguments);
        String current=lastSql;
        String dimension=dimension(current).replaceAll("\\s+"," ").trim();
        if (DIMENSION_HASHES.containsKey(method)) assertEquals(DIMENSION_HASHES.get(method),HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(dimension.getBytes(StandardCharsets.UTF_8))),"reviewed actual-warehouse source UNION predicates are unchanged");
        if(DIMENSION_HASHES.containsKey(method))assertReviewedNativeOriginDelta(method,dimension);
        var oldRows=(List<Object[]>)bind(em.createNativeQuery(oldQuery(current)),params).getResultList();
        var old=oldRows.stream().map(row->new MaterialAnalysisSupplyWakeupService.AnalysisTarget((UUID)row[0],(UUID)row[1])).toList();
        assertEquals(old,actual,"old/new UUID and maker results, including ordering");
        // PostgreSQL UUID ordering is unsigned lexicographic; Java UUID.compareTo has different signed semantics.
        assertEquals(expected.stream().sorted(Comparator.comparing(UUID::toString)).toList(),actual.stream().map(MaterialAnalysisSupplyWakeupService.AnalysisTarget::analysisId).toList());
    }
    private static void assertReviewedNativeOriginDelta(String method,String dimension) throws Exception {
        String original=dimension;
        Map<String,Integer> projections=switch(method) {
            case "resolvedReceiptTargets"->Map.of("purchase_receipts",1,"subcontract_receipts",1);
            case "reversedPurchaseTargets"->Map.of("purchase_receipts",2,"purchase_receipt_items",1);
            case "reversedSubcontractTargets"->Map.of("subcontract_receipts",2,"subcontract_receipt_items",1);
            default->throw new IllegalArgumentException(method);
        };
        for(var entry:projections.entrySet()) {
            String table=entry.getKey();
            String reviewed="(SELECT * FROM "+table+" archive_origin WHERE NULLIF(to_jsonb(archive_origin)->>'legacy_id','') IS NULL AND NULLIF(to_jsonb(archive_origin)->>'legacy_import_run_id','') IS NULL AND NOT fn_imported_business_document('"+table+"',archive_origin.id))";
            assertEquals(entry.getValue(),original.split(java.util.regex.Pattern.quote(reviewed),-1).length-1,"exact approved native-source projection count");
            original=original.replace(reviewed,table);
        }
        String expected=switch(method) {
            case "resolvedReceiptTargets"->"e74cfde7c0d014f6942c1d3d453eea378ca8cde9da07400ead473037521676d1";
            case "reversedPurchaseTargets"->"8337cfcf5808946277eef7b3bb05f969dfee1a0b14fbbf3ffe48f8aca9ac30aa";
            case "reversedSubcontractTargets"->"1de24fe0b164e47ac90428fedb105b478744f09a9ef2cb39d42ecee6eaf39ee9";
            default->throw new IllegalArgumentException(method);
        };
        assertEquals(expected,HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(original.getBytes(StandardCharsets.UTF_8))),
                "removing only reviewed origin projections restores the original warehouse UNION/status/color SQL byte contract");
    }
    private static Map<String,Object> resolvedReceiptParameters(String type,UUID receipt) {
        return Map.of("purchaseReceiptIds","PURCHASE".equals(type)?receipt.toString():"",
                "subcontractReceiptIds","SUBCONTRACT".equals(type)?receipt.toString():"");
    }
    private static String joined(List<UUID> ids) {
        return ids.stream().distinct().sorted().map(UUID::toString).collect(java.util.stream.Collectors.joining(","));
    }
    private static void assertReceiptTargets(String type,UUID receipt,boolean reversed,List<UUID> expected) throws Exception {
        if(reversed) {
            assertTargets("PURCHASE".equals(type)?"reversedPurchaseTargets":"reversedSubcontractTargets",
                    new Object[]{receipt},Map.of("sourceDocumentId",receipt),expected);
        } else {
            assertTargets("resolvedReceiptTargets",new Object[]{List.of(
                    new com.uten.imp.application.port.ProductionInspectionStockInPort.ResolvedReceipt(type,receipt))},
                    resolvedReceiptParameters(type,receipt),expected);
        }
    }
    private static String dimension(String sql){return sql.substring(sql.indexOf('(')+1,sql.indexOf("), candidates AS MATERIALIZED ("));}
    private static String oldQuery(String sql){return "WITH dimensions AS ("+dimension(sql)+")\n"+OLD_SELECTOR;}
    private static Query bind(Query query,Map<String,Object> params){params.forEach(query::setParameter);return query;}
    private static JsonNode explain(String sql,Map<String,Object> params) throws Exception {
        String json=bind(em.createNativeQuery("EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,FORMAT JSON) "+sql),params).getSingleResult().toString();
        return new ObjectMapper().readTree(json).get(0);
    }
    private static JsonNode findPlan(JsonNode node,String field,String value){if(value.equals(node.path(field).asText()))return node;for(JsonNode child:node.path("Plans")){JsonNode found=findPlan(child,field,value);if(found!=null)return found;}return null;}
    private static String metrics(String label,List<JsonNode> plans){double[] times=plans.stream().mapToDouble(p->p.path("Execution Time").asDouble()).sorted().toArray();return label+" execution_ms min/median/max="+times[0]+"/"+times[2]+"/"+times[4]+"; shared_hits="+plans.stream().map(p->p.path("Plan").path("Shared Hit Blocks").asInt()).toList()+"\n";}

    private static Scope scope(){
        UUID main=warehouse(null),leaf=warehouse(main),sibling=warehouse(main),other=warehouse(null),goods=goods(),blue=UUID.randomUUID();
        db.update("INSERT INTO colors(id,code,name) VALUES (?,?,'wakeup blue')",blue,"WU-C-"+blue);
        UUID active=analysis(main,goods,null,"ACTIVE",true,false,true);
        db.update("""
                INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,
                    goods_id,color_id,unit_id,depth,path,per_product_qty,required_qty,available_qty,
                    allocated_available_qty,shortage_qty,source_suggestion,active)
                SELECT gen_random_uuid(),analysis_id,analysis_item_id,node_key||'-second-path',goods_id,
                    color_id,unit_id,depth,path||'-second-path',per_product_qty,required_qty,
                    available_qty,allocated_available_qty,shortage_qty,source_suggestion,active
                FROM production_material_analysis_materials WHERE analysis_id=?
                """,active);
        UUID partial=analysis(sibling,goods,null,"PARTIALLY_PLANNED",true,false,true);
        UUID reopened=analysis(main,goods,null,"COMPLETED",true,false,true);
        assertEquals("ACTIVE",db.queryForObject("SELECT fn_material_analysis_fulfillment_status(?)",String.class,reopened));
        UUID complete=analysis(main,goods,null,"COMPLETED",true,false,false);
        assertEquals("COMPLETED",db.queryForObject("SELECT fn_material_analysis_fulfillment_status(?)",String.class,complete));
        analysis(other,goods,null,"ACTIVE",true,false,true);analysis(main,goods,null,"CANCELLED",true,false,true);
        analysis(main,goods,null,"ACTIVE",false,false,true);analysis(main,goods,null,"ACTIVE",true,true,true);
        assertThrows(org.springframework.dao.DataIntegrityViolationException.class,
                ()->analysis(null,goods,null,"ACTIVE",true,false,true),"current schema rejects new warehouse-less analyses");
        UUID colored=analysis(main,goods,blue,"ACTIVE",true,false,true);
        return new Scope(main,leaf,goods,blue,colored,List.of(active,partial,reopened));
    }
    private static UUID analysis(UUID warehouse,UUID goods,UUID color,String status,boolean active,boolean deleted,boolean demand){
        UUID id=UUID.randomUUID(),item=UUID.randomUUID();
        db.update("INSERT INTO production_material_analyses(id,warehouse_id,status,fingerprint,initial_idempotency_key,maker_id,is_deleted,cancelled_by,cancelled_at,cancellation_reason) VALUES (?,?,?,?,?,?,?,?,CASE WHEN ? THEN now() END,?)",id,warehouse,status,"a".repeat(64),"wakeup-"+id,maker,deleted,status.equals("CANCELLED")?actor:null,status.equals("CANCELLED"),status.equals("CANCELLED")?"Query fixture cancellation":null);
        db.update("INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,color_id,unit_id,source_ref,source_reason,requested_qty,is_deleted) VALUES (?,?,'OTHER',?,?,?,?,'wakeup query fixture',10,?)",item,id,goods,color,unit,"WU-SOURCE-"+item,!demand);
        // Completed without active demand is represented by the existing soft-deleted source item, never fabricated fulfillment.
        db.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,goods_id,color_id,unit_id,depth,path,per_product_qty,required_qty,available_qty,allocated_available_qty,shortage_qty,source_suggestion,active) VALUES (gen_random_uuid(),?,?,?,?,?,?,1,?,1,10,0,0,10,'BUY',?)",id,item,"node-"+item,goods,color,unit,"node-"+item,active);
        return id;
    }
    private static Receipt receipt(String type,UUID warehouse,UUID goods,UUID color,int status,String quality,boolean stocked) throws Exception {
        String prefix=type.toLowerCase(Locale.ROOT),bill=(type.equals("PURCHASE")?"CJ":"EJ")+"20260908"+NUMBERS.incrementAndGet();
        UUID id=UUID.randomUUID(),item=UUID.randomUUID(),inspection=quality==null?null:UUID.randomUUID();
        try(var c=connection()){
            c.setAutoCommit(false);
            execute(c,"INSERT INTO "+prefix+"_receipts(id,bill_no,bill_date,warehouse_id,status,exchange_rate,total_original,total_local) VALUES (?,?,DATE '2026-09-08',?,?,1,0,0)",id,bill,warehouse,status);
            execute(c,"INSERT INTO "+prefix+"_receipt_items(id,bill_no,bill_date,receipt_id,line_no,goods_id,color_id,unit_id,unit_rate,qty,price,amount_original,amount_local,replacement_intent,goods_snapshot_source) VALUES (?,?,DATE '2026-09-08',?,1,?,?,?,1,10,0,0,0,'NORMAL','MASTER_AT_SAVE')",item,bill,id,goods,color,unit);
            if(status==1)ProcurementReceiptFixtureSupport.appendStandardReceipt(c,type,id,actor);
            if(quality!=null){
                execute(c,"INSERT INTO procurement_inspection_items(id,receipt_type,receipt_id,receipt_item_id,warehouse_id,goods_id,color_id,unit_id,unit_rate,received_base_qty,received_amount_local,status) VALUES (?,?,?,?,?,?,?,?,1,10,0,?)",inspection,type,id,item,warehouse,goods,color,unit,quality.equals("REVERSED")?"REVERSED":"PENDING");
                if(quality.equals("RESOLVED"))ProcurementReceiptFixtureSupport.recordZeroPriceQualityDecision(c,inspection,"FAIL",BigDecimal.TEN,actor);
                if(quality.equals("PARTIAL"))ProcurementReceiptFixtureSupport.recordZeroPriceQualityDecision(c,inspection,"PASS",new BigDecimal("4"),actor);
            }
            c.commit();
        }
        if(stocked)try(var c=connection()){ProcurementReceiptFixtureSupport.stockZeroPricePasses(c,List.of(inspection));}
        return new Receipt(id,inspection);
    }
    private static UUID finished(UUID warehouse,UUID goods,UUID color,int status){UUID id=UUID.randomUUID();String bill="CR20260908"+NUMBERS.incrementAndGet();db.update("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,warehouse_id,status) VALUES (?,'FINISHED_IN',?,DATE '2026-09-08',?,?)",id,bill,warehouse,status);db.update("INSERT INTO stock_document_items(id,doc_id,bill_type,bill_no,bill_date,line_no,goods_id,color_id,unit_id,unit_rate,qty,base_qty,goods_snapshot_source) VALUES (gen_random_uuid(),?,'FINISHED_IN',?,DATE '2026-09-08',1,?,?,?,1,10,10,'MASTER_AT_SAVE')",id,bill,goods,color,unit);return id;}
    private static UUID goods(){UUID id=UUID.randomUUID();db.update("INSERT INTO goods(id,code,name,unit_id,code_sequence) VALUES (?,?,'wakeup goods',?,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))",id,"WU-G-"+id,unit);return id;}
    private static UUID warehouse(UUID parent){UUID id=UUID.randomUUID();db.update("INSERT INTO warehouses(id,code,name,parent_id,status) VALUES (?,?,'wakeup warehouse',?,'使用')",id,"WU-W-"+id,parent);return id;}
    private static Connection connection() throws Exception{return DriverManager.getConnection(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());}
    private static void execute(Connection connection,String sql,Object...params) throws Exception{try(var query=connection.prepareStatement(sql)){for(int i=0;i<params.length;i++){ query.setObject(i+1,params[i]); }query.execute();}}
    private record Receipt(UUID id,UUID inspection){}
    private record Scope(UUID main,UUID leaf,UUID goods,UUID blue,UUID colored,List<UUID> expected){}
}
