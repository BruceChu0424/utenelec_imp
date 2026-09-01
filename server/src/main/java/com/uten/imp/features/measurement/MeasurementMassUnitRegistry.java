package com.uten.imp.features.measurement;

import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.UUID;

/** Authoritative dimension check; unit names are deliberately not inspected. */
@Repository
@RequiredArgsConstructor
public class MeasurementMassUnitRegistry {

    private final JdbcTemplate jdbc;

    public boolean isMassUnit(UUID unitId) {
        if (unitId == null) return false;
        Integer count = jdbc.queryForObject("""
                SELECT count(*)
                FROM unit_measurement_profiles
                WHERE unit_id = ? AND measurement_dimension = 'MASS'
                """, Integer.class, unitId);
        return count != null && count == 1;
    }
}
