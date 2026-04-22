/**
 * Auth header helper for dispatch tests.
 *
 * The `/dispatch/*` routes require `Authorization: Bearer <secret>`.
 * Tests use the `dispatchAuthSecret` from `testConfig()` so this
 * matches the value the app expects under test.
 */

import { testConfig } from "../src/config/index.js";

export const dispatchAuthHeaders = {
  authorization: `Bearer ${testConfig().dispatchAuthSecret}`,
} as const;
