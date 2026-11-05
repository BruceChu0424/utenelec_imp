package com.uten.imp.features.sales.shipment;

import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.order.SalesOrderService;
import com.uten.imp.features.finance.receivables.*;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.lang.reflect.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** The annotation belongs on every owning entry, including self-invoking batch wrappers. */
class SalesFinanceSnapshotIsolationContractTest {
    static List<Method> entrypoints() {
        List<Method> result=new ArrayList<>();
        Set<String> shipment=Set.of("financeAudit","financeAuditReject","financeAuditBatch",
                "financeAuditRejectBatch","financeRejectReverse","financeAuditReverse","financeAuditInfo");
        for(Method method:SalesShipmentService.class.getDeclaredMethods())
            if(Modifier.isPublic(method.getModifiers()) && shipment.contains(method.getName()))result.add(method);
        for(Method method:SalesOrderFinanceConfirmService.class.getDeclaredMethods())
            if(Modifier.isPublic(method.getModifiers()) && Set.of("review","managerReview").contains(method.getName()))result.add(method);
        result.sort(Comparator.comparing(Method::toGenericString));
        return result;
    }
    @Test void eachReviewDecisionAndBatchOwnsOneRepeatableReadTransactionWithoutIndependentInnerWrites() {
        var source=new AnnotationTransactionAttributeSource();
        assertThat(entrypoints()).hasSize(10);
        List<Method> all=new ArrayList<>(entrypoints());
        for(Method method:SalesOrderService.class.getDeclaredMethods())if(method.getName().equals("list"))all.add(method);
        for(Method method:SalesOrderMoneyReadAdapter.class.getDeclaredMethods())if(method.getName().equals("read"))all.add(method);
        for(Method method:all){
            var attribute=source.getTransactionAttribute(method,method.getDeclaringClass());
            assertThat(attribute).as(method.toGenericString()).isNotNull();
            assertThat(attribute.getIsolationLevel()).as(method.toGenericString()).isEqualTo(TransactionDefinition.ISOLATION_REPEATABLE_READ);
            assertThat(attribute.getPropagationBehavior()).as(method.toGenericString()).isEqualTo(TransactionDefinition.PROPAGATION_REQUIRED);
        }
    }
    @Test void incompleteTransactionAuthorityReturnsUnknownForTheWholeBatchWithoutReadingOrInventingZero(){
        var query=mock(CustomerPrepaymentQueryService.class);var em=mock(EntityManager.class);
        var adapter=new SalesOrderMoneyReadAdapter(query,em);List<UUID> ids=List.of(UUID.randomUUID(),UUID.randomUUID());
        Integer previous=TransactionSynchronizationManager.getCurrentTransactionIsolationLevel();
        boolean active=TransactionSynchronizationManager.isActualTransactionActive();
        try{
            TransactionSynchronizationManager.setActualTransactionActive(true);
            for(Integer level:new Integer[]{null,TransactionDefinition.ISOLATION_READ_UNCOMMITTED,TransactionDefinition.ISOLATION_READ_COMMITTED}){
                TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(level);
                var result=adapter.read(ids,true);assertThat(result).hasSize(2);
                assertThat(result.values()).allSatisfy(value->{
                    assertThat(value.positionComplete()).isFalse();assertThat(value.hasUnallocated()).isTrue();
                    assertThat(value.cashReceivedOriginal()).isNull();assertThat(value.plannedRemainingOriginal()).isNull();
                    assertThat(value.customerUnassignedPrepaymentOriginal()).isNull();assertThat(value.warnings()).isNotEmpty();
                });
            }
            verifyNoInteractions(query,em);
        }finally{
            TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(previous);
            TransactionSynchronizationManager.setActualTransactionActive(active);
        }
    }
}
