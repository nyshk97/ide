import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import type { Bindings } from "./types";
import { webhookRoute } from "./routes/webhook";
import { thanksRoute } from "./routes/thanks";

const app = new Hono<{ Bindings: Bindings }>();

app.use("*", logger());

// アプリからは origin が付かない (Mac native app) ことが多い。
// LP からは polepole.dev origin が付く。両方許可する緩い設定。
// 認証は API key / Stripe 署名 / ライセンスキー + メアドの組み合わせで取る。
app.use(
  "/v1/*",
  cors({
    origin: "*",
    allowMethods: ["POST", "GET", "OPTIONS"],
    maxAge: 600,
  })
);

app.get("/", (c) => c.text("PolePole backend OK"));

app.get("/healthz", (c) =>
  c.json({
    ok: true,
    name: "polepole-backend",
    time: new Date().toISOString(),
  })
);

app.route("/stripe-webhook", webhookRoute);
app.route("/thanks", thanksRoute);

// Phase 3 で実装:
//   POST /v1/license/activate / deactivate / verify / resend
app.post("/v1/license/activate", (c) => c.json({ todo: "phase 3" }, 501));
app.post("/v1/license/deactivate", (c) => c.json({ todo: "phase 3" }, 501));
app.post("/v1/license/verify", (c) => c.json({ todo: "phase 3" }, 501));
app.post("/v1/license/resend", (c) => c.json({ todo: "phase 3" }, 501));

app.onError((err, c) => {
  console.error("unhandled:", err);
  return c.json({ error: "internal_error" }, 500);
});

app.notFound((c) => c.json({ error: "not_found" }, 404));

export default app;
