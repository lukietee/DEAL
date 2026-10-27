import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Deal } from "../deal.js";
import { parseBody } from "./util.js";

// Contract: ios/DEAL/Look/LookContracts.swift (LookIdentification, LookPrice). Keep field names.
// Same image cap as /listings/parse; the app-wide bodyLimit (12 MB) covers it.
const Identify = z.object({
  image_base64: z.string().min(16).max(10_000_000), // JPEG crop, <= 768 px
  hint: z.string().trim().min(1).max(300).optional(),
});

const Price = z.object({
  name: z.string().trim().min(1).max(300),
  category: z.string().trim().min(1).max(64).optional(),
});

export function lookRoutes(app: FastifyInstance, deal: Deal) {
  // {is_product, name, category, confidence}. Real mode: one NEMOTRON_VISION_MODEL call (or CUE_MODEL) (~1-2 s); 502 {error} on failure.
  app.post("/look/identify", async (req) => deal.lookIdentify(parseBody(Identify, req.body)));
  // {name, price_low, price_high, summary, source_count} (cents). Real mode: one Tavily search + NEMOTRON_FAST_MODEL (~1-3 s;
  // Claude fallback: CUE_MODEL + <= 2 web searches, ~4-5 s), cached 30 min per name.
  app.post("/look/price", async (req) => deal.lookPrice(parseBody(Price, req.body)));
}
