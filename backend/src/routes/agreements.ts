import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Deal } from "../deal.js";
import { parseBody, type IdParams } from "./util.js";

export function agreementRoutes(app: FastifyInstance, deal: Deal) {
  app.post<{ Params: IdParams }>("/sessions/:id/agreement", async (req, reply) => {
    reply.code(201);
    return deal.decorateAgreement(await deal.draftAgreement(req.params.id));
  });

  app.post<{ Params: IdParams }>("/agreements/:id/confirm", async (req) => {
    const { role } = parseBody(z.object({ role: z.enum(["buyer", "seller"]) }), req.body);
    return deal.decorateAgreement(await deal.confirmAgreement(req.params.id, role));
  });
}
