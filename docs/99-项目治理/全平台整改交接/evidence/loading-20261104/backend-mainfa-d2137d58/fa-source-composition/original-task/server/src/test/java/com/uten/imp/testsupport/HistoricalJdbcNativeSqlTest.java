package com.uten.imp.testsupport;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import javax.sql.DataSource;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

class HistoricalJdbcNativeSqlTest {
    @Test void historicalSeedingCannotStartEntityAccessOrSilentlyBypassCurrentMappings() {
        var source=mock(DataSource.class);
        var statements=HistoricalJdbcNativeSql.statements(new JdbcTemplate(source));
        assertThatThrownBy(()->statements.find(Object.class,UUID.randomUUID())).isInstanceOf(UnsupportedOperationException.class);
        assertThatThrownBy(()->statements.persist(new Object())).isInstanceOf(UnsupportedOperationException.class);
        assertThatThrownBy(()->statements.createNativeQuery("SELECT 1",Object.class)).isInstanceOf(UnsupportedOperationException.class);
        assertThatThrownBy(()->statements.unwrap(org.hibernate.Session.class)).isInstanceOf(UnsupportedOperationException.class);
        verifyNoInteractions(source);
    }
}
