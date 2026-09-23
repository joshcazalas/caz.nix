import { setTimeout as sleep } from 'node:timers/promises';
import { requireValue } from './format.ts';

const budgetMs = 180_000;
const retryDelayMs = 15_000;
const transientStatuses = new Set([408, 429, 500, 502, 503, 504, 522, 524]);
const transientCodes = new Set([
  'ENOTFOUND', 'EAI_AGAIN', 'ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT',
  'EHOSTUNREACH', 'ENETUNREACH', 'EPIPE', 'UND_ERR_CONNECT_TIMEOUT',
  'UND_ERR_HEADERS_TIMEOUT', 'UND_ERR_BODY_TIMEOUT', 'UND_ERR_SOCKET',
  'UND_ERR_RES_CONTENT_LENGTH_MISMATCH',
]);

class TransientHttpError extends Error {
  delayMs: number;
  constructor(status: number, retryAfter: string | null) {
    super(`GitHub download failed: HTTP ${status}`);
    const seconds = retryAfter && /^\d+$/.test(retryAfter) ? Number(retryAfter) : NaN;
    const delay = Number.isNaN(seconds) ? Date.parse(retryAfter ?? '') - Date.now() : seconds * 1000;
    this.delayMs = Number.isNaN(delay) ? retryDelayMs : Math.max(retryDelayMs, delay);
  }
}

function transient(error: unknown): boolean {
  if (error instanceof TransientHttpError) return true;
  if (!(error instanceof Error)) return false;
  // Fetch can report an aborted body as AbortError even when our own timeout
  // signal caused it. This downloader has no caller-supplied cancellation.
  if (error.name === 'TimeoutError' || error.name === 'AbortError') return true;
  if ('code' in error && transientCodes.has(String(error.code))) return true;
  if (error instanceof AggregateError) return error.errors.length > 0 && error.errors.every(transient);
  return error.cause !== undefined && transient(error.cause);
}

type Dependencies = {
  fetch: typeof fetch;
  sleep: (ms: number) => Promise<unknown>;
  now: () => number;
  warn: (message: string) => void;
};

async function attempt(url: string, max: number, signal: AbortSignal, fetcher: typeof fetch): Promise<Buffer> {
  let target = new URL(url);
  for (let redirects = 0; redirects <= 5; redirects++) {
    requireValue(target.protocol === 'https:' && ['api.github.com', 'github.com', 'objects.githubusercontent.com', 'release-assets.githubusercontent.com'].includes(target.hostname), 'Unexpected GitHub download host');
    const response = await fetcher(target, { redirect: 'manual', signal, headers: { 'User-Agent': 'caz-website-updater', Accept: 'application/vnd.github+json' } });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location');
      await response.body?.cancel();
      requireValue(location, 'Missing download redirect'); target = new URL(location, target); continue;
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      if (transientStatuses.has(response.status)) throw new TransientHttpError(response.status, response.headers.get('retry-after'));
      throw new Error(`GitHub download failed: HTTP ${response.status}`);
    }
    const size = response.headers.get('content-length');
    if (size && Number(size) > max) {
      await response.body?.cancel().catch(() => {});
      throw new Error('Download exceeds size limit');
    }
    requireValue(response.body, 'Empty download response');
    const chunks: Uint8Array[] = []; let count = 0;
    for await (const chunk of response.body) {
      count += chunk.length;
      requireValue(count <= max, 'Download exceeds size limit'); chunks.push(chunk);
    }
    return Buffer.concat(chunks);
  }
  throw new Error('Too many download redirects');
}

// Retry only the idempotent download, always from its original URL. Partial
// bytes are discarded and signed redirect URLs are refreshed on each attempt.
// Manifest, checksum, and signature validation remain outside this loop.
export async function request(url: string, max: number, overrides: Partial<Dependencies> = {}): Promise<Buffer> {
  const deps: Dependencies = { fetch, sleep, now: () => performance.now(), warn: message => console.error(message), ...overrides };
  const deadline = deps.now() + budgetMs;
  let lastError: unknown;
  while (deps.now() < deadline) {
    try {
      const timeout = Math.max(1, Math.ceil(Math.min(60_000, deadline - deps.now())));
      return await attempt(url, max, AbortSignal.timeout(timeout), deps.fetch);
    } catch (error) {
      if (!transient(error)) throw error;
      lastError = error;
      const delay = error instanceof TransientHttpError ? error.delayMs : retryDelayMs;
      if (deps.now() + delay >= deadline) break;
      // Do not log signed redirect URLs or response bodies.
      deps.warn(`Transient GitHub download failure; retrying in ${delay / 1000}s (${new URL(url).hostname}).`);
      await deps.sleep(delay);
    }
  }
  throw new Error('GitHub download exhausted its 180-second retry budget', { cause: lastError });
}
