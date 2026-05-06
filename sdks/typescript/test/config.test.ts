import { describe, expect, it } from "vitest";
import {
  DEFAULT_BASE_URL,
  DEFAULT_TIMEOUT_MS,
  readConfigFromEnv,
  resolveConfig,
} from "../src/config.js";

describe("resolveConfig", () => {
  it("requires apiKey", () => {
    expect(() => resolveConfig({ apiKey: "" })).toThrow(/missing apiKey/);
  });

  it("rejects non-cb_ keys", () => {
    expect(() => resolveConfig({ apiKey: "sk_oops" })).toThrow(/cb_/);
  });

  it("strips trailing slashes from baseUrl", () => {
    const cfg = resolveConfig({
      apiKey: "cb_test_dummy_key_for_unit_tests_only",
      baseUrl: "http://localhost:4000///",
    });
    expect(cfg.baseUrl).toBe("http://localhost:4000");
  });

  it("defaults baseUrl + timeout when omitted", () => {
    const cfg = resolveConfig({ apiKey: "cb_test_dummy_key_for_unit_tests_only" });
    expect(cfg.baseUrl).toBe(DEFAULT_BASE_URL);
    expect(cfg.timeoutMs).toBe(DEFAULT_TIMEOUT_MS);
    expect(cfg.userAgent).toMatch(/^cryptobank-js\//);
  });

  it("rejects non-positive timeouts", () => {
    expect(() =>
      resolveConfig({ apiKey: "cb_test_dummy_key_for_unit_tests_only", timeoutMs: 0 }),
    ).toThrow(/timeoutMs/);
  });
});

describe("readConfigFromEnv", () => {
  it("requires CRYPTOBANK_API_KEY", () => {
    expect(() => readConfigFromEnv({} as NodeJS.ProcessEnv)).toThrow(
      /CRYPTOBANK_API_KEY/,
    );
  });

  it("parses base url + timeout", () => {
    const cfg = readConfigFromEnv({
      CRYPTOBANK_API_KEY: "cb_env_dummy_key_for_unit_tests_only",
      CRYPTOBANK_BASE_URL: "http://localhost:5000",
      CRYPTOBANK_TIMEOUT_MS: "1234",
    } as NodeJS.ProcessEnv);

    expect(cfg.apiKey).toBe("cb_env_dummy_key_for_unit_tests_only");
    expect(cfg.baseUrl).toBe("http://localhost:5000");
    expect(cfg.timeoutMs).toBe(1234);
  });

  it("rejects bogus timeouts in the env", () => {
    expect(() =>
      readConfigFromEnv({
        CRYPTOBANK_API_KEY: "cb_env_dummy_key_for_unit_tests_only",
        CRYPTOBANK_TIMEOUT_MS: "not-a-number",
      } as NodeJS.ProcessEnv),
    ).toThrow(/CRYPTOBANK_TIMEOUT_MS/);
  });
});
