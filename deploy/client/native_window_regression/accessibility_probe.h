#ifndef UTEN_ACCESSIBILITY_PROBE_H_
#define UTEN_ACCESSIBILITY_PROBE_H_
#include <windows.h>
#include <cstdint>
struct AccessibilityProbeSnapshot {
  unsigned queries;
  unsigned failures;
  int64_t last_cycle;
  unsigned value_queries;
  unsigned retained_value_reads;
};
void StartAccessibilityProbe(HWND window);
void StopAccessibilityProbe();
AccessibilityProbeSnapshot ReadAccessibilityProbe();
#endif
