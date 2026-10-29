package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.*;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.stream.Collectors;

import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.*;

/** Server recipe partitions pass through the real transactional writer and replay ledger. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class AggregateMaterialRecipeGroupingEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    private AggregateMaterialOrderEndToEndTest harness;
    @BeforeEach void before(){harness=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(harness);harness.before();}
    @AfterEach void after(){harness.after();}

    @Test void differentFrozenChildRoutesAutomaticallyPartitionIntoTwoExactPlansAndReplayWithoutDuplicates() {
        var scenario=harness.create(true,false,"10");
        AnalysisView initial=harness.analyses.detail(scenario.analysis());
        List<MaterialView> parents=initial.flatMaterials().stream()
                .filter(row->row.goodsId().equals(scenario.common())&&"BOM_COMPONENT".equals(row.nodeRole())).toList();
        assertEquals(3,parents.size());
        MaterialView changedParent=parents.getLast();
        MaterialView changedChild=initial.flatMaterials().stream()
                .filter(row->row.analysisLineId().equals(changedParent.analysisLineId())
                        &&changedParent.nodeKey().equals(row.parentNodeKey())).findFirst().orElseThrow();
        // Different already-confirmed child routes are frozen production-rule facts.
        // They must survive grouping rather than borrowing a sibling's recipe.
        assertEquals(1,harness.db.update("UPDATE production_material_analysis_materials SET confirmed_route='MAKE',route_reason='recipe grouping fixture' WHERE id=?",changedChild.materialLineId()));
        AnalysisView current=harness.analyses.detail(scenario.analysis());
        var keys=current.aggregateRecipeKeysByMaterialLineId();
        assertTrue(parents.stream().allMatch(row->keys.containsKey(row.materialLineId())),"Every intact source has an authoritative recipe key");
        var partitions=parents.stream().collect(Collectors.groupingBy(row->keys.get(row.materialLineId())));
        assertEquals(2,partitions.size());
        var combined=harness.preview.preview(scenario.analysis(),harness.request(scenario,
                List.of(harness.input(scenario,scenario.common(),"MAKE","30",false))));
        assertTrue(combined.groups().getFirst().blockedReason().contains("冻结组件规则不同"));
        List<GroupInput> inputs=new ArrayList<>();
        for(var entry:partitions.entrySet()) {
            List<UUID> ids=entry.getValue().stream().map(MaterialView::materialLineId).toList();
            inputs.add(new GroupInput("recipe-"+entry.getKey(),ids,"MAKE",BigDecimal.TEN.multiply(BigDecimal.valueOf(ids.size())),false,
                    scenario.workshop(),scenario.worker(),null,null,null,null,BigDecimal.ZERO,BigDecimal.ZERO,
                    ids.stream().collect(Collectors.toMap(id->id,id->BigDecimal.TEN))));
        }
        var request=harness.request(scenario,inputs);
        Preview preview=harness.preview.preview(scenario.analysis(),request);
        assertTrue(preview.groups().stream().allMatch(group->group.blockedReason()==null));
        SubmitRequest command=harness.submit(preview,request);
        SubmitResult result=harness.writer.submit(scenario.analysis(),command);
        assertEquals(2,result.batches().size());
        amount("30",result.batches().stream().map(BatchResult::qty).reduce(BigDecimal.ZERO,BigDecimal::add));
        assertEquals(3,result.batches().stream().flatMap(batch->batch.sources().stream()).count());
        for(BatchResult batch:result.batches()) {
            assertNotNull(batch.planId());amount("0",batch.publicExtraQty());
            for(SourcePreview source:batch.sources())amount("10",source.allocatedQty());
            boolean changedRecipe=batch.sources().stream().anyMatch(source->source.materialLineId().equals(changedParent.materialLineId()));
            MaterialView frozenChild=result.analysis().flatMaterials().stream()
                    .filter(row->row.analysisLineId().equals(batch.anchorAnalysisItemId())&&row.goodsId().equals(scenario.material()))
                    .findFirst().orElseThrow();
            assertEquals(changedRecipe?"MAKE":"BUY",frozenChild.sourceConfirmed());
        }
        var replay=harness.writer.submit(scenario.analysis(),command);
        assertTrue(replay.replayed());
        assertEquals(result.batches().stream().map(BatchResult::batchId).toList(),replay.batches().stream().map(BatchResult::batchId).toList());
        assertEquals(2,harness.count("SELECT COUNT(*) FROM preplan_aggregate_batches WHERE analysis_id=?",scenario.analysis()));
        assertEquals(2,harness.count("SELECT COUNT(*) FROM production_plans WHERE material_analysis_id=? AND NOT is_deleted",scenario.analysis()));
    }
}
