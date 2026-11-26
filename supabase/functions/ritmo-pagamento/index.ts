// Ritmo — pagamentos (Mercado Pago Checkout Pro: Pix ou cartão)
// Projeto: enamed-engine (ConsultaIA). Função "ritmo-pagamento", com Verify JWT desligado.
// IMPORTANTE: desligar "Verify JWT" (o webhook do Mercado Pago não manda JWT; o checkout valida o usuário aqui dentro).
// Secrets (Edge Functions > Secrets): RITMO_MP_ACCESS_TOKEN (obrigatório), APP_URL (opcional).
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem automaticamente.

const env = (k: string, d = "") => (globalThis as any).Deno?.env.get(k) ?? (globalThis as any).process?.env?.[k] ?? d;
const SB = () => env("SUPABASE_URL");
// Chave de servidor: aceita a legada (service_role) ou a nova (sb_secret_...).
const SRK = () => {
  const legacy = env("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  try { const m = JSON.parse(env("SUPABASE_SECRET_KEYS", "{}")); return m.default || Object.values(m)[0] || ""; } catch { return ""; }
};
const srvHeaders = (): Record<string, string> =>
  SRK().startsWith("sb_secret_") ? { apikey: SRK() } : { apikey: SRK(), Authorization: "Bearer " + SRK() };
const MP = () => env("RITMO_MP_ACCESS_TOKEN") || env("MP_ACCESS_TOKEN");
const APP = () => env("APP_URL", "https://consultaia.github.io/consultaia-ritmo/");
const FN = () => SB() + "/functions/v1/ritmo-pagamento";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function db(path: string, init: RequestInit = {}) {
  const alvo = path.startsWith("rpc/") ? "rpc/ritmo_" + path.slice(4) : "ritmo_" + path;
  const r = await fetch(SB() + "/rest/v1/" + alvo, {
    ...init,
    headers: {
      ...srvHeaders(), "Content-Type": "application/json",
      Prefer: "return=representation",
      ...(init.headers || {}),
    },
  });
  const t = await r.text();
  if (!r.ok) throw new Error("db " + r.status + " " + t);
  return t ? JSON.parse(t) : null;
}

async function usuario(req: Request) {
  const auth = req.headers.get("authorization") || "";
  if (!auth.startsWith("Bearer ")) return null;
  const r = await fetch(SB() + "/auth/v1/user", { headers: { apikey: SRK(), Authorization: auth } });
  if (!r.ok) return null;
  const u = await r.json();
  return u && u.id ? u : null;
}

async function checkout(req: Request) {
  const u = await usuario(req);
  if (!u) return json({ erro: "Faça login de novo." }, 401);
  if (!MP()) return json({ erro: "Pagamento ainda não configurado. Tente mais tarde." }, 500);
  const body = await req.json().catch(() => ({}));
  const planos = await db("planos?select=*&ativo=eq.true&id=eq." + encodeURIComponent(String(body.plano || "")));
  const pl = planos && planos[0];
  if (!pl) return json({ erro: "Plano inválido." }, 400);

  const [pg] = await db("pagamentos", {
    method: "POST",
    body: JSON.stringify({ user_id: u.id, plano: pl.id, valor: pl.valor, dias: pl.dias }),
  });
  const pref = await fetch("https://api.mercadopago.com/checkout/preferences", {
    method: "POST",
    headers: { Authorization: "Bearer " + MP(), "Content-Type": "application/json", "X-Idempotency-Key": pg.id },
    body: JSON.stringify({
      items: [{ id: pl.id, title: "Ritmo — plano " + pl.nome, quantity: 1, unit_price: Number(pl.valor), currency_id: "BRL" }],
      payer: { email: u.email },
      external_reference: pg.id,
      notification_url: FN() + "/webhook",
      back_urls: { success: APP() + "?pg=ok", pending: APP() + "?pg=pendente", failure: APP() + "?pg=erro" },
      auto_return: "approved",
      statement_descriptor: "RITMO",
      payment_methods: { installments: 1, excluded_payment_types: [{ id: "ticket" }] },
      expires: true,
      expiration_date_to: new Date(Date.now() + 2 * 86400000).toISOString(),
    }),
  });
  const pj = await pref.json().catch(() => ({}));
  if (!pref.ok || !pj.init_point) return json({ erro: "Mercado Pago recusou: " + (pj.message || pref.status) }, 502);
  await db("pagamentos?id=eq." + pg.id, { method: "PATCH", body: JSON.stringify({ mp_preference: pj.id }) });
  return json({ url: pj.init_point, ref: pg.id });
}

async function webhook(req: Request) {
  const url = new URL(req.url);
  const body = await req.json().catch(() => ({}));
  const tipo = body.type || body.topic || url.searchParams.get("type") || url.searchParams.get("topic");
  const id = (body.data && body.data.id) || url.searchParams.get("data.id") || url.searchParams.get("id");
  if (tipo !== "payment" || !id) return json({ ok: true, ignorado: true });

  // Nunca confia no corpo do aviso: consulta o pagamento direto no Mercado Pago.
  const r = await fetch("https://api.mercadopago.com/v1/payments/" + encodeURIComponent(String(id)), {
    headers: { Authorization: "Bearer " + MP() },
  });
  if (!r.ok) return json({ ok: false, erro: "mp " + r.status }, r.status === 404 ? 200 : 500);
  const p = await r.json();
  const ref = p.external_reference;
  if (!ref || !/^[0-9a-f-]{36}$/i.test(ref)) return json({ ok: true, ignorado: "sem referência" });

  const [pg] = (await db("pagamentos?select=*&id=eq." + ref)) || [];
  if (!pg) return json({ ok: true, ignorado: "referência desconhecida" });

  if (p.status === "approved") {
    if (Number(p.transaction_amount) + 0.001 < Number(pg.valor)) return json({ ok: false, erro: "valor menor que o plano" });
    const res = await db("rpc/creditar_pagamento", {
      method: "POST",
      body: JSON.stringify({ p_ref: ref, p_mp_id: String(p.id), p_metodo: p.payment_type_id || p.payment_method_id || null }),
    });
    return json({ ok: true, ...res });
  }
  // Estorno ou chargeback de um pagamento já creditado: tira os dias liberados.
  if (["refunded", "charged_back"].includes(p.status) && pg.status === "aprovado") {
    const res = await db("rpc/estornar_pagamento", { method: "POST", body: JSON.stringify({ p_ref: ref }) });
    return json({ ok: true, ...res });
  }
  if (["rejected", "cancelled", "refunded", "charged_back"].includes(p.status) && pg.status === "pendente") {
    await db("pagamentos?id=eq." + ref + "&status=eq.pendente", { method: "PATCH", body: JSON.stringify({ status: "recusado", mp_payment_id: String(p.id) }) });
  }
  return json({ ok: true, status: p.status });
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const path = new URL(req.url).pathname;
  try {
    if (path.endsWith("/webhook")) return await webhook(req);
    if (path.endsWith("/checkout") && req.method === "POST") return await checkout(req);
    return json({ ok: true, servico: "ritmo-pagamento" });
  } catch (e) {
    console.error(e);
    return json({ erro: "Falha interna." }, 500); // 500 faz o Mercado Pago reenviar o aviso
  }
}

(globalThis as any).Deno?.serve(handler);
