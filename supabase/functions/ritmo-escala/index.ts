// Ritmo — lê a foto de uma escala de plantão e devolve os dias e siglas (Gemini).
// Projeto enamed-engine. Verify JWT desligado (o usuário é validado aqui dentro).
// Secret obrigatório: RITMO_GEMINI_KEY (chave da API do Gemini). Opcional: RITMO_GEMINI_MODEL.
// Limites: só contas ativas, 8 leituras por dia por conta, imagem de até ~3 MB.

const env = (k: string, d = "") => (globalThis as any).Deno?.env.get(k) ?? (globalThis as any).process?.env?.[k] ?? d;
const SB = () => env("SUPABASE_URL");
const SRK = () => {
  const legacy = env("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  try { const m = JSON.parse(env("SUPABASE_SECRET_KEYS", "{}")); return m.default || Object.values(m)[0] || ""; } catch { return ""; }
};
const srv = (): Record<string, string> =>
  SRK().startsWith("sb_secret_") ? { apikey: SRK() } : { apikey: SRK(), Authorization: "Bearer " + SRK() };
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const LIMITE = 8;

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: true, servico: "ritmo-escala" });
  try {
    const auth = req.headers.get("authorization") || "";
    const ur = await fetch(SB() + "/auth/v1/user", { headers: { apikey: SRK(), Authorization: auth } });
    const u = ur.ok ? await ur.json() : null;
    if (!u?.id) return json({ erro: "Faça login de novo." }, 401);
    // conta ativa? (pergunta ao banco com o token do próprio usuário)
    const ar = await fetch(SB() + "/rest/v1/rpc/ritmo_eu_ativo", { method: "POST", headers: { apikey: SRK(), Authorization: auth, "Content-Type": "application/json" }, body: "{}" });
    if (!ar.ok || (await ar.json()) !== true) return json({ erro: "Recurso disponível para contas ativas." }, 403);
    const key = env("RITMO_GEMINI_KEY");
    if (!key) return json({ erro: "Leitura por foto ainda não configurada." }, 503);

    const b = await req.json().catch(() => ({}));
    const img = String(b.imagem || ""), mime = /^image\/(jpeg|png|webp)$/.test(b.mime) ? b.mime : "image/jpeg";
    if (img.length < 1000 || img.length > 4_200_000) return json({ erro: "Imagem inválida ou grande demais." }, 400);
    const nome = String(b.nome || "").slice(0, 80), siglas = (Array.isArray(b.siglas) ? b.siglas : []).slice(0, 20).map((s: unknown) => String(s).slice(0, 8));
    const mes = Number(b.mes) || 0, ano = Number(b.ano) || 0;

    const cr = await fetch(SB() + "/rest/v1/rpc/ritmo_ia_contar", { method: "POST", headers: { ...srv(), "Content-Type": "application/json" }, body: JSON.stringify({ p_user: u.id }) });
    const usos = cr.ok ? Number(await cr.json()) : 1;
    if (usos > LIMITE) return json({ erro: `Limite de ${LIMITE} leituras por dia atingido. Tente amanhã.` }, 429);

    const prompt = `Você lê a foto de uma escala de plantão de um hospital brasileiro (tabela com profissionais nas linhas e dias do mês nas colunas, ou um calendário).
${nome ? `Extraia SOMENTE a linha do profissional cujo nome mais se parece com "${nome}". Se não encontrar esse nome, devolva "dias": [] e "achou": false.` : "A escala é de uma pessoa só: extraia todos os plantões."}
${mes && ano ? `Se a imagem não disser o mês, considere ${mes}/${ano}.` : ""}
Siglas que essa pessoa costuma usar: ${siglas.join(", ") || "SD, SN, M, T, P24"}. Copie a sigla exatamente como está escrita na célula (ex.: SD, SN, D, N, M, T, MT, P, 12, 24). Ignore células vazias, traços, folgas (F, FO, DSR, "-"), férias e licenças.
Responda APENAS com JSON neste formato: {"achou": true, "nome_lido": "texto do nome na imagem", "mes": 11, "ano": 2026, "dias": [{"dia": 3, "sigla": "SD"}]}`;
    const model = env("RITMO_GEMINI_MODEL", "gemini-3.5-flash-lite");
    const gr = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
      method: "POST", headers: { "Content-Type": "application/json", "x-goog-api-key": key },
      body: JSON.stringify({ contents: [{ role: "user", parts: [{ text: prompt }, { inline_data: { mime_type: mime, data: img } }] }], generationConfig: { responseMimeType: "application/json" } }),
    });
    const gj = await gr.json().catch(() => ({}));
    if (!gr.ok) { console.error("gemini", gr.status, JSON.stringify(gj).slice(0, 300)); return json({ erro: gr.status === 429 ? "Serviço de leitura ocupado. Tente em alguns minutos." : "Não foi possível ler a imagem agora." }, 502); }
    const txt = (gj.candidates?.[0]?.content?.parts || []).map((p: any) => p.text || "").join("").replace(/^```(?:json)?/i, "").replace(/```\s*$/, "").trim();
    let out: any; try { out = JSON.parse(txt); } catch { return json({ erro: "Não consegui entender a escala nessa foto. Tente uma foto mais nítida e reta." }, 422); }
    const dias = (Array.isArray(out.dias) ? out.dias : [])
      .map((d: any) => ({ dia: Math.trunc(Number(d.dia)), sigla: String(d.sigla || "").trim().toUpperCase().slice(0, 8) }))
      .filter((d: any) => d.dia >= 1 && d.dia <= 31 && d.sigla && !/^(F|FO|FOLGA|DSR|-+)$/.test(d.sigla));
    const m = Math.trunc(Number(out.mes)) || mes, a = Math.trunc(Number(out.ano)) || ano;
    return json({ ok: true, achou: out.achou !== false && dias.length > 0, nome_lido: String(out.nome_lido || "").slice(0, 80), mes: m >= 1 && m <= 12 ? m : mes, ano: a >= 2020 && a <= 2100 ? a : ano, dias, restantes: Math.max(0, LIMITE - usos) });
  } catch (e) { console.error(e); return json({ erro: "Falha interna." }, 500); }
}
(globalThis as any).Deno?.serve(handler);
