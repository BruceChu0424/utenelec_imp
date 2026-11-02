#include "accessibility_probe.h"
#include <oleacc.h>
#include <atomic>
#include <cwchar>

namespace {
std::atomic<bool> active{false};
std::atomic<unsigned> queries{0}, failures{0};
std::atomic<unsigned> value_queries{0}, retained_value_reads{0};
std::atomic<int64_t> last_cycle{-1};
void ReadAttributes(IAccessible* object, VARIANT child) {
  BSTR text = nullptr;
  if (SUCCEEDED(object->get_accName(child, &text)) && text) {
    // Never save arbitrary accessible names. Only this offline fixture's
    // synthetic counter is retained, as a numeric freshness check.
    constexpr wchar_t prefix[] = L"Semantics reparent cycles: ";
    const auto found = wcsstr(text, prefix);
    if (found) last_cycle = _wcstoi64(found + (sizeof(prefix) / sizeof(wchar_t) - 1), nullptr, 10);
    SysFreeString(text);
  }
  // Exercise the field-confirmed get_accValue path too. Persist only a count
  // for the known offline fixture input, never an arbitrary accessible value.
  text = nullptr;
  ++value_queries;
  if (SUCCEEDED(object->get_accValue(child, &text)) && text) {
    if (wcscmp(text, L"0001. retained input") == 0) ++retained_value_reads;
    SysFreeString(text);
  }
}
void Visit(IAccessible* object, unsigned depth, unsigned& budget) {
  if (!depth || !budget) return;
  --budget;
  VARIANT self{}; self.vt = VT_I4; self.lVal = CHILDID_SELF;
  ReadAttributes(object, self);
  long children = 0;
  if (FAILED(object->get_accChildCount(&children)) || children <= 0) return;
  VARIANT values[64]{};
  long count = 0;
  if (FAILED(AccessibleChildren(object, 0, children < 64 ? children : 64, values, &count))) return;
  for (long i = 0; i < count && i < 64; ++i) {
    IDispatch* dispatch = nullptr;
    if (budget && values[i].vt == VT_DISPATCH) {
      dispatch = values[i].pdispVal;
      if (dispatch) dispatch->AddRef();
    } else if (budget && values[i].vt == VT_I4) {
      ReadAttributes(object, values[i]);
      object->get_accChild(values[i], &dispatch);
    }
    if (dispatch) {
      IAccessible* child = nullptr;
      if (SUCCEEDED(dispatch->QueryInterface(IID_IAccessible, reinterpret_cast<void**>(&child)))) {
        Visit(child, depth - 1, budget); child->Release();
      }
      dispatch->Release();
    }
    VariantClear(&values[i]);
  }
}
DWORD WINAPI Observe(void* argument) {
  const HWND window = static_cast<HWND>(argument);
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  Sleep(1500);
  IAccessible* root = nullptr;
  while (active && IsWindow(window)) {
    if (IsIconic(window)) { Sleep(30); continue; }
    if (!root) {
      const HWND child = GetWindow(window, GW_CHILD);
      AccessibleObjectFromWindow(child ? child : window, static_cast<DWORD>(OBJID_CLIENT), IID_IAccessible, reinterpret_cast<void**>(&root));
    }
    if (root) {
      unsigned budget = 512;
      Visit(root, 20, budget);
      RECT rectangle{}; GetWindowRect(window, &rectangle);
      VARIANT hit{};
      const HRESULT result = root->accHitTest((rectangle.left + rectangle.right) / 2,
          (rectangle.top + rectangle.bottom) / 2, &hit);
      VariantClear(&hit);
      ++queries;
      if (FAILED(result)) { ++failures; root->Release(); root = nullptr; }
    } else ++failures;
    Sleep(25);
  }
  if (root) root->Release();
  if (SUCCEEDED(com)) CoUninitialize();
  return 0;
}
}  // namespace
void StartAccessibilityProbe(HWND window) { active = true; QueueUserWorkItem(Observe, window, WT_EXECUTELONGFUNCTION); }
void StopAccessibilityProbe() { active = false; }
AccessibilityProbeSnapshot ReadAccessibilityProbe() {
  return {queries.load(), failures.load(), last_cycle.load(),
          value_queries.load(), retained_value_reads.load()};
}
