package com.uten.imp.application.port;

import java.util.List;
import java.util.Objects;

/** Public company identity only. Consumers capture one immutable snapshot per document/job. */
public interface CompanyBrandingReadPort {
    Identity currentIdentity();

    record Identity(int version, String companyName, List<String> companyAliases) {
        public Identity {
            Objects.requireNonNull(companyName, "companyName");
            companyAliases = List.copyOf(companyAliases);
        }
    }
}
