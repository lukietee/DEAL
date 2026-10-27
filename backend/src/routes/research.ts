import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Deal } from "../deal.js";
import { parseBody } from "./util.js";

// Contract for the iOS B2 "market check" screen: keep field names.
const ResearchPreview = z.object({
  item: z.string().trim().min(1).max(500),
  category: z.string().trim().min(1).max(64).optional(),
  asking_price: z.number().int().nonnegative().optional(), // cents
});

export function researchRoutes(app: FastifyInstance, deal: Deal) {
  // Blocking: real mode takes ~3-4 s on Tavily + Nemotron (~15-25 s on the Claude fallback) plus og:images; mock mode ~1.5 s.
  // Returns {summary, price_low, price_high, sources: [{title, url, price, note, image_url}]}.
  app.post("/research/preview", async (req) => deal.researchPreview(parseBody(ResearchPreview, req.body)));
}
