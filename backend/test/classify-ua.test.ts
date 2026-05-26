import { describe, it, expect } from "vitest";
import { classifyUA } from "../src/routes/downloads";

describe("classifyUA", () => {
  it("classifies Sparkle UA", () => {
    expect(classifyUA("polepole/1.4.2 Sparkle/2.9.1")).toBe("sparkle");
  });

  it("classifies Homebrew UA", () => {
    expect(
      classifyUA("Homebrew/4.5.0 (Macintosh; arm64 Mac OS X 14.5) curl/8.4.0")
    ).toBe("homebrew");
  });

  it("classifies bare curl UA as curl, not browser", () => {
    expect(classifyUA("curl/8.5.0")).toBe("curl");
  });

  it("classifies modern browser UA", () => {
    expect(
      classifyUA(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
      )
    ).toBe("browser");
  });

  it("falls back to other for unknown UA", () => {
    expect(classifyUA("wget/1.21.4")).toBe("other");
  });

  it("treats missing UA as other", () => {
    expect(classifyUA(undefined)).toBe("other");
    expect(classifyUA(null)).toBe("other");
    expect(classifyUA("")).toBe("other");
  });

  it("Sparkle wins over Mozilla if both appear", () => {
    // 念のため: Sparkle UA に Mozilla prefix が付いている亜種があっても sparkle に倒す
    expect(classifyUA("Mozilla/5.0 Sparkle/2.9.1")).toBe("sparkle");
  });
});
