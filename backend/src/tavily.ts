// Tavily web search (https://docs.tavily.com). Used by the research agents and the Look price
// lookup in place of Claude's server-side web search. Plain fetch, no SDK.

export interface TavilyResult {
  title: string;
  url: string;
  content: string; // extracted snippet
  score: number;
}

export interface TavilySearch {
  query: string;
  maxResults?: number;
  /** "basic" (1 credit) or "advanced" (2 credits, better snippets). */
  depth?: "basic" | "advanced";
  includeImages?: boolean;
  includeDomains?: string[];
  timeoutMs?: number;
}

export interface TavilyResponse {
  query: string;
  results: TavilyResult[];
  images: string[];
  responseTime: number | null;
}

export class TavilyClient {
  constructor(private apiKey: string, private baseUrl = "https://api.tavily.com") {}

  async search(s: TavilySearch): Promise<TavilyResponse> {
    const res = await fetch(`${this.baseUrl}/search`, {
      method: "POST",
      headers: { authorization: `Bearer ${this.apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({
        query: s.query,
        max_results: s.maxResults ?? 5,
        search_depth: s.depth ?? "basic",
        include_images: s.includeImages ?? false,
        ...(s.includeDomains?.length ? { include_domains: s.includeDomains } : {}),
      }),
      signal: AbortSignal.timeout(s.timeoutMs ?? 10_000),
    });
    const raw = await res.text();
    if (!res.ok) throw new Error(`Tavily ${res.status}: ${raw.slice(0, 300)}`);
    const data = JSON.parse(raw) as { query?: string; results?: TavilyResult[]; images?: (string | { url: string })[]; response_time?: number };
    return {
      query: data.query ?? s.query,
      results: data.results ?? [],
      images: (data.images ?? []).map((i) => (typeof i === "string" ? i : i.url)),
      responseTime: data.response_time ?? null,
    };
  }
}
