// Ritmo — avisos com o app fechado (Web Push sem conteúdo: o texto do lembrete fica no aparelho).
// Projeto enamed-engine. Verify JWT desligado. Não precisa de nenhum Secret: as chaves VAPID são criadas
// na primeira chamada e guardadas em public.ritmo_config (acesso só do servidor).
//   GET  /chave   → chave pública para o app se inscrever
//   POST /enviar  → chamado pelo agendador do banco (cabeçalho x-ritmo-cron)

const env = (k: string, d = "") => (globalThis as any).Deno?.env.get(k) ?? (globalThis as any).process?.env?.[k] ?? d;
const SB = () => env("SUPABASE_URL");
const SRK = () => {
  const legacy = env("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  try { const m = JSON.parse(env("SUPABASE_SECRET_KEYS", "{}")); return m.default || Object.values(m)[0] || ""; } catch { return ""; }
};
const srv = (): Record<string, string> =>
  SRK().startsWith("sb_secret_") ? { apikey: SRK() } : { apikey: SRK(), Authorization: "Bearer " + SRK() };
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function db(path: string, init: RequestInit = {}) {
  const r = await fetch(SB() + "/rest/v1/" + path, { ...init, headers: { ...srv(), "Content-Type": "application/json", ...(init.headers || {}) } });
  const t = await r.text();
  if (!r.ok) throw new Error("db " + r.status + " " + t);
  return t ? JSON.parse(t) : null;
}
const b64u = (buf: ArrayBuffer | Uint8Array) => {
  const u = buf instanceof Uint8Array ? buf : new Uint8Array(buf); let s = "";
  for (const c of u) s += String.fromCharCode(c);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const cfg = async (chave: string) => ((await db("ritmo_config?select=valor&chave=eq." + chave)) || [])[0]?.valor as string | undefined;

async function vapid() {
  let pub = await cfg("vapid_pub"), jwk = await cfg("vapid_jwk");
  if (!pub || !jwk) {
    const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
    const novoPub = b64u(await crypto.subtle.exportKey("raw", kp.publicKey));
    const novoJwk = JSON.stringify(await crypto.subtle.exportKey("jwk", kp.privateKey));
    // grava só se ainda não existir (duas chamadas simultâneas não geram duas chaves)
    await db("ritmo_config?on_conflict=chave", { method: "POST", headers: { Prefer: "resolution=ignore-duplicates" }, body: JSON.stringify([{ chave: "vapid_jwk", valor: novoJwk + "|" + novoPub }]) });
    const par = (await cfg("vapid_jwk"))!;
    if (par.includes("|")) { jwk = par.split("|")[0]; pub = par.split("|")[1]; }
    await db("ritmo_config?on_conflict=chave", { method: "POST", headers: { Prefer: "resolution=ignore-duplicates" }, body: JSON.stringify([{ chave: "vapid_pub", valor: pub }]) });
  }
  if (jwk!.includes("|")) jwk = jwk!.split("|")[0];
  return { pub: pub!, jwk: JSON.parse(jwk!) };
}

async function assinar(aud: string, v: { pub: string; jwk: JsonWebKey }) {
  const enc = (o: unknown) => b64u(new TextEncoder().encode(JSON.stringify(o)));
  const dados = enc({ typ: "JWT", alg: "ES256" }) + "." + enc({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: "mailto:" + env("RITMO_CONTATO", "janan.almeida@gmail.com") });
  const key = await crypto.subtle.importKey("jwk", v.jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(dados));
  return dados + "." + b64u(sig);
}

async function enviar(req: Request) {
  const segredo = await cfg("cron");
  if (!segredo || req.headers.get("x-ritmo-cron") !== segredo) return json({ erro: "não autorizado" }, 401);
  const endpoints: string[] = (await db("rpc/ritmo_avisos_pegar", { method: "POST", body: "{}" })) || [];
  if (!endpoints.length) return json({ ok: true, enviados: 0 });
  const v = await vapid(), tokens: Record<string, string> = {};
  let ok = 0, mortos = 0;
  await Promise.all(endpoints.map(async (ep) => {
    try {
      const aud = new URL(ep).origin;
      tokens[aud] = tokens[aud] || await assinar(aud, v);
      const r = await fetch(ep, { method: "POST", headers: { Authorization: `vapid t=${tokens[aud]}, k=${v.pub}`, TTL: "3600", Urgency: "high", "Content-Length": "0" } });
      if (r.status === 404 || r.status === 410) { mortos++; await db("ritmo_push_subs?endpoint=eq." + encodeURIComponent(ep), { method: "DELETE" }); }
      else if (r.ok) ok++;
      else console.error("push", r.status, await r.text().catch(() => ""));
    } catch (e) { console.error(e); }
  }));
  return json({ ok: true, enviados: ok, removidos: mortos });
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const path = new URL(req.url).pathname;
  try {
    if (path.endsWith("/chave")) return json({ chave: (await vapid()).pub });
    if (path.endsWith("/enviar") && req.method === "POST") return await enviar(req);
    return json({ ok: true, servico: "ritmo-push" });
  } catch (e) { console.error(e); return json({ erro: "Falha interna." }, 500); }
}
(globalThis as any).Deno?.serve(handler);
