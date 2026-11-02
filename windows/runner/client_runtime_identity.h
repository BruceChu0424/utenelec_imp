#pragma once

#ifdef UTEN_GENERATED_RUNTIME_PROFILE
#include "client_runtime_profile.g.h"
#else
// Standalone native regressions consume the checked generated formal default.
#include "client_runtime_profile.default.g.h"
#endif
