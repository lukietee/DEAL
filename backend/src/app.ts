import cors from "@fastify/cors";
import Anthropic from "@anthropic-ai/sdk";
import Fastify, { type FastifyInstance } from "fastify";
import { createAi, type Ai } from "./ai/index.js";
import type { Config } from "./config.js";
import { listScriptIds } from "./content.js";
import { Deal, HttpError } from "./deal.js";
import { LookRunner } from "./look.js";
import { createPayments, type Payments } from "./payments/index.js";
import { ResearchRunner } from "./research.js";
import { agreementRoutes } from "./routes/agreements.js";
import { eventRoutes } from "./routes/events.js";
import { listingRoutes } from "./routes/listings.js";
import { lookRoutes } from "./routes/look.js";
import { paymentRoutes } from "./routes/payments.js";
import { researchRoutes } from "./routes/research.js";
import { sessionRoutes } from "./routes/sessions.js";
import type { Store } from "./store/index.js";
import { MemoryStore } from "./store/memory.js";
import { SupabaseStore } from "./store/supabase.js";

export interface AppDeps {
  store?: Store;
  ai?: Ai;
  payments?: Payments;
  research?: ResearchRunner;
  look?: LookRunner;
  logger?: boolean;
}

export async function buildApp(cfg: Config, deps: AppDeps = {}): Promise<{ app: FastifyInstance; deal: Deal }> {
  const app = Fastify({ logger: deps.logger ?? true, bodyLimit: 12_000_000 /* base64 screenshots / photos */ });
  await app.register(cors, { origin: true, methods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"] });

  const store =
    deps.store ??
    (cfg.supabaseUrl && cfg.supabaseServiceRoleKey ? new SupabaseStore(cfg.supabaseUrl, cfg.supabaseServiceRoleKey) : new MemoryStore());
  const ai = deps.ai ?? createAi(cfg, app.log);
  const payments = deps.payments ?? createPayments(cfg.stripeSecretKey);
  const client = ai.kind === "claude" ? new Anthropic({ apiKey: cfg.anthropicApiKey, maxRetries: 2 }) : null;
  const research = deps.research ?? new ResearchRunner({
    mockMode: ai.kind !== "claude",
    client,
    model: cfg.researchModel,
    cueModel: cfg.cueModel,
    log: app.log,
  });
  const look = deps.look ?? new LookRunner({ mockMode: ai.kind !== "claude", client, model: cfg.cueModel, log: app.log });
  const deal = new Deal(store, ai, payments, cfg, research, look);

  app.setErrorHandler((err: unknown, _req, reply) => {
    if (err instanceof HttpError) {
      return reply.code(err.statusCode).send({ error: err.message, ...(err.details !== undefined ? { details: err.details } : {}) });
    }
    const e = err as { statusCode?: number; message?: string };
    const code = e.statusCode && e.statusCode >= 400 && e.statusCode < 600 ? e.statusCode : 500;
    if (code >= 500) app.log.error(err);
    return reply.code(code).send({ error: e.message ?? "internal error" });
  });

  app.get("/health", async () => ({
    ok: true,
    mock_mode: cfg.mockMode,
    ai: ai.kind,
    store: store.kind,
    payments: payments.kind,
    models: ai.kind === "claude" ? { cue: cfg.cueModel, agreement: cfg.agreementModel, research: cfg.researchModel } : null,
    scripts: listScriptIds(),
    time: new Date().toISOString(),
  }));

  sessionRoutes(app, deal);
  eventRoutes(app, deal);
  agreementRoutes(app, deal);
  paymentRoutes(app, deal);
  listingRoutes(app, deal);
  researchRoutes(app, deal);
  lookRoutes(app, deal);

  app.addHook("onClose", async () => deal.stopAll());
  return { app, deal };
}
