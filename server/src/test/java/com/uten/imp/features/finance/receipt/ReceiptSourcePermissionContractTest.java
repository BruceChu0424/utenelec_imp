package com.uten.imp.features.finance.receipt;

import com.uten.imp.features.finance.receivables.*;
import org.junit.jupiter.api.*;
import org.springframework.context.annotation.*;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.mock.web.MockHttpServletRequest;
import java.math.BigDecimal;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real method-security interception: preview/reference access does not grant create or update. */
class ReceiptSourcePermissionContractTest {
    AnnotationConfigApplicationContext context;Beans beans;ReceiptOrderCollectionController sources;FinanceReceiptController receipts;
    @BeforeEach void start(){context=new AnnotationConfigApplicationContext(Beans.class);beans=context.getBean(Beans.class);
        sources=context.getBean(ReceiptOrderCollectionController.class);receipts=context.getBean(FinanceReceiptController.class);}
    @AfterEach void stop(){SecurityContextHolder.clearContext();context.close();}
    void actor(String...permissions){SecurityContextHolder.getContext().setAuthentication(new TestingAuthenticationToken("receipt-clerk","test-only",permissions));}
    void read(){sources.preview(new ReceiptOrderCollectionController.Request(UUID.randomUUID(),BigDecimal.ONE,UUID.randomUUID()),new MockHttpServletRequest());}
    @Test void editOnlyMayReadItsOrderAndBatchSourcesButCannotCreateANewReceipt(){
        actor("finance_receipt:edit","sales_order:view");read();sources.shipmentSources(UUID.randomUUID(),null,1,20);
        assertThatThrownBy(()->receipts.create(new com.uten.imp.features.finance.receipt.dto.FinanceReceiptSaveRequest())).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(beans.receiptService);
    }
    @Test void createOnlyMayPrepareSourcesButCannotUpdateAnExistingReceipt(){
        actor("finance_receipt:create","sales_order:view");read();
        var command=new com.uten.imp.features.finance.FinanceDocumentActions.UpdateCommand(UUID.randomUUID(),1L,"a".repeat(64),new com.fasterxml.jackson.databind.ObjectMapper().createObjectNode());
        assertThatThrownBy(()->receipts.update(UUID.randomUUID(),command)).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(beans.commands);
    }
    @Test void fullFinanceDoesNotNeedAnAdditionalSalesViewForItsAuthorizedReceiptSources(){
        actor("finance_receipt:edit","finance:view:all");read();sources.choices(null,null,null,1,20,null,null);
        verify(beans.orderSources).choices(null,null,null,1,20,null,null);
    }
    @Test void salesViewAloneDoesNotGrantFinancialSourcePreparationOrWrites(){
        actor("sales_order:view");assertThatThrownBy(this::read).isInstanceOf(AccessDeniedException.class);
        assertThatThrownBy(()->sources.shipmentSources(UUID.randomUUID(),null,1,20)).isInstanceOf(AccessDeniedException.class);
        verifyNoInteractions(beans.preview,beans.ledgerSources);
    }
    @Configuration @EnableMethodSecurity static class Beans{
        final SalesOrderCollectionPreviewService preview=mock(SalesOrderCollectionPreviewService.class);
        final ReceiptOrderSourceAccess orderSources=mock(ReceiptOrderSourceAccess.class);
        final ReceiptLedgerSourceAccess ledgerSources=mock(ReceiptLedgerSourceAccess.class);
        final FinanceReceiptService receiptService=mock(FinanceReceiptService.class);
        final com.uten.imp.features.finance.FinanceDocumentActions commands=mock(com.uten.imp.features.finance.FinanceDocumentActions.class);
        @Bean com.uten.imp.features.finance.FinanceDocumentActions commands(){return commands;}
        @Bean ReceiptOrderCollectionController sources(){return new ReceiptOrderCollectionController(preview,orderSources,ledgerSources);}
        @Bean FinanceReceiptController receipts(){return new FinanceReceiptController(receiptService,mock(com.uten.imp.audit.AuditService.class),
                mock(com.uten.imp.security.SecurityContextCurrentUser.class),mock(com.uten.imp.audit.AuditDetailViewRecorder.class));}
    }
}
