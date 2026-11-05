package com.uten.imp.features.master.account;

import com.uten.imp.application.port.FundingAccountStylePort;
import com.uten.imp.common.mastercode.MasterCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.account.dto.AccountSaveRequest;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class AccountFundingStyleSelectionTest {
    private final AccountRepository repo=mock(AccountRepository.class);
    private final EntityManager em=mock(EntityManager.class);
    private final FundingAccountStylePort funding=mock(FundingAccountStylePort.class);
    private final UUID currency=UUID.randomUUID(),oldStyle=UUID.randomUUID(),newStyle=UUID.randomUUID();
    private final AccountService service=new AccountService(repo,mock(TxSessionVars.class),em,
            mock(MasterCodeService.class),funding);
    private Account existing;

    @BeforeEach void setup() {
        SecurityContextHolder.getContext().setAuthentication(new TestingAuthenticationToken("account-editor","n/a",
                "account:view","account:create","account:edit"));
        existing=new Account();existing.setId(UUID.randomUUID());existing.setCode("ZH-EXISTING");
        existing.setName("保留原账户");existing.setStatus("使用");existing.setCurrencyId(currency);
        existing.setStyleId(oldStyle);existing.setInitBalance(BigDecimal.ZERO);
        when(repo.findById(existing.getId())).thenReturn(Optional.of(existing));
        when(repo.save(any(Account.class))).thenAnswer(call->{Account value=call.getArgument(0);
            if(value.getId()==null)value.setId(UUID.randomUUID());return value;});
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);var parameters=new java.util.HashMap<String,Object>();
            return mock(Query.class,q->{
                if(q.getMethod().getName().equals("setParameter")){parameters.put(q.getArgument(0),q.getArgument(1));return q.getMock();}
                if(q.getMethod().getName().equals("getSingleResult"))return sql.contains("FROM currencies")?1L:0L;
                if(q.getMethod().getName().equals("getResultList")) {
                    if(sql.contains("SELECT id, legacy_id"))return List.<Object[]>of(new Object[]{parameters.get("styleId"),null});
                    if(sql.contains("SELECT code, name, is_deleted"))return List.<Object[]>of(new Object[]{"SK-ORIGINAL","原记账科目",false});
                    return List.of();
                }
                return org.mockito.Answers.RETURNS_DEFAULTS.answer(q);
            });
        });
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void newFundingAccountChecksFinanceMeaningBeforeSaving() {
        var request=request(newStyle);request.setCode("ZH-NEW");
        var result=service.create(request);
        assertThat(result.getStyleId()).isEqualTo(newStyle);
        verify(funding).requireSelectable(newStyle);
        verify(repo).save(any(Account.class));
    }
    @Test void aPostableAssetSubjectIsStillRejectedWhenItIsNotAProvedFundingSubject() {
        doThrow(new ApiException(ErrorCode.VALIDATION_FAILED,"请维护资金记账对应"))
                .when(funding).requireSelectable(newStyle);
        assertThatThrownBy(()->service.create(request(newStyle))).isInstanceOf(ApiException.class)
                .hasMessageContaining("资金记账对应");
        verify(repo,never()).save(any());
    }
    @Test void changingAnUnusedAccountSubjectMustPassTheSameFinanceSelector() {
        doThrow(new ApiException(ErrorCode.VALIDATION_FAILED,"请维护资金记账对应"))
                .when(funding).requireSelectable(newStyle);
        assertThatThrownBy(()->service.update(existing.getId(),request(newStyle))).isInstanceOf(ApiException.class)
                .hasMessageContaining("资金记账对应");
        verify(funding).requireSelectable(newStyle);
        verify(repo,never()).save(any());
        assertThat(existing.getStyleId()).isEqualTo(oldStyle);
    }
    @Test void editingOnlyANameKeepsAnExistingOutOfScopeSubjectAndNeverRemapsIt() {
        existing.setInitBalance(BigDecimal.TEN);
        var request=request(oldStyle);request.setName("只修改名称");
        var result=service.update(existing.getId(),request);
        assertThat(result.getName()).isEqualTo("只修改名称");
        assertThat(result.getStyleId()).isEqualTo(oldStyle);
        assertThat(existing.getInitBalance()).isEqualByComparingTo("10");
        verifyNoInteractions(funding);
        verify(repo).save(existing);
    }
    @Test void candidateReadRequiresAccountActionsAndUsesTheFinancePort() throws Exception {
        var choices=List.of(new FundingAccountStylePort.Choice(newStyle,null,"SK-FUND","资金科目",null));
        when(funding.choices()).thenReturn(choices);
        assertThat(service.postingStyles()).isSameAs(choices);
        String required="hasAnyAuthority('account:create','account:edit')";
        for(var type:List.of(AccountController.class,AccountService.class))assertThat(type.getDeclaredMethod("postingStyles")
                .getAnnotation(org.springframework.security.access.prepost.PreAuthorize.class).value()).isEqualTo(required);
    }
    private AccountSaveRequest request(UUID style) {
        var request=new AccountSaveRequest();request.setName("资金账户");request.setAccountType("BANK");
        request.setCurrencyId(currency);request.setStatus("使用");request.setStyleId(style);return request;
    }
}
