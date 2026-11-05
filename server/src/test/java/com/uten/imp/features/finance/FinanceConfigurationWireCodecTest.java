package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.gl.*;
import com.uten.imp.features.finance.payables.ProcurementPayableRecognitionService;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.mock;

class FinanceConfigurationWireCodecTest {
    private final ObjectMapper json=new ObjectMapper().registerModule(new JavaTimeModule());
    private final FinanceOperationJournal journal=new FinanceOperationJournal(mock(JdbcTemplate.class),json,mock(SecurityContextCurrentUser.class));
    @Test void newBoxedCommandsKeepMissingAndExplicitNullInsteadOfPrimitiveDefaults()throws Exception{
        UUID id=UUID.randomUUID();String missing="{\"requestId\":\""+id+"\"}",explicit="{\"requestId\":\""+id+"\",\"expectedRevision\":null,\"enabled\":null}";
        var omitted=json.readValue(missing,FinanceOperationJournal.WireCommand.class);var nulls=json.readValue(explicit,FinanceOperationJournal.WireCommand.class);
        assertThat(omitted.body().has("expectedRevision")).isFalse();assertThat(nulls.body().has("expectedRevision")).isTrue();
        for(var raw:new FinanceOperationJournal.WireCommand[]{omitted,nulls}){var command=journal.decodeOriginal(raw,ProcurementPayableRecognitionService.PolicyCommand.class);assertThat(command.expectedRevision()).isNull();assertThat(command.enabled()).isNull();}
        var inventory=journal.decodeOriginal(omitted,InventoryCostPostingService.PolicyCommand.class);assertThat(inventory.expectedVersion()).isNull();assertThat(inventory.enabled()).isNull();
        var binding=journal.decodeOriginal(omitted,GlReportLineBindingService.ReplaceCommand.class);assertThat(binding.targetIds()).isNull();assertThat(binding.confirmedZero()).isNull();
        assertThat(journal.decodeOriginal(omitted,InventoryCostPostingService.CloseCommand.class).expectedVersion()).isNull();
    }
    @Test void explicitFalseZeroAndAnExplicitEmptyTargetListRemainValidWireValues()throws Exception{
        UUID id=UUID.randomUUID();var ap=journal.decodeOriginal(json.readValue("{\"requestId\":\""+id+"\",\"expectedRevision\":0,\"enabled\":false}",FinanceOperationJournal.WireCommand.class),ProcurementPayableRecognitionService.PolicyCommand.class);
        assertThat(ap.expectedRevision()).isZero();assertThat(ap.enabled()).isFalse();
        var binding=journal.decodeOriginal(json.readValue("{\"requestId\":\""+id+"\",\"targetIds\":[],\"confirmedZero\":false}",FinanceOperationJournal.WireCommand.class),GlReportLineBindingService.ReplaceCommand.class);assertThat(binding.targetIds()).isEmpty();assertThat(binding.confirmedZero()).isFalse();
    }
    @Test void coercibleStringsAndFractionalVersionsAreMalformedRatherThanNewFlagsOrCasValues()throws Exception{
        for(String fields:new String[]{"\"enabled\":\"false\"","\"expectedRevision\":0.1","\"expectedRevision\":\"0\""}){
            var original=json.readValue("{\"requestId\":\""+UUID.randomUUID()+"\","+fields+"}",FinanceOperationJournal.WireCommand.class);
            assertThatThrownBy(()->journal.decodeOriginal(original,ProcurementPayableRecognitionService.PolicyCommand.class)).isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.MALFORMED_REQUEST));
        }
    }
}
