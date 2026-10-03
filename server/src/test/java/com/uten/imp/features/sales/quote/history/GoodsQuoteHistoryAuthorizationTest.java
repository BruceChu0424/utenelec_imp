package com.uten.imp.features.sales.quote.history;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

class GoodsQuoteHistoryAuthorizationTest {
    @Configuration @EnableMethodSecurity static class Config {
        @Bean NamedParameterJdbcTemplate jdbc() { return mock(NamedParameterJdbcTemplate.class); }
        @Bean GoodsQuoteHistoryService history(NamedParameterJdbcTemplate jdbc) { return new GoodsQuoteHistoryService(jdbc); }
    }
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void salesOrGoodsPricePermissionAloneCannotReadOtherCustomersQuoteHistory() {
        try (var context = new AnnotationConfigApplicationContext(Config.class)) {
            var service = context.getBean(GoodsQuoteHistoryService.class);
            for (var permissions : List.of(
                    List.of("goods:view", "goods:price:view", "sales_quote:view"),
                    List.of("sales_quote_finance:view"))) {
                SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                        "test", "unused", permissions.stream().map(SimpleGrantedAuthority::new).toList()));
                assertThatThrownBy(() -> service.list(UUID.randomUUID(), 1, 20)).isInstanceOf(AccessDeniedException.class);
            }
            verifyNoInteractions(context.getBean(NamedParameterJdbcTemplate.class));
        }
    }
}
