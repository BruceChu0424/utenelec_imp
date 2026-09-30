package com.uten.imp.common.platformcolumns;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.common.platformcolumns.PlatformColumnContracts.*;
import static org.assertj.core.api.Assertions.*;

class PlatformColumnCalculatorTest {
    @Test void displayMathUsesExplicitFactsAndPreservesNegativeExactResults() {
        UUID id=UUID.randomUUID();
        var definition=new Definition(id,"goods","差额","CALCULATED",false,
                new Formula(new Operand(null,"qty",null),List.of(
                        new Step("SUBTRACT",new Operand(null,null,"8")),new Step("DIVIDE",new Operand(null,null,"2")))),0,0);
        assertThat(PlatformColumnService.evaluate(id,Map.of(id,definition),Map.of(),Map.of("qty",new BigDecimal("3.123456")),new HashSet<>(),0))
                .isEqualByComparingTo("-2.438272");
    }
    @Test void missingFactsStayUnknownAndZeroOrNonFiniteDivisionIsExplicit() {
        UUID id=UUID.randomUUID();
        for(String divisor:List.of("0","3")) {
            var definition=new Definition(id,"goods","显示","CALCULATED",false,
                    new Formula(new Operand(null,"qty",null),List.of(new Step("DIVIDE",new Operand(null,null,divisor)))),0,0);
            assertThat(PlatformColumnService.evaluate(id,Map.of(id,definition),Map.of(),Map.of(),new HashSet<>(),0)).isNull();
            assertThatThrownBy(()->PlatformColumnService.evaluate(id,Map.of(id,definition),Map.of(),Map.of("qty",BigDecimal.ONE),new HashSet<>(),0))
                    .isInstanceOf(ApiException.class);
        }
    }
    @Test void cyclesCannotExecuteAndSharedDependencyGraphsAreBounded() {
        UUID id=UUID.randomUUID();
        var cycle=new Definition(id,"goods","loop","CALCULATED",false,
                new Formula(new Operand(id,null,null),List.of()),0,0);
        assertThatThrownBy(()->PlatformColumnService.evaluate(id,Map.of(id,cycle),Map.of(),Map.of(),new HashSet<>(),0)).isInstanceOf(ApiException.class);
        Map<UUID,Definition> definitions=new HashMap<>();
        UUID prior=UUID.randomUUID();
        definitions.put(prior,new Definition(prior,"goods","base","NUMBER",false,null,0,0));
        Map<UUID,String> values=Map.of(prior,"1");
        for(int i=0;i<12;i++) {
            UUID next=UUID.randomUUID();
            definitions.put(next,new Definition(next,"goods","level"+i,"CALCULATED",false,
                    new Formula(new Operand(prior,null,null),Collections.nCopies(16,new Step("ADD",new Operand(prior,null,null)))),0,0));
            prior=next;
        }
        assertThat(PlatformColumnService.evaluate(prior,definitions,values,Map.of(),new HashSet<>(),0))
                .isEqualByComparingTo(BigDecimal.valueOf(17).pow(12));
    }
}
