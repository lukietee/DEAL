import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { getComparables, listScriptIds, normalizeCategory } from "../content.js";
import { HttpError, type Deal } from "../deal.js";
import { parseBody, type IdParams } from "./util.js";

const cents = z.number().int().nonnegative();

const CreateSession = z.object({
  category: z.string().min(1).transform(normalizeCategory),
  item: z.string().min(1),
  asking_price: cents,
  target_price: cents,
  max_budget: cents,
  style: z.string().min(1).default("firm").transform((s) => s.toLowerCase()),
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

  app.get<{ Params: IdParams }>("/sessions/:id/dispute-pack", async (req) => deal.disputePack(req.params.id));

  app.get<{ Params: { category: string } }>("/comparables/:category", async (req) => {
    const c = getComparables(req.params.category);
    if (!c) throw new HttpError(404, `no comparables for category ${req.params.category}`);
    return c;
  });

  app.get("/scripts", async () => ({ scripts: listScriptIds() }));
}
