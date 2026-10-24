import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Deal } from "../deal.js";
import { parseBody, type IdParams } from "./util.js";

const AddEvent = z.object({ speaker: z.enum(["buyer", "seller"]), text: z.string().min(1).max(2000) });
const PlayScript = z.object({ script_id: z.string().min(1), interval_ms: z.number().int().min(0).max(60000).optional() });
const PatchTerm = z.object({
  term_id: z.string().min(1),
  correction: z.object({
    label: z.string().min(1).optional(),
    amount: z.number().int().nonnegative().nullable().optional(),
    type: z.string().min(1).optional(),
    removed: z.boolean().optional(),
  }),
});

export function eventRoutes(app: FastifyInstance, deal: Deal) {
  app.post<{ Params: IdParams }>("/sessions/:id/events", async (req, reply) => {
    const { speaker, text } = parseBody(AddEvent, req.body);
    reply.code(201);
    return deal.addEvent(req.params.id, speaker, text);
  });

  app.post<{ Params: IdParams }>("/sessions/:id/script/play", async (req) => {
    const { script_id, interval_ms } = parseBody(PlayScript, req.body);
    const run = await deal.playScript(req.params.id, script_id, interval_ms);
    return { started: true, script_id: run.script_id, line_count: run.total };
  });

  app.patch<{ Params: IdParams }>("/sessions/:id/terms", async (req) => {
    const { term_id, correction } = parseBody(PatchTerm, req.body);
    return { terms: await deal.correctTerm(req.params.id, term_id, correction) };
  });
}
