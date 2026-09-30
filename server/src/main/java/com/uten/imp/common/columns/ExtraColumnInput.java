package com.uten.imp.common.columns;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.UUID;

/** Only the definition identity and exact user value are writable. */
public record ExtraColumnInput(@NotNull UUID columnId, @Size(max = 2000) String value) { }
