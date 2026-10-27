import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const BACKEND_ROOT = resolve(here, "..");

// Load backend/.env if present (Node 24 built-in; no dotenv dependency).
const envPath = resolve(BACKEND_ROOT, ".env");
if (existsSync(envPath) && !process.env.DEAL_SKIP_DOTENV) {
  process.loadEnvFile(envPath);
}

/** Treat empty strings and template placeholders like "sk_test_..." as unset. */
function secret(name: string): string {
  const v = (process.env[name] ?? "").trim();
  if (!v || v.includes("...") || v.startsWith("<")) return "";
  return v;
}

export function loadConfig() {
  const mockMode = (process.env.MOCK_MODE ?? "true").trim().toLowerCase() !== "false";
  return {
    port: Number(process.env.PORT ?? 3000),
    host: process.env.HOST ?? "0.0.0.0",
    mockMode,
    anthropicApiKey: secret("ANTHROPIC_API_KEY"),
    cueModel: process.env.CUE_MODEL?.trim() || "claude-haiku-5-5",
    agreementModel: process.env.AGREEMENT_MODEL?.trim() || "claude-sonnet-5-5",
    researchModel: process.env.RESEARCH_MODEL?.trim() || "claude-opus-5-5", // live research agents (web search)
    // Nebius Token Factory (NVIDIA Nemotron). When NEBIUS_API_KEY is set, real mode runs on Nemotron;
    // AI_PROVIDER=claude forces the Claude path instead.
    nebiusApiKey: secret("NEBIUS_API_KEY"),
    nebiusBaseUrl: process.env.NEBIUS_BASE_URL?.trim() || "https://api.tokenfactory.nebius.com/v1",
    aiProvider: (process.env.AI_PROVIDER?.trim().toLowerCase() || "") as "" | "nebius" | "claude",
    nemotronFastModel: process.env.NEMOTRON_FAST_MODEL?.trim() || "nvidia/Nemotron-3_5-Lightning", // per-line cues, phrases, detection
    nemotronModel: process.env.NEMOTRON_MODEL?.trim() || "nvidia/nemotron-3-super-120b-a12b", // research summaries, listing parse
    nemotronReasoningModel: process.env.NEMOTRON_REASONING_MODEL?.trim() || "nvidia/Nemotron-3-Ultra-550b-a55b", // agreement drafting
    nemotronVisionModel: process.env.NEMOTRON_VISION_MODEL?.trim() || "nvidia/Nemotron-3.5-Super-VL", // Look identify, condition photos
    tavilyApiKey: secret("TAVILY_API_KEY"),
    supabaseUrl: secret("SUPABASE_URL"),
    supabaseServiceRoleKey: secret("SUPABASE_SERVICE_ROLE_KEY"),
    stripeSecretKey: secret("STRIPE_SECRET_KEY"),
    displayTimeZone: process.env.DISPLAY_TZ ?? "America/Los_Angeles",
    merchantName: process.env.MERCHANT_NAME ?? "DEAL Demo Seller",
  };
}

export type Config = ReturnType<typeof loadConfig>;
