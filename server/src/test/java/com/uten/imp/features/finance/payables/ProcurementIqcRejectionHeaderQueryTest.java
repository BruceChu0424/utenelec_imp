package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterUtils;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ProcurementIqcRejectionHeaderQueryTest {
    @Test void serviceBindsEveryReasonPlaceholderAndNeverBindsSortOnlyLabelsIntoTheCountQuery() {
        for(boolean filtering:new boolean[]{false,true}) {
            UUID owner=UUID.randomUUID();
            var current=mock(SecurityContextCurrentUser.class);
            when(current.requireId()).thenReturn(owner);
            when(current.get()).thenReturn(Optional.of(new AuthUser(owner,UUID.randomUUID(),"iqc-binding",
                    Set.of("procurement_iqc_rejection:view"),false,true,false)));
            var em=mock(EntityManager.class);
            List<String> statements=new ArrayList<>();
            List<Map<String,Object>> bindings=new ArrayList<>();
            when(em.createNativeQuery(anyString())).thenAnswer(call->{
                String sql=call.getArgument(0);statements.add(sql);
                Map<String,Object> values=new LinkedHashMap<>();bindings.add(values);
                Set<String> declared=new java.util.HashSet<>();
                NamedParameterUtils.buildSqlParameterList(NamedParameterUtils.parseSqlStatement(sql),
                        new MapSqlParameterSource()).forEach(parameter->declared.add(parameter.getName()));
                return mock(Query.class,invocation->switch(invocation.getMethod().getName()) {
                    case "setParameter" -> {
                        String name=invocation.getArgument(0);
                        assertThat(declared).as("JPA rejects binding a parameter absent from this query").contains(name);
                        values.put(name,invocation.getArgument(1));yield invocation.getMock();
                    }
                    case "getResultList" -> {assertThat(values.keySet()).containsExactlyInAnyOrderElementsOf(declared);yield List.of();}
                    case "getSingleResult" -> {assertThat(values.keySet()).containsExactlyInAnyOrderElementsOf(declared);yield 0L;}
                    default -> RETURNS_DEFAULTS.answer(invocation);
                });
            });
            var service=new ProcurementIqcRejectionService(em,null,current,null,null,null,null,null,null,null,null);
            service.list(null,null,null,1,20,filtering
                    ?Map.of("search.holdReason","闭环","sort","holdReason","order","asc")
                    :Map.of("sort","holdReason","order","asc"));
            assertThat(statements).hasSize(2);
            assertThat(bindings.getFirst().values()).contains("CREDIT_CONFIRMED","供应商贷项已闭环");
            assertThat(bindings.get(1).keySet().stream().anyMatch(key->key.startsWith("iqc_reason_")))
                    .isEqualTo(filtering);
        }
    }

    @Test void reasonLabelsAreBoundOnlyToQueriesThatActuallyUseTheReasonExpression() {
        var filter=ProcurementIqcRejectionColumnQuery.read(Map.of("search.holdReason","贷项已闭环"),false);
        assertThat(filter.criteria().predicate()).contains(":iqc_reason_status_",":iqc_reason_label_")
                .doesNotContain("供应商贷项已闭环");
        assertThat(filter.criteria().parameters().values()).contains("CREDIT_CONFIRMED","供应商贷项已闭环");
        assertThat(filter.orderParameters()).isEmpty();
        var ordering=ProcurementIqcRejectionColumnQuery.read(Map.of("sort","holdReason","order","asc"),false);
        assertThat(ordering.criteria().parameters()).isEmpty();
        assertThat(ordering.orderBy()).contains(":iqc_reason_status_",":iqc_reason_label_");
        assertThat(ordering.orderParameters().values()).contains("CREDIT_CONFIRMED","供应商贷项已闭环");
        var ordinary=ProcurementIqcRejectionColumnQuery.read(Map.of("sort","failedQty","order","asc"),false);
        assertThat(ordinary.criteria().parameters()).isEmpty();
        assertThat(ordinary.orderParameters()).isEmpty();
    }

    @Test void amountCriteriaAreDeniedBeforeParsingWhenTheAmountIsMasked() {
        for(var query:List.of(Map.of("search.amount","NaN"),Map.of("search.amount",">=25"),
                Map.of("sort","amount","order","desc")))
            assertThatThrownBy(()->ProcurementIqcRejectionColumnQuery.read(query,false))
                    .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
    }
    @Test void quantitiesAndLocalMoneyRemainExactAndRequestTextCannotBecomeSql() {
        var read=ProcurementIqcRejectionColumnQuery.read(Map.of("search.amount",">=90071992547409.1234",
                "search.failedQty","0.0001..2.5001","search.goodsName","螺丝_%","sort","amount","order","desc"),true);
        assertThat(read.criteria().predicate()).contains("rejection.failed_qty","rejection.failed_amount_local","goods.name")
                .doesNotContain("failed_amount_original","螺丝_%","90071992547409");
        assertThat(read.criteria().parameters().values()).contains(new BigDecimal("90071992547409.1234"),
                new BigDecimal("0.0001"),new BigDecimal("2.5001"));
        assertThat(read.orderBy()).startsWith("rejection.failed_amount_local DESC NULLS LAST");
        assertThatThrownBy(()->ProcurementIqcRejectionColumnQuery.read(Map.of("search.ownerUserId","other"),true))
                .isInstanceOf(ApiException.class);
    }
    @Test void displayReasonKeepsTheVisibleMessagePrecedenceAndCalendarIndependentNextStep() {
        assertThat(ProcurementIqcRejectionColumnQuery.displayReason("FINANCE_EXCEPTION","  编码待修复  ","fallback"))
                .isEqualTo("编码待修复");
        assertThat(ProcurementIqcRejectionColumnQuery.displayReason("PENDING_RETURN","  ","未闭环"))
                .isEqualTo("未闭环");
        assertThat(ProcurementIqcRejectionColumnQuery.displayReason("FINANCE_EXCEPTION",null,null))
                .isEqualTo("下一步：修复后重试财务投影");
        assertThat(ProcurementIqcRejectionColumnQuery.displayReason("CREDIT_CONFIRMED",null,null))
                .isEqualTo("供应商贷项已闭环");
    }
}
