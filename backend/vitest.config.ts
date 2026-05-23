import { defineConfig } from "vitest/config";

// Phase 1 では Workers の bindings を必要としない sanity test だけ走らせる。
// Phase 2/3 で D1 / fetch を含むテストを書く時点で
// @cloudflare/vitest-pool-workers の defineWorkersProject に切り替える。
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});
