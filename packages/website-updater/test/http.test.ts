import assert from 'node:assert/strict';
import { test } from 'node:test';
import { request } from '../src/http.ts';

const url = 'https://api.github.com/repos/example/site/releases/latest';
const networkError = (code: string) => new TypeError('fetch failed', { cause: Object.assign(new Error(code), { code }) });

function clock() {
  let elapsed = 0;
  const delays: number[] = [];
  return { delays, now: () => elapsed, sleep: async (ms: number) => { delays.push(ms); elapsed += ms; }, warn: () => {} };
}

for (const code of ['ENOTFOUND', 'EAI_AGAIN', 'ECONNRESET', 'UND_ERR_CONNECT_TIMEOUT']) {
  test(`recovers from ${code} before returning complete bytes`, async () => {
    const timing = clock(); let calls = 0;
    const result = await request(url, 10, { ...timing, fetch: async () => {
      if (++calls <= 2) throw networkError(code);
      return new Response('complete');
    }});
    assert.equal(result.toString(), 'complete');
    assert.deepEqual(timing.delays, [15_000, 15_000]);
  });
}

test('persistent DNS failure exhausts a bounded budget and preserves the cause', async () => {
  const timing = clock(); let calls = 0;
  await assert.rejects(request(url, 10, { ...timing, fetch: async () => { calls++; throw networkError('ENOTFOUND'); } }), error => {
    assert(error instanceof Error); assert.match(error.message, /retry budget/);
    assert(error.cause instanceof TypeError); return true;
  });
  assert.equal(calls, 12);
  assert.equal(timing.now(), 165_000);
});

test('request and response-body timeouts recover', async () => {
  for (const name of ['TimeoutError', 'AbortError']) {
    const timing = clock(); let calls = 0;
    const result = await request(url, 10, { ...timing, fetch: async () => {
      if (++calls === 1) throw new DOMException('Timed out', name);
      return new Response('ok');
    }});
    assert.equal(result.toString(), 'ok'); assert.equal(calls, 2);
  }
});

test('time spent downloading also consumes the retry budget', async () => {
  const timing = clock(); let calls = 0;
  await assert.rejects(request(url, 10, { ...timing, fetch: async () => {
    calls++; await timing.sleep(60_000); throw networkError('UND_ERR_BODY_TIMEOUT');
  }}), /retry budget/);
  assert.equal(calls, 3);
  assert.equal(timing.delays.filter(delay => delay === 15_000).length, 2);
});

test('Retry-After delays are honored but never extend the budget', async () => {
  for (const seconds of [45, 600]) {
    const timing = clock(); let calls = 0;
    const result = request(url, 10, { ...timing, fetch: async () => ++calls === 1
      ? new Response('', { status: 429, headers: { 'Retry-After': String(seconds) } })
      : new Response('ok') });
    if (seconds === 45) { assert.equal((await result).toString(), 'ok'); assert.deepEqual(timing.delays, [45_000]); }
    else { await assert.rejects(result, /retry budget/); assert.equal(calls, 1); assert.deepEqual(timing.delays, []); }
  }
});

test('temporary HTTP errors recover and response bodies are released', async () => {
  const timing = clock(); let calls = 0, canceled = false;
  const result = await request(url, 10, { ...timing, fetch: async () => ++calls === 1
    ? new Response(new ReadableStream({ cancel() { canceled = true; } }), { status: 503 })
    : new Response('ok') });
  assert.equal(result.toString(), 'ok'); assert(canceled); assert.equal(calls, 2);
});

test('permanent HTTP and certificate failures are not retried', async () => {
  for (const failure of [401, 403, 404, networkError('CERT_HAS_EXPIRED')]) {
    const timing = clock(); let calls = 0;
    await assert.rejects(request(url, 10, { ...timing, fetch: async () => {
      calls++; if (failure instanceof Error) throw failure;
      return new Response('', { status: failure });
    }}));
    assert.equal(calls, 1); assert.deepEqual(timing.delays, []);
  }
});

test('interrupted body is discarded and redirects are refreshed from the original URL', async () => {
  const timing = clock(); const visited: string[] = []; let redirects = 0;
  const result = await request(url, 10, { ...timing, fetch: async target => {
    visited.push(String(target));
    if (String(target) === url) return new Response('', { status: 302, headers: { location: `https://release-assets.githubusercontent.com/file?signature=${++redirects}` } });
    if (redirects === 1) {
      let reads = 0;
      return new Response(new ReadableStream({ pull(controller) {
        if (++reads === 1) controller.enqueue(new TextEncoder().encode('partial'));
        else controller.error(networkError('ECONNRESET'));
      }}));
    }
    return new Response('complete');
  }});
  assert.equal(result.toString(), 'complete');
  assert.deepEqual(visited, [url, 'https://release-assets.githubusercontent.com/file?signature=1', url, 'https://release-assets.githubusercontent.com/file?signature=2']);
});

test('untrusted redirects and oversized responses fail without retrying', async () => {
  for (const response of [
    new Response('', { status: 302, headers: { location: 'https://untrusted.example/file' } }),
    new Response('too large'),
    new Response('x', { headers: { 'content-length': '100' } }),
  ]) {
    const timing = clock(); let calls = 0;
    await assert.rejects(request(url, 2, { ...timing, fetch: async () => { calls++; return response; } }), /Unexpected GitHub download host|size limit/);
    assert.equal(calls, 1); assert.deepEqual(timing.delays, []);
  }
});
