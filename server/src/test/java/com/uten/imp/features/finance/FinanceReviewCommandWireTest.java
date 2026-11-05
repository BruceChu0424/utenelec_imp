package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.FinancialJsonResults;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class FinanceReviewCommandWireTest {
    @Test void allFiveApprovalAndReversalControllersLeaveBusinessAuditToTheActualJournalWork()throws Exception{
        var types=List.of(com.uten.imp.features.finance.receipt.FinanceReceiptController.class,com.uten.imp.features.finance.payment.FinancePaymentController.class,com.uten.imp.features.finance.expense.FinanceExpenseController.class,com.uten.imp.features.finance.other_income.FinanceOtherIncomeController.class,com.uten.imp.features.finance.bank_transfer.FinanceBankTransferController.class);
        var segments=List.of("receipts","payments","expenses","incomes","bank-transfers");var families=List.of("financeReceipt","financePayment","financeExpense","financeOtherIncome","financeBankTransfer");
        for(int index=0;index<types.size();index++){
            var constructor=types.get(index).getDeclaredConstructors()[0];Object[] dependencies=Arrays.stream(constructor.getParameterTypes()).map(value->mock(value)).toArray();Object controller=constructor.newInstance(dependencies);
            var actions=mock(FinanceDocumentActions.class);ReflectionTestUtils.setField(controller,"documentActions",actions);var http=MockMvcBuilders.standaloneSetup(controller).build();
            UUID id=UUID.randomUUID(),request=UUID.randomUUID();String family=families.get(index),prefix="/api/finance/"+segments.get(index)+"/"+id;
            var succeeded=Map.<String,Object>of("outcome","SUCCEEDED","requestId",request);var cancelled=Map.<String,Object>of("outcome","CANCELLED_UNWRITTEN","requestId",request);
            when(actions.approve(eq(family),eq(id),any(FinanceDocumentActions.ApprovalCommand.class))).thenReturn(succeeded).thenReturn(succeeded).thenReturn(cancelled);
            when(actions.unapprove(eq(family),eq(id),any(com.uten.imp.application.port.FinancialDocumentUnapprovalCommandPort.Command.class))).thenReturn(succeeded).thenReturn(succeeded).thenReturn(cancelled);
            String approval="{\"requestId\":\""+request+"\",\"expectedVersion\":null,\"expectedSnapshot\":\""+"a".repeat(64)+"\"}";
            String reversal="{\"requestId\":\""+request+"\",\"idempotencyKey\":\""+request+"\",\"reason\":\"explicit reviewed correction\",\"expectedSnapshot\":\""+"b".repeat(64)+"\"}";
            for(int attempt=0;attempt<3;attempt++)for(String action:List.of("approve","reverse")){
                String response=http.perform(post(prefix+"/"+action).contentType("application/json").content(action.equals("approve")?approval:reversal)).andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
                assertThat(response).contains(attempt==2?"CANCELLED_UNWRITTEN":"SUCCEEDED");
            }
            verify(actions,times(3)).approve(eq(family),eq(id),argThat(body->body.requestId().equals(request)&&body.expectedVersion()==null&&body.expectedSnapshot().equals("a".repeat(64))));
            verify(actions,times(3)).unapprove(eq(family),eq(id),argThat(body->body.requestId().equals(request)&&body.idempotencyKey().equals(request.toString())&&body.reason().equals("explicit reviewed correction")&&body.expectedSnapshot().equals("b".repeat(64))));
            for(Object dependency:dependencies)verifyNoInteractions(dependency);
        }
    }
    @Test void everyFinanceHttpApprovalAndReversalRejectsTheOldBodylessBypass()throws Exception{
        var types=List.of(
            com.uten.imp.features.finance.receipt.FinanceReceiptController.class,
            com.uten.imp.features.finance.payment.FinancePaymentController.class,
            com.uten.imp.features.finance.expense.FinanceExpenseController.class,
            com.uten.imp.features.finance.other_income.FinanceOtherIncomeController.class,
            com.uten.imp.features.finance.bank_transfer.FinanceBankTransferController.class);
        var segments=List.of("receipts","payments","expenses","incomes","bank-transfers");
        for(int i=0;i<types.size();i++){
            var constructor=types.get(i).getDeclaredConstructors()[0];
            Object controller=constructor.newInstance(Arrays.stream(constructor.getParameterTypes()).map(type->mock(type)).toArray());
            var actions=mock(FinanceDocumentActions.class);ReflectionTestUtils.setField(controller,"documentActions",actions);
            var http=MockMvcBuilders.standaloneSetup(controller).build();
            for(String action:List.of("approve","reverse"))http.perform(post("/api/finance/"+segments.get(i)+"/"+UUID.randomUUID()+"/"+action)).andExpect(status().isBadRequest());
            verifyNoInteractions(actions);
        }
    }

    @Test void defaultHttpMapperRetainsRawFinancialNumbersBeforeAnyUntypedDoubleIsCreated()throws Exception{
        var mapper=new ObjectMapper();UUID id=UUID.randomUUID();
        String raw="{\"requestId\":\""+id+"\",\"expectedVersion\":null,\"expectedSnapshot\":\""+"a".repeat(64)+"\",\"document\":{\"amount\":1234567890123456789012345678901234567890.123456789012345678901234,\"tiny\":0.000000000000000000000001,\"long\":12345678901234567890123456789012345678901234567890,\"remark\":null}}";
        var command=mapper.readValue(raw,FinanceDocumentActions.UpdateCommand.class);
        assertThat(command.document().get("amount").decimalValue()).isEqualByComparingTo("1234567890123456789012345678901234567890.123456789012345678901234");
        assertThat(command.document().get("tiny").decimalValue()).isEqualByComparingTo("0.000000000000000000000001");
        assertThat(command.document().get("long").bigIntegerValue().toString()).isEqualTo("12345678901234567890123456789012345678901234567890");
        assertThat(command.document().has("remark")).isTrue();assertThat(command.document().get("remark").isNull()).isTrue();assertThat(command.document().has("absent")).isFalse();
        var reread=FinancialJsonResults.value(mapper,mapper.writeValueAsString(command),FinanceDocumentActions.UpdateCommand.class);
        assertThat(reread.document()).isEqualTo(command.document());
    }
    @Test void expenseGlConfirmationRequiresTheFrozenReviewBodyAndDelegatesWithoutAControllerAuditReplay()throws Exception{
        var type=com.uten.imp.features.finance.expense.FinanceExpenseController.class;var constructor=type.getDeclaredConstructors()[0];
        Object[] dependencies=Arrays.stream(constructor.getParameterTypes()).map(value->mock(value)).toArray();Object controller=constructor.newInstance(dependencies);
        var actions=mock(FinanceDocumentActions.class);ReflectionTestUtils.setField(controller,"documentActions",actions);var http=MockMvcBuilders.standaloneSetup(controller).build();
        UUID id=UUID.randomUUID(),request=UUID.randomUUID();String path="/api/finance/expenses/"+id+"/gl-confirm";
        http.perform(post(path)).andExpect(status().isBadRequest());verifyNoInteractions(actions);
        when(actions.glConfirm(eq(id),any(FinanceDocumentActions.ApprovalCommand.class))).thenReturn(Map.of("outcome","SUCCEEDED","requestId",request));
        http.perform(post(path).contentType("application/json").content("{\"requestId\":\""+request+"\",\"expectedVersion\":null,\"expectedSnapshot\":\""+"a".repeat(64)+"\"}")).andExpect(status().isOk());
        verify(actions).glConfirm(eq(id),argThat(body->body.requestId().equals(request)&&body.expectedVersion()==null&&body.expectedSnapshot().equals("a".repeat(64))));
        for(Object dependency:dependencies)verifyNoInteractions(dependency);
    }
    @Test void everyDraftDeletionRejectsTheOldBodylessBypassAndRoutesTheOriginalSnapshotBody()throws Exception{
        var types=List.of(com.uten.imp.features.finance.receipt.FinanceReceiptController.class,com.uten.imp.features.finance.payment.FinancePaymentController.class,com.uten.imp.features.finance.expense.FinanceExpenseController.class,com.uten.imp.features.finance.other_income.FinanceOtherIncomeController.class,com.uten.imp.features.finance.bank_transfer.FinanceBankTransferController.class);
        var segments=List.of("receipts","payments","expenses","incomes","bank-transfers");var families=List.of("financeReceipt","financePayment","financeExpense","financeOtherIncome","financeBankTransfer");
        for(int index=0;index<types.size();index++){
            var constructor=types.get(index).getDeclaredConstructors()[0];Object[] dependencies=Arrays.stream(constructor.getParameterTypes()).map(value->mock(value)).toArray();Object controller=constructor.newInstance(dependencies);var actions=mock(FinanceDocumentActions.class);ReflectionTestUtils.setField(controller,"documentActions",actions);
            var http=MockMvcBuilders.standaloneSetup(controller).build();UUID id=UUID.randomUUID(),request=UUID.randomUUID();String family=families.get(index),path="/api/finance/"+segments.get(index)+"/"+id;
            http.perform(delete(path)).andExpect(status().isBadRequest());verifyNoInteractions(actions);
            when(actions.delete(eq(family),eq(id),any(FinanceDocumentActions.ApprovalCommand.class))).thenReturn(Map.of("outcome","SUCCEEDED","requestId",request,"result",Map.of("id",id,"status",0,"deleted",true)));
            http.perform(delete(path).contentType("application/json").content("{\"requestId\":\""+request+"\",\"expectedVersion\":null,\"expectedSnapshot\":\""+"a".repeat(64)+"\"}")).andExpect(status().isOk());
            verify(actions).delete(eq(family),eq(id),argThat(body->body.requestId().equals(request)&&body.expectedVersion()==null&&body.expectedSnapshot().equals("a".repeat(64))));for(Object dependency:dependencies)verifyNoInteractions(dependency);
        }
    }
    @Test void originalPrecisionCancellationNeverGuessesAMissingOrNullScaleAsZero()throws Exception{
        var mapper=new ObjectMapper();var id=UUID.randomUUID();
        var command=new FinanceOperationJournal.Cancellation(id,UUID.randomUUID(),"FINANCE_DOCUMENT_APPROVE","POST","/finance/expenses/"+UUID.randomUUID()+"/approve",mapper.createObjectNode().put("requestId",id.toString()),Map.of("purpose",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(0,"DOWN")));
        String exact=mapper.writeValueAsString(command);assertThat(mapper.readValue(exact,FinanceOperationJournal.Cancellation.class).precisionChoices()).isEqualTo(command.precisionChoices());
        for(String malformed:List.of(exact.replace("\"scale\":0","\"scale\":null"),exact.replace("\"scale\":0,",""),exact.replace("\"scale\":0","\"scale\":0.1"))){
            assertThatThrownBy(()->mapper.readValue(malformed,FinanceOperationJournal.Cancellation.class)).isInstanceOf(com.fasterxml.jackson.core.JsonProcessingException.class);
        }
    }
}
