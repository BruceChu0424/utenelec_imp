package com.uten.imp.common.export;

import java.util.Map;

/** Server support for selected rows is independent of durable artifact storage. */
public final class OutputSelectionProtocol {
    public static final int VERSION = 1;
    private OutputSelectionProtocol() { }
    public static Map<String,Object> capabilities(boolean available) {
        return Map.of("available",available,"selectionVersion",VERSION);
    }
}
