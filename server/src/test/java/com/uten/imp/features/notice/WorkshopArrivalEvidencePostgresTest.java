package com.uten.imp.features.notice;

import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.features.admin.workflow.SalesOrderFinanceConfirmerEligibility;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.production.analysis.MaterialAnalysisSupplyWakeupService;
import com.uten.imp.features.rd_task.RdTaskService;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Executes production evidence and paging SQL on PostgreSQL; this is a focused query fixture, not migration acceptance. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class WorkshopArrivalEvidencePostgresTest {
    static final PostgreSQLContainer<?> DB=new PostgreSQLContainer<>("postgres:16-alpine");
    static JdbcTemplate db;
    @BeforeAll static void start() {
        DB.start(); db=new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword()));
        MigratedProjectionSchema.createCurrentTables(db,
                "stock_documents",
                "production_daily_reports",
                "production_workshop_direct_transfers",
                "production_workshop_direct_transfer_items",
                "purchase_receipts",
                "subcontract_receipts",
                "procurement_iqc_stock_in_batches",
                "procurement_iqc_stock_in_batch_items",
                "procurement_inspection_items",
                "production_planning_packages",
                "production_execution_segments",
                "production_material_demands",
                "stock_document_items",
                "production_plans",
                "preplan_stock_entitlement_events",
                "v_preplan_stock_entitlement_beneficiary_balance",
                "stock_reservations");
        db.execute("CREATE FUNCTION fn_warehouse_same_main(uuid,uuid) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT $1=$2'");
        db.execute("CREATE FUNCTION fn_analysis_plan_material_matches(uuid,uuid) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT $1=$2'");
        db.execute("CREATE FUNCTION fn_preplan_reservation_has_qualified_origin(uuid) RETURNS boolean LANGUAGE sql IMMUTABLE AS 'SELECT true'");
    }
    @AfterAll static void stop() { DB.stop(); }

    @Test void arrivalRightsSuppressAnotherPlansExclusiveReceiptButKeepOwnPartialAndUsablePublicSlices() {
        var readiness=mock(com.uten.imp.application.port.WorkshopMaterialAvailabilityReadPort.class);
        @SuppressWarnings("unchecked")
        org.springframework.beans.factory.ObjectProvider<com.uten.imp.application.port.WorkshopMaterialAvailabilityReadPort> provider=mock(org.springframework.beans.factory.ObjectProvider.class);
        when(provider.getObject()).thenReturn(readiness);
        var service=new ChainNoticeService(mock(NoticeService.class),mock(UserAccountRepository.class),mock(PermissionResolver.class),
                db,mock(BusinessEventPublisher.class),mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),mock(SalesOrderFinanceConfirmerEligibility.class),null,provider);
        UUID plan=UUID.randomUUID(),analysis=UUID.randomUUID(),material=UUID.randomUUID(),pack=UUID.randomUUID(),
                segment=UUID.randomUUID(),demand=UUID.randomUUID(),warehouse=UUID.randomUUID(),goods=UUID.randomUUID(),
                source=UUID.randomUUID(),sourceItem=UUID.randomUUID(),originReservation=UUID.randomUUID(),other=UUID.randomUUID();
        db.update("INSERT INTO production_plans(id,material_analysis_id,material_analysis_item_id) VALUES (?,?,?)",plan,analysis,material);
        db.update("INSERT INTO production_planning_packages(id,status,warehouse_id) VALUES (?,'CONFIRMED',?)",pack,warehouse);
        db.update("INSERT INTO production_execution_segments(id,package_id,plan_id,status) VALUES (?,?,?,'WAITING')",segment,pack,plan);
        db.update("INSERT INTO production_material_demands(id,execution_segment_id,goods_id,warehouse_id,status) VALUES (?,?,?,?,'DEMANDED')",demand,segment,goods,warehouse);
        // Another required material has no receipt at all: aggregate output capacity is zero.
        db.update("INSERT INTO production_material_demands(id,execution_segment_id,goods_id,warehouse_id,status) VALUES (?,?,?,?,'DEMANDED')",UUID.randomUUID(),segment,UUID.randomUUID(),warehouse);
        db.update("INSERT INTO stock_documents(id,doc_type,status,warehouse_id) VALUES (?,'FINISHED_IN',1,?)",source,warehouse);
        db.update("INSERT INTO stock_document_items(id,doc_id,goods_id,base_qty) VALUES (?,?,?,100)",sourceItem,source,goods);
        db.update("INSERT INTO preplan_stock_entitlement_events(event_group_id,stock_reservation_id,event_type,qty) VALUES (?,?,'ORIGIN_MAKE',100)",sourceItem,originReservation);
        db.update("INSERT INTO v_preplan_stock_entitlement_beneficiary_balance(stock_reservation_id,beneficiary_analysis_id,beneficiary_analysis_material_id,effective_qty) VALUES (?,?,?,100)",originReservation,other,material);
        assertThat(service.workshopArrivalCanBenefit(segment,"FINISHED_IN",List.of(source))).isFalse();
        verifyNoInteractions(readiness); // Existing unrelated public stock cannot turn a private receipt into this task's arrival.
        db.update("UPDATE v_preplan_stock_entitlement_beneficiary_balance SET beneficiary_analysis_id=? WHERE stock_reservation_id=?",analysis,originReservation);
        when(readiness.batchAvailability(eq(warehouse),eq(List.of(demand)),eq(analysis),eq(material)))
                .thenReturn(List.of(available(demand,warehouse,100,0,0)));
        assertThat(service.workshopArrivalCanBenefit(segment,"FINISHED_IN",List.of(source))).isTrue();
        db.update("UPDATE v_preplan_stock_entitlement_beneficiary_balance SET beneficiary_analysis_id=? WHERE stock_reservation_id=?",other,originReservation);
        db.update("UPDATE stock_document_items SET base_qty=150 WHERE id=?",sourceItem);
        when(readiness.batchAvailability(any(),anyList(),any(),any())).thenReturn(List.of(available(demand,warehouse,0,50,0)));
        assertThat(service.workshopArrivalCanBenefit(segment,"FINISHED_IN",List.of(source))).isTrue();
        when(readiness.batchAvailability(any(),anyList(),any(),any())).thenReturn(List.of(available(demand,warehouse,0,50,100)));
        assertThat(service.workshopArrivalCanBenefit(segment,"FINISHED_IN",List.of(source))).isFalse();
        when(readiness.batchAvailability(any(),anyList(),any(),any())).thenReturn(List.of(
                available(demand,warehouse,0,50,100),available(demand,UUID.randomUUID(),0,60,100)));
        assertThat(service.workshopArrivalCanBenefit(segment,"FINISHED_IN",List.of(source))).isTrue();
        // Preparation has already moved the newly public slice into this exact demand.
        db.update("INSERT INTO stock_reservations(id,demand_id,warehouse_id,qty) VALUES (?,?,?,50)",UUID.randomUUID(),demand,warehouse);
        when(readiness.batchAvailability(any(),anyList(),any(),any())).thenReturn(List.of());
        assertThat(service.workshopArrivalCanBenefit(segment,"FINISHED_IN",List.of(source))).isTrue();
        db.update("UPDATE production_material_demands SET warehouse_id=? WHERE id=?",UUID.randomUUID(),demand);
        assertThat(service.workshopArrivalCanBenefit(segment,"FINISHED_IN",List.of(source))).isFalse();
    }

    private static com.uten.imp.application.port.WorkshopMaterialAvailabilityReadPort.Availability available(
            UUID demand,UUID warehouse,int owned,int publicQty,int safety) {
        return new com.uten.imp.application.port.WorkshopMaterialAvailabilityReadPort.Availability(
                demand,warehouse,BigDecimal.valueOf(publicQty),BigDecimal.valueOf(safety),BigDecimal.valueOf(owned));
    }

    @Test void finishedDirectAndIqcEvidenceBecomeInvalidAfterTheirRealSourceReverses() {
        var service=new ChainNoticeService(mock(NoticeService.class),mock(UserAccountRepository.class),mock(PermissionResolver.class),
                db,mock(BusinessEventPublisher.class),mock(RdTaskService.class),
                mock(FinanceReviewerEligibilityPort.class),mock(SalesOrderFinanceConfirmerEligibility.class));
        UUID doc=UUID.randomUUID(),report=UUID.randomUUID(),transfer=UUID.randomUUID(),receipt=UUID.randomUUID(),
                batch=UUID.randomUUID(),inspection=UUID.randomUUID();
        db.update("INSERT INTO stock_documents(id,doc_type,status) VALUES (?,'FINISHED_IN',1)",doc);
        db.update("INSERT INTO production_daily_reports(id,status) VALUES (?,1)",report);
        db.update("INSERT INTO production_workshop_direct_transfers(id,source_report_id) VALUES (?,?)",transfer,report);
        db.update("INSERT INTO production_workshop_direct_transfer_items(transfer_id) VALUES (?)",transfer);
        db.update("INSERT INTO purchase_receipts(id,status) VALUES (?,1)",receipt);
        db.update("INSERT INTO procurement_iqc_stock_in_batches(id,receipt_type,receipt_id) VALUES (?,'PURCHASE',?)",batch,receipt);
        db.update("INSERT INTO procurement_inspection_items(id,status) VALUES (?,'PARTIAL')",inspection);
        db.update("INSERT INTO procurement_iqc_stock_in_batch_items(batch_id,inspection_item_id) VALUES (?,?)",batch,inspection);
        assertThat(service.workshopArrivalEvidenceValid("FINISHED_IN",List.of(doc))).isTrue();
        assertThat(service.workshopArrivalEvidenceValid("DIRECT_REPORT",List.of(report))).isTrue();
        assertThat(service.workshopArrivalEvidenceValid("IQC_STOCK_IN",List.of(batch))).isTrue();
        assertThat(service.workshopArrivalEvidenceValid("FINISHED_IN",List.of(doc,UUID.randomUUID()))).isFalse();
        db.update("UPDATE stock_documents SET status=-1 WHERE id=?",doc);
        db.update("UPDATE production_workshop_direct_transfer_items SET reversal_id=? WHERE transfer_id=?",UUID.randomUUID(),transfer);
        db.update("UPDATE procurement_inspection_items SET status='REVERSED' WHERE id=?",inspection);
        assertThat(service.workshopArrivalEvidenceValid("FINISHED_IN",List.of(doc))).isFalse();
        assertThat(service.workshopArrivalEvidenceValid("DIRECT_REPORT",List.of(report))).isFalse();
        assertThat(service.workshopArrivalEvidenceValid("IQC_STOCK_IN",List.of(batch))).isFalse();
    }

    @Test void arrivalVisitsEveryMatchingSegmentAndReversalAlsoRefreshesFulfilledReadyRows() throws Exception {
        UUID warehouse=UUID.randomUUID(),goods=UUID.randomUUID(),workshop=UUID.randomUUID(),pack=UUID.randomUUID();
        db.update("INSERT INTO production_planning_packages(id,status) VALUES (?,'CONFIRMED')",pack);
        Set<UUID> segments=new HashSet<>();
        for(int i=0;i<405;i++) {
            UUID id=UUID.randomUUID();segments.add(id);
            db.update("INSERT INTO production_execution_segments(id,package_id,workshop_department_id,status) VALUES (?,?,?,'WAITING')",id,pack,workshop);
            db.update("INSERT INTO production_material_demands(execution_segment_id,goods_id,warehouse_id,status) VALUES (?,?,?,'DEMANDED')",id,goods,warehouse);
        }
        EntityManager em=mock(EntityManager.class);ChainNoticeService notices=mock(ChainNoticeService.class);
        NamedParameterJdbcTemplate named=new NamedParameterJdbcTemplate(db);
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);Query query=mock(Query.class);Map<String,Object> parameters=new HashMap<>();
            when(query.setParameter(anyString(),any())).thenAnswer(bind->{parameters.put(bind.getArgument(0),bind.getArgument(1));return query;});
            when(query.getResultList()).thenAnswer(read->named.query(sql,parameters,(row,index)->new Object[]{row.getObject(1),row.getString(2)}));
            return query;
        });
        var service=new MaterialAnalysisSupplyWakeupService(em,null,null,null,notices);
        var method=MaterialAnalysisSupplyWakeupService.class.getDeclaredMethod("notifyWaitingSegmentsAboutArrival",
                String.class,List.class,String.class,Collection.class);method.setAccessible(true);
        List<Object[]> dimensions=List.<Object[]>of(new Object[]{warehouse,goods,null,new BigDecimal("100"),"材料","M01",""});
        UUID evidence=UUID.randomUUID();
        method.invoke(service,"one",dimensions,"FINISHED_IN",List.of(evidence));
        var ids=org.mockito.ArgumentCaptor.forClass(UUID.class);
        verify(notices,times(405)).notifyWorkshopMaterialArrival(ids.capture(),eq("one"),anyString(),eq("FINISHED_IN"),eq(List.of(evidence)));
        assertThat(new HashSet<>(ids.getAllValues())).isEqualTo(segments);
        UUID ready=UUID.randomUUID();segments.add(ready);
        db.update("INSERT INTO production_execution_segments(id,package_id,workshop_department_id,status) VALUES (?,?,?,'READY')",ready,pack,workshop);
        db.update("INSERT INTO production_material_demands(execution_segment_id,goods_id,warehouse_id,status) VALUES (?,?,?,'FULFILLED')",ready,goods,warehouse);
        clearInvocations(notices);
        method.invoke(service,"reverse",dimensions,"CURRENT_STATE",List.of());
        verify(notices,times(406)).notifyWorkshopMaterialArrival(any(),eq("reverse"),contains("来源已撤回"),eq("CURRENT_STATE"),eq(List.of()));
        verify(notices,times(3)).resolveProductionWorkshopTasks(anyCollection(),eq("SOURCE_REVERSED"));
    }
}
