import type { z } from "zod";
import { HttpError } from "../deal.js";

export function parseBody<S extends z.ZodTypeAny>(schema: S, body: unknown): z.infer<S> {
  const r = schema.safeParse(body ?? {});
  if (!r.success) {
    throw new HttpError(400, "invalid request body", r.error.issues.map((i) => ({ path: i.path.join("."), message: i.message })));
  }
  return r.data;
}

export type IdParams = { id: string };
