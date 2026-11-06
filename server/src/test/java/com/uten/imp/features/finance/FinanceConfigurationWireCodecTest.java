package com.uten.imp.features.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import com.uten.imp.common.finance.FinancialJsonResults;
import com.uten.imp.common.web.*;
import com.uten.imp.features.finance.gl.*;
import com.uten.imp.features.finance.payables.ProcurementPayableRecognitionService;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import java.util.UUID;
import java.util.Optional;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

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
    @Test void journalAdaptersShareExactOriginalObjectIdentityWithoutMutatingItsNumbersOrOrder()throws Exception{
        String value="123456789012345678901234567890.123456789012345678901234";
        var original=FinancialJsonResults.tree(json,"{\"amount\":"+value+",\"targets\":[\"a\",\"b\"],\"flag\":false,\"memo\":null}");
        var before=original.deepCopy();
        String originalWire=json.writeValueAsString(original);
        var reordered=FinancialJsonResults.tree(json,"{\"memo\":null,\"flag\":false,\"targets\":[\"a\",\"b\"],\"amount\":"+value+"}");
        assertThat(journal.originalBodyFingerprint(original)).isEqualTo(journal.originalBodyFingerprint(reordered));
        assertThatCode(()->journal.requireOriginalBodyMatch(original,reordered)).doesNotThrowAnyException();
        assertThat(original).isEqualTo(before);
        assertThat(json.writeValueAsString(original)).isEqualTo(originalWire);
        assertThat(original.get("amount").decimalValue()).isEqualByComparingTo(value);
        for(String changed:new String[]{
                "{\"amount\":"+value+",\"targets\":[\"b\",\"a\"],\"flag\":false,\"memo\":null}",
                "{\"amount\":\""+value+"\",\"targets\":[\"a\",\"b\"],\"flag\":false,\"memo\":null}",
                "{\"amount\":"+value+",\"targets\":[\"a\",\"b\"],\"flag\":\"false\",\"memo\":null}",
                "{\"amount\":"+value+",\"targets\":[\"a\",\"b\"],\"flag\":false}",
                "{\"amount\":123456789012345678901234567890.123456789012345678901235,\"targets\":[\"a\",\"b\"],\"flag\":false,\"memo\":null}"}){
            var other=FinancialJsonResults.tree(json,changed);
            assertThatThrownBy(()->journal.requireOriginalBodyMatch(original,other))
                    .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        }
        for(String invalid:new String[]{"null","[]","\"body\"","0"}){
            var other=FinancialJsonResults.tree(json,invalid);
            assertThatThrownBy(()->journal.originalBodyFingerprint(other)).isInstanceOf(ApiException.class);
            assertThatThrownBy(()->journal.requireOriginalBodyMatch(original,other)).isInstanceOf(ApiException.class);
        }
    }
    @Test void importCancellationUsesItsOriginalOpaqueIdentityAndKeepsTheSameActorAndBodyGuards()throws Exception{
        var current=mock(SecurityContextCurrentUser.class);var actor=UUID.randomUUID();
        var principal=mock(com.uten.imp.security.AuthUser.class);
        when(current.requireId()).thenReturn(actor);when(current.get()).thenReturn(Optional.of(principal));
        when(principal.isAccountNonLocked()).thenReturn(true);
        var db=mock(JdbcTemplate.class);var adapter=new FinanceOperationJournal(db,json,current);
        var id=UUID.randomUUID();var original=json.createObjectNode().put("importId",id.toString());
        var cancellation=new FinanceOperationJournal.Cancellation(id,actor,"CHART_IMPORT_APPLY","POST","/finance/chart/import-apply",original);
        var typed=adapter.cancellationBodyForIdentityField(id,cancellation,"CHART_IMPORT_APPLY","POST","/finance/chart/import-apply","importId",FinanceChartContracts.Apply.class);
        assertThat(typed.importId()).isEqualTo(id);
        assertThat(original).isEqualTo(json.createObjectNode().put("importId",id.toString()));
        assertThatThrownBy(()->adapter.cancellationBody(id,cancellation,"CHART_IMPORT_APPLY","POST","/finance/chart/import-apply",FinanceChartContracts.Apply.class)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->adapter.cancellationBodyForIdentityField(id,cancellation,"CHART_IMPORT_APPLY","POST","/finance/chart/import-apply","actorId",FinanceChartContracts.Apply.class)).isInstanceOf(IllegalArgumentException.class);
        var other=new FinanceOperationJournal.Cancellation(id,UUID.randomUUID(),cancellation.operation(),cancellation.method(),cancellation.path(),original);
        assertThatThrownBy(()->adapter.cancellationBodyForIdentityField(id,other,cancellation.operation(),cancellation.method(),cancellation.path(),"importId",FinanceChartContracts.Apply.class))
            .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        var changed=new FinanceOperationJournal.Cancellation(id,actor,cancellation.operation(),cancellation.method(),cancellation.path(),json.createObjectNode().put("importId",UUID.randomUUID().toString()));
        assertThatThrownBy(()->adapter.cancellationBodyForIdentityField(id,changed,cancellation.operation(),cancellation.method(),cancellation.path(),"importId",FinanceChartContracts.Apply.class)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->adapter.cancellationBodyForIdentityField(id,cancellation,cancellation.operation(),"PUT",cancellation.path(),"importId",FinanceChartContracts.Apply.class)).isInstanceOf(ApiException.class);
        var extra=new FinanceOperationJournal.Cancellation(id,actor,cancellation.operation(),cancellation.method(),cancellation.path(),original.deepCopy().put("requestId",id.toString()));
        assertThatThrownBy(()->adapter.cancellationBodyForIdentityField(id,extra,cancellation.operation(),cancellation.method(),cancellation.path(),"importId",FinanceChartContracts.Apply.class)).isInstanceOf(ApiException.class);
        verifyNoInteractions(db);
    }
}
