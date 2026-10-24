import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Deal } from "../deal.js";
import { parseBody, type IdParams } from "./util.js";

const CreatePaymentRequest = z.object({
  line_items: z.array(z.object({ label: z.string().trim().min(1), amount: z.number().int().nonnegative() })).min(1).max(50),
});

export function paymentRoutes(app: FastifyInstance, deal: Deal) {
  app.post<{ Params: IdParams }>("/sessions/:id/payment-requests", async (req, reply) => {
    const { line_items } = parseBody(CreatePaymentRequest, req.body);
    reply.code(201);
    return deal.createPaymentRequest(req.params.id, line_items);
  });

  app.post<{ Params: IdParams }>("/payment-requests/:id/decision", async (req) => {
    const { decision } = parseBody(z.object({ decision: z.enum(["approve", "reject"]) }), req.body);
    return deal.decide(req.params.id, decision);
  });

  app.post<{ Params: IdParams }>("/payment-requests/:id/pay", async (req, reply) => {
    reply.code(201);
    return deal.pay(req.params.id);
  });
}
