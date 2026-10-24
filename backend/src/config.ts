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
    supabaseUrl: secret("SUPABASE_URL"),
    supabaseServiceRoleKey: secret("SUPABASE_SERVICE_ROLE_KEY"),
    stripeSecretKey: secret("STRIPE_SECRET_KEY"),
    displayTimeZone: process.env.DISPLAY_TZ ?? "America/Los_Angeles",
    merchantName: process.env.MERCHANT_NAME ?? "DEAL Demo Seller",
  };
}

export type Config = ReturnType<typeof loadConfig>;
