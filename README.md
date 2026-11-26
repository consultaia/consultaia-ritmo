# Ritmo — rotina inteligente

PWA (um `index.html`, sem build) que organiza tarefas, hábitos, metas, lembretes e gastos em volta da rotina de cada pessoa: **escala/plantão**, **horário fixo** ou **rotina flexível**.

- Captura por voz ou texto ("consulta sexta às 14h", "gastei 45 no mercado")
- ⚡ Distribuir: encaixa tarefas e atividades no tempo livre da semana
- Grade semanal, resumo do dia (com envio no WhatsApp), painel de gestão do tempo
- Funciona offline; com login, sincroniza entre aparelhos (Supabase)

## Estrutura
| Arquivo | Para quê |
|---|---|
| `index.html` | App inteiro (HTML + CSS + JS puro) |
| `sw.js`, `manifest.json`, `icon-*.png` | Instalação no celular e uso offline |
| `supabase/migrations/20261126040000_ritmo_schema.sql` | Banco: schema `ritmo` isolado no projeto **dri-imoveis** |
| `supabase/migrations/20261126050000_ritmo_assinatura.sql` | Planos, assinaturas, pagamentos e bloqueio por vencimento |
| `supabase/functions/ritmo-pagamento/index.ts` | Checkout Mercado Pago + webhook |

## Colocar no ar
1. **Banco (uma vez):** Supabase → dri-imoveis → SQL Editor → cole e rode o arquivo da migration.
2. **Expor o schema:** Project Settings → Data API → *Exposed schemas* → adicione `ritmo` → Save.
3. **Chave:** Project Settings → API Keys → copie a *publishable key* (ou `anon`) e cole em `SUPABASE_KEY` no topo da seção "Nuvem" do `index.html`.
4. **Login:** Authentication → URL Configuration → em *Redirect URLs* adicione `https://consultaia.github.io/consultaia-ritmo/**`.
5. **Site:** GitHub → Settings → Pages → Branch `main` / root. Endereço: `https://consultaia.github.io/consultaia-ritmo/`.

## Assinatura (multitenant: cada conta é um cliente)
- Cadastro → **7 dias grátis** sem cartão → planos **Mensal R$ 9,90 · 6 meses R$ 49,90 · Anual R$ 89,90** (tabela `ritmo.planos`; mude preço direto lá).
- Pagamento por **Mercado Pago Checkout Pro** (Pix ou cartão), sem renovação automática. Pagar de novo soma dias ao que falta.
- Vencido: o app mostra os planos; os dados continuam guardados e podem ser baixados.

### Ativar cobrança
1. SQL Editor → rode `supabase/migrations/20261126050000_ritmo_assinatura.sql`.
2. Edge Functions → *Deploy a new function* → *Via editor* → nome **`ritmo-pagamento`** → cole `supabase/functions/ritmo-pagamento/index.ts` → em *Function configuration* **desligue Verify JWT** → Deploy.
3. Edge Functions → **Secrets** → `MP_ACCESS_TOKEN` = Access Token de **produção** do Mercado Pago (Suas integrações → aplicação → Credenciais de produção).
4. Mercado Pago → Suas integrações → aplicação → **Webhooks** → URL `https://xmqmnmyejkfpmniljkbt.supabase.co/functions/v1/ritmo-pagamento/webhook`, evento **Pagamentos**.

## Segurança
- Assinatura e pagamentos só são gravados pela Edge Function (service role); o valor vem do banco e o pagamento é conferido direto na API do Mercado Pago (aviso repetido não credita duas vezes, valor menor não libera).
- Conta vencida não grava na nuvem (RLS), mas continua lendo os próprios dados.
- Tabela `ritmo.estado`: um documento JSON por usuário, RLS ligada (cada um só lê/grava o seu), `anon` sem acesso, limite de 2 MB.
- Nada no schema `public` do dri-imoveis é lido ou alterado.
