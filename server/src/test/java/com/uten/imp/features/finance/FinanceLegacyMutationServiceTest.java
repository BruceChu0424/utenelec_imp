package com.uten.imp.features.finance;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.lang.reflect.InvocationTargetException;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.RETURNS_DEEP_STUBS;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.mockingDetails;

class FinanceLegacyMutationServiceTest {
    @ParameterizedTest
    @ValueSource(strings={"receipt:FinanceReceipt", "payment:FinancePayment", "expense:FinanceExpense",
            "other_income:FinanceOtherIncome", "bank_transfer:FinanceBankTransfer"})
    void legacyHeaderCannotReachAnyMoneyMutation(String family) throws Exception {
        String[] names=family.split(":");
        String prefix="com.uten.imp.features.finance."+names[0]+"."+names[1];
        Class<?> entityType=Class.forName(prefix);
        Object entity=entityType.getConstructor().newInstance();
        UUID id=UUID.randomUUID();
        entityType.getMethod("setId",UUID.class).invoke(entity,id);
        entityType.getMethod("setLegacyId",Integer.class).invoke(entity,900001);
        entityType.getMethod("setStatus",Short.class).invoke(entity,(short)1);
        entityType.getMethod("setBillDate",LocalDate.class).invoke(entity,LocalDate.of(2025,1,2));
        for (String setter : List.of("setSupplierId","setCurrencyId","setAccountId","setOutAccountId")) {
            try { entityType.getMethod(setter,UUID.class).invoke(entity,UUID.randomUUID()); }
            catch (NoSuchMethodException ignored) { /* Different finance families have different accounts. */ }
        }
        var constructor=Arrays.stream(Class.forName(prefix+"Service").getConstructors())
                .max(Comparator.comparingInt(java.lang.reflect.Constructor::getParameterCount)).orElseThrow();
        List<Object> dependencies=new ArrayList<>();
        for (Class<?> type:constructor.getParameterTypes()) {
            Object dependency=mock(type, invocation -> {
                if (invocation.getMethod().getReturnType()==Optional.class) return Optional.of(entity);
                return RETURNS_DEEP_STUBS.answer(invocation);
            });
            dependencies.add(dependency);
        }
        Object service=constructor.newInstance(dependencies.toArray());
        for (String operation:List.of("update","delete","approve","reverse","glConfirm")) {
            var method=Arrays.stream(service.getClass().getMethods()).filter(m->m.getName().equals(operation))
                    .findFirst();
            if (method.isEmpty()) continue;
            Object[] args=Arrays.stream(method.get().getParameterTypes())
                    .map(type->type==UUID.class?id:mock(type)).toArray();
            assertThatThrownBy(()->method.get().invoke(service,args)).as(names[1]+"."+operation)
                    .isInstanceOf(InvocationTargetException.class)
                    .cause().isInstanceOf(ApiException.class).hasMessageContaining("历史资金记录仅供核对");
        }
        for (Object dependency:dependencies) {
            assertThat(mockingDetails(dependency).getInvocations()).allSatisfy(invocation -> {
                assertThat(invocation.getMethod().getName()).doesNotMatch("save.*|delete.*|post.*|reverse.*|adjust.*");
                if (dependency instanceof EntityManager && invocation.getMethod().getName().equals("createNativeQuery")) {
                    assertThat(invocation.getArgument(0,String.class).stripLeading().toUpperCase())
                            .doesNotStartWith("INSERT ")
                            .doesNotStartWith("UPDATE ")
                            .doesNotStartWith("DELETE ");
                }
            });
        }
    }

    @Test
    void ordinaryNewDocumentsHaveNoLegacyIdentityAndRemainEligible() {
        FinanceLegacyRecordGuard.requireMutable(null);
        assertThatThrownBy(()->FinanceLegacyRecordGuard.requireMutable(1))
                .isInstanceOf(ApiException.class).hasMessageContaining("历史资金记录");
    }
}
