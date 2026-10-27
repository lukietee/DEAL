// Nebius Token Factory client (OpenAI-compatible chat completions) for NVIDIA Nemotron models.
// Plain fetch, no SDK. Thinking is off by default (chat_template_kwargs.enable_thinking=false):
// every Nemotron model on Token Factory then answers in ~1 s instead of reasoning out loud.

export type NemotronContent =
  | string
  | ({ type: "text"; text: string } | { type: "image_url"; image_url: { url: string } })[];

export interface NemotronMessage {
  role: "system" | "user" | "assistant";
  content: NemotronContent;
}

export interface NemotronRequest {
  model: string;
  messages: NemotronMessage[];
  maxTokens?: number;
  temperature?: number;
  /** true = let the model reason first (slower; use for the agreement / strategy calls only). */
  thinking?: boolean;
  /** Ask for a JSON object back (response_format json_object). */
  json?: boolean;
  timeoutMs?: number;
}

export interface NemotronResponse {
  text: string;
  model: string;
  usage: { prompt_tokens: number; completion_tokens: number } | null;
  finishReason: string | null;
}

export class NemotronError extends Error {
  constructor(message: string, readonly status: number | null = null) {
    super(message);
  }
}

export class NemotronClient {
  constructor(private apiKey: string, private baseUrl = "https://api.tokenfactory.nebius.com/v1") {}

  async chat(req: NemotronRequest): Promise<NemotronResponse> {
    const body: Record<string, unknown> = {
      model: req.model,
      messages: req.messages,
      max_tokens: req.maxTokens ?? 1024,
      temperature: req.temperature ?? 0.3,
      chat_template_kwargs: { enable_thinking: req.thinking ?? false },
    };
    if (req.json) body.response_format = { type: "json_object" };
    let res: Response;
    try {
      res = await fetch(`${this.baseUrl}/chat/completions`, {
        method: "POST",
        headers: { authorization: `Bearer ${this.apiKey}`, "content-type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(req.timeoutMs ?? 20_000),
      });
    } catch (err) {
      throw new NemotronError(`Token Factory request failed: ${String(err)}`);
    }
    const raw = await res.text();
    if (!res.ok) throw new NemotronError(`Token Factory ${res.status}: ${raw.slice(0, 300)}`, res.status);
    const data = JSON.parse(raw) as {
      model?: string;
      choices?: { message?: { content?: string | null }; finish_reason?: string | null }[];
      usage?: { prompt_tokens: number; completion_tokens: number };
    };
    const choice = data.choices?.[0];
    return {
      text: (choice?.message?.content ?? "").trim(),
      model: data.model ?? req.model,
      usage: data.usage ?? null,
      finishReason: choice?.finish_reason ?? null,
    };
  }
}

/** JPEG/PNG base64 (no data: prefix) → an OpenAI-style image part. */
export function imagePart(base64: string, mediaType = "image/jpeg") {
  return { type: "image_url" as const, image_url: { url: `data:${mediaType};base64,${base64}` } };
}
