package com.uten.imp.application.port;

import java.util.UUID;

/** Finance owns the external chart; master data owns safe creation of its native posting identity. */
public interface FinancialChartAccountCreationPort {
    UUID create(String externalCode,String name,String category);
}
