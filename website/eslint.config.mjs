import { defineConfig, globalIgnores } from 'eslint/config';
import nextVitals from 'eslint-config-next/core-web-vitals';
export default defineConfig([
  ...nextVitals,
  // Existing server-driven forms intentionally render dynamic translations and
  // update draft previews from input handlers; retain useful correctness rules.
  { rules: { 'react-hooks/set-state-in-effect': 'off', 'react-hooks/refs': 'off' } },
  globalIgnores(['.next/**', 'generated/**', '.scrape/**', '.local-artifacts/**', 'next-env.d.ts']),
]);
