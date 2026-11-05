package com.uten.imp.features.finance.receivables;

import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class ShipmentReceivablePositionAdapterTest {
    final UUID shipment=UUID.randomUUID(),currency=UUID.randomUUID(),ledger=UUID.randomUUID();
    EntityManager em;Query query;ShipmentReceivablePositionAdapter service;Integer previous;boolean active;
    @BeforeEach void start(){
        previous=TransactionSynchronizationManager.getCurrentTransactionIsolationLevel();active=TransactionSynchronizationManager.isActualTransactionActive();
        TransactionSynchronizationManager.setActualTransactionActive(true);TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
        em=mock(EntityManager.class);query=mock(Query.class);when(em.createNativeQuery(anyString())).thenReturn(query);when(query.setParameter(anyString(),any())).thenReturn(query);
        service=new ShipmentReceivablePositionAdapter(em);
    }
    @AfterEach void reset(){TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(previous);TransactionSynchronizationManager.setActualTransactionActive(active);}
    Object[] ready(String cash,String advance,String balance){return new Object[]{shipment,currency,"人民币",n("1000"),(short)1,true,"CHARGED",ledger,currency,"RECEIVABLE",
            n("1000"),n(cash),n(advance),n("0"),n(balance),null,1L,n(cash),0L,n(advance),0L,shipment,shipment};}
    void row(Object[] value){when(query.getResultList()).thenReturn(List.<Object[]>of(value));}
    @Test void physicalBatchPartialCashLeavesItsOwnBalanceWithoutOrderOrBankNetSubstitution(){
        row(ready("400","0","600"));var position=service.read(List.of(shipment)).get(shipment);
        assertThat(position.complete()).isTrue();assertThat(position.state()).isEqualTo("READY");assertThat(position.ledgerId()).isEqualTo(ledger);
        assertThat(new BigDecimal(position.confirmedPaidOriginal())).isEqualByComparingTo("400");assertThat(new BigDecimal(position.balanceOriginal())).isEqualByComparingTo("600");
        verify(query).setParameter("ids",List.of(shipment));
    }
    @Test void onlyActualTargetAdvanceApplicationCountsAsPaidAndItIsNotAddedTwice(){
        row(ready("0","200","800"));var position=service.read(List.of(shipment)).get(shipment);
        assertThat(position.complete()).isTrue();assertThat(new BigDecimal(position.cashReceivedOriginal())).isZero();
        assertThat(new BigDecimal(position.prepaymentAppliedOriginal())).isEqualByComparingTo("200");
        assertThat(new BigDecimal(position.confirmedPaidOriginal())).isEqualByComparingTo("200");assertThat(new BigDecimal(position.balanceOriginal())).isEqualByComparingTo("800");
    }
    @Test void unpostedShipmentHasKnownGoodsValueButNoInventedFormalReceiptOrBalance(){
        Object[] value=ready("0","0","1000");value[4]=(short)0;value[5]=false;value[7]=null;value[16]=0L;row(value);
        var position=service.read(List.of(shipment)).get(shipment);assertThat(position.state()).isEqualTo("NOT_POSTED");
        assertThat(position.ledgerId()).isNull();assertThat(position.formalReceivableOriginal()).isNull();assertThat(position.cashReceivedOriginal()).isNull();assertThat(position.balanceOriginal()).isNull();
        assertThat(new BigDecimal(position.shipmentOriginal())).isEqualByComparingTo("1000");
    }
    @Test void unverifiedBankPostingOrDuplicateArCannotBePresentedAsConfirmedMoney(){
        Object[] value=ready("400","0","600");value[18]=1L;row(value);
        assertThat(service.read(List.of(shipment)).get(shipment).state()).isEqualTo("UNVERIFIED");
        value=ready("400","0","600");value[16]=2L;row(value);
        assertThat(service.read(List.of(shipment)).get(shipment).balanceOriginal()).isNull();
    }
    @Test void wrongCurrencyOrBrokenBalanceConservationRemainsUnknownInsteadOfZero(){
        Object[] value=ready("400","0","600");value[8]=UUID.randomUUID();row(value);
        assertThat(service.read(List.of(shipment)).get(shipment).complete()).isFalse();
        row(ready("400","0","601"));assertThat(service.read(List.of(shipment)).get(shipment).confirmedPaidOriginal()).isNull();
    }
    @Test void weakOuterTransactionDoesNotReadOrClaimAnyBatchAmount(){
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_READ_COMMITTED);
        var position=service.read(List.of(shipment)).get(shipment);assertThat(position.complete()).isFalse();assertThat(position.balanceOriginal()).isNull();verifyNoInteractions(em);
    }
    @Test void reversedAndFreeShipmentsKeepTheirDifferentAuthoritativeStates(){
        Object[] value=ready("0","0","1000");value[4]=(short)-1;value[7]=null;value[16]=0L;row(value);
        assertThat(service.read(List.of(shipment)).get(shipment).state()).isEqualTo("REVERSED");
        value=ready("0","0","1000");value[3]=n("0");value[6]="FREE";value[5]=false;value[7]=null;value[16]=0L;row(value);
        var free=service.read(List.of(shipment)).get(shipment);assertThat(free.state()).isEqualTo("FREE");assertThat(new BigDecimal(free.balanceOriginal())).isZero();
    }
    @Test void shippedWithoutArCannotMasqueradeAsPendingShipment(){
        Object[] value=ready("0","0","1000");value[5]=false;value[7]=null;value[16]=0L;row(value);
        assertThat(service.read(List.of(shipment)).get(shipment).state()).isEqualTo("UNVERIFIED");
    }
    @Test void pendingShipmentWithArCannotMasqueradeAsAReadyDebt(){
        Object[] value=ready("400","0","600");value[4]=(short)0;row(value);
        assertThat(service.read(List.of(shipment)).get(shipment).state()).isEqualTo("UNVERIFIED");
    }
    @Test void freeShipmentCannotHideAnActiveArOrPositiveGoodsValue(){
        Object[] value=ready("0","0","1000");value[6]="FREE";row(value);
        assertThat(service.read(List.of(shipment)).get(shipment).state()).isEqualTo("UNVERIFIED");
    }
    @Test void recognizedGoodsMustMatchTheImmutableShipmentValue(){
        Object[] value=ready("400","0","600");value[3]=n("1001");row(value);
        assertThat(service.read(List.of(shipment)).get(shipment).balanceOriginal()).isNull();
    }
    @Test void wrongLedgerCustomerCannotLeakAnotherPartysMoneyThroughAnOtherwiseMatchingShipmentId(){
        Object[] value=ready("0","0","1000");value[22]=UUID.randomUUID();row(value);
        assertThat(service.read(List.of(shipment)).get(shipment).state()).isEqualTo("UNVERIFIED");
    }
    @Test void twoMissingCurrencyIdsDoNotEstablishASameCurrencyDebt(){
        Object[] value=ready("0","0","1000");value[1]=null;value[8]=null;row(value);
        assertThat(service.read(List.of(shipment)).get(shipment).state()).isEqualTo("UNVERIFIED");
    }
    static BigDecimal n(String value){return new BigDecimal(value);}
}
