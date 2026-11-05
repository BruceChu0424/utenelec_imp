package com.uten.imp.common.export;
import java.util.List;
import java.util.UUID;
/** Nullable selection means the complete current filter; an empty selection is invalid. */
public interface MasterExportSelectionRequest { List<UUID> selectedIds(); }
