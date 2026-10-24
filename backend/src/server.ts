import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";

const cfg = loadConfig();
const { app } = await buildApp(cfg);

try {
  await app.listen({ port: cfg.port, host: cfg.host });
  app.log.info(
    `DEAL backend on http://${cfg.host}:${cfg.port} (mock_mode=${cfg.mockMode}, store=${cfg.supabaseUrl ? "supabase" : "memory"}, payments=${cfg.stripeSecretKey ? "stripe" : "mock"})`,
  );
} catch (err) {
  app.log.error(err);
  process.exit(1);
}

for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, async () => {
    await app.close();
    process.exit(0);
  });
}
