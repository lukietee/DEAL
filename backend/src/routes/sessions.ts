import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { getComparables, listScriptIds } from "../content.js";
import { HttpError, type Deal } from "../deal.js";
import { ListingSchema } from "../listing.js";
import { parseBody, type IdParams } from "./util.js";

const cents = z.number().int().nonnegative();

// Every field is optional. No item (and no listing) = an auto "Start listening" session: auto: true, item "",
// detected: false, category "other", unknown prices null, style "friendly"; the item is detected from the conversation.
const CreateSession = z.object({
  category: z.string().optional(),
  item: z.string().optional(),
  asking_price: cents.nullish(),
  target_price: cents.nullish(),
  max_budget: cents.nullish(),
  style: z.string().optional(),
  listing: ListingSchema.nullish(), // from POST /listings/parse; stored as session.listing
  auto: z.boolean().optional(),
});

export function sessionRoutes(app: FastifyInstance, deal: Deal) {
  app.post("/sessions", async (req, reply) => {
    const body = parseBody(CreateSession, req.body);
    reply.code(201);
    return deal.createSession(body);
  });

  app.post("/sessions/join", async (req) => {
    const { join_code } = parseBody(z.object({ join_code: z.string().min(1) }), req.body);
    return deal.joinSession(join_code);
  });

  app.get("/sessions", async () => deal.listSessions());

  app.get<{ Params: IdParams }>("/sessions/:id", async (req) => deal.getState(req.params.id));

  app.delete("/sessions", async () => {
    await deal.deleteAll();
    return { deleted: true };
  });

  // End of conversation (with or without a payment): ended_at, status "ended" unless paid, summary. Idempotent.
  app.post<{ Params: IdParams }>("/sessions/:id/end", async (req) => deal.endSession(req.params.id));

  app.post<{ Params: IdParams }>("/sessions/:id/research", async (req, reply) => {
    reply.code(202);
    return deal.restartResearch(req.params.id);
  });

  app.get<{ Params: IdParams }>("/sessions/:id/dispute-pack", async (req) => deal.disputePack(req.params.id));

  app.get<{ Params: { category: string } }>("/comparables/:category", async (req) => {
    const c = getComparables(req.params.category);
    if (!c) throw new HttpError(404, `no comparables for category ${req.params.category}`);
    return c;
  });

  app.get("/scripts", async () => ({ scripts: listScriptIds() }));
}
