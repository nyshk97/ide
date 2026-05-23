import { describe, it, expect } from "vitest";
import { generateLicenseKey, isValidKeyFormat } from "../src/lib/keygen";

describe("keygen", () => {
  it("generates keys that match the expected format", () => {
    for (let i = 0; i < 100; i++) {
      const key = generateLicenseKey();
      expect(isValidKeyFormat(key)).toBe(true);
      expect(key.startsWith("polepole-")).toBe(true);
    }
  });

  it("does not use ambiguous characters (0/O/1/I/l) in the random portion", () => {
    for (let i = 0; i < 1000; i++) {
      const key = generateLicenseKey();
      const randomPart = key.slice("polepole-".length);
      expect(randomPart).not.toMatch(/[0O1I]/);
    }
  });

  it("rejects malformed keys", () => {
    expect(isValidKeyFormat("polepole-ABCD-ABCD-ABCD-ABCD")).toBe(true);
    expect(isValidKeyFormat("polepole-abcd-ABCD-ABCD-ABCD")).toBe(false);
    expect(isValidKeyFormat("foobar-ABCD-ABCD-ABCD-ABCD")).toBe(false);
    expect(isValidKeyFormat("polepole-ABCD-ABCD-ABCD")).toBe(false);
    expect(isValidKeyFormat("")).toBe(false);
  });
});
