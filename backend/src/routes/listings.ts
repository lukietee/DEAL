import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Deal } from "../deal.js";
import { parseBody, type IdParams } from "./util.js";

const opt = z.string().trim().min(1).optional();
// ~10 MB of base64 (~7.5 MB image). The Claude API caps a single image at 5 MB, so phones should downscale.
const image = z.string().min(16).max(10_000_000).optional();

const ParseListing = z
  .object({ url: opt, text: z.string().trim().min(1).max(20000).optional(), image_base64: image })
  .refine((b) => b.url || b.text || b.image_base64, { message: "provide at least one of url, text, image_base64" });

const ConditionCheck = z
  .object({ observation: z.string().trim().min(1).max(2000).optional(), image_base64: image })
  .refine((b) => b.observation || b.image_base64, { message: "provide observation and/or image_base64" });

export function listingRoutes(app: FastifyInstance, deal: Deal) {
  app.post("/listings/parse", async (req) => deal.parseListing(parseBody(ParseListing, req.body)));

  app.post<{ Params: IdParams }>("/sessions/:id/condition-check", async (req, reply) => {
    const body = parseBody(ConditionCheck, req.body);
    reply.code(201);
    return deal.conditionCheck(req.params.id, body);
  });
}
