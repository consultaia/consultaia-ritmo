# Ritmo — rotina inteligente

PWA (um `index.html`, sem build) que organiza tarefas, hábitos, metas, lembretes e gastos em volta da rotina de cada pessoa: **escala/plantão**, **horário fixo** ou **rotina flexível**.

- Captura por voz ou texto ("consulta sexta às 14h", "gastei 45 no mercado")
- ⚡ Distribuir: encaixa tarefas e atividades no tempo livre da semana
- Grade semanal, resumo do dia (com envio no WhatsApp), painel de gestão do tempo
- Funciona offline; com login, sincroniza entre aparelhos (Supabase)

## Estrutura
| Arquivo | Para quê |
|---|---|
| `index.html`, `assets/*.jpg` | Landing page de vendas (raiz do site) com prints reais do app |
| `termos.html`, `privacidade.html` | Termos de Uso e Política de Privacidade (LGPD) |
| `app/index.html` | App inteiro (HTML + CSS + JS puro) |
| `app/sw.js`, `app/manifest.json`, `app/icon-*.png` | Instalação no celular e uso offline |
| `supabase/migrations/20261126130000_ritmo.sql` | Banco: tabelas e funções `ritmo_*` no projeto **enamed-engine** (ConsultaIA) |
| `supabase/functions/ritmo-pagamento/index.ts` | Checkout Mercado Pago + webhook (pagamento e estorno) |
| `supabase/remover_do_dri_imoveis.sql` | Limpeza do antigo schema `ritmo` no projeto da Dri |

## Onde roda
- Site: GitHub Pages. Landing em `https://consultaia.github.io/consultaia-ritmo/`, app em `/app/`.
- Banco e login: Supabase **enamed-engine** (`jtkkqmqlydqenxwnttyi`), o mesmo do Preceptor. O login é a conta ConsultaIA: quem já tem conta no Preceptor entra no Ritmo com o mesmo e-mail e senha.
- Tudo do Ritmo tem prefixo `ritmo_` e não altera nada do Preceptor.

## Assinatura (cada conta é um cliente independente)
- Cadastro → **7 dias grátis** sem cartão (um teste por e-mail; pontos e `+algo` do Gmail não geram teste novo).
- Planos em `public.ritmo_planos`: **Mensal R$ 9,90 · 6 meses R$ 49,90 · Anual R$ 89,90**. Para mudar preço, edite a tabela.
- Pagamento por **Mercado Pago Checkout Pro** (Pix ou cartão), sem renovação automática. Estorno ou chargeback tira os dias liberados.
- Vencido: o app mostra os planos; os dados continuam guardados e podem ser baixados.

### Configuração (uma vez)
1. Edge Functions → Secrets → `RITMO_MP_ACCESS_TOKEN` = Access Token de produção da aplicação "Ritmo ConsultaIA" no Mercado Pago.
2. Mercado Pago → Webhooks (produção) → `https://jtkkqmqlydqenxwnttyi.supabase.co/functions/v1/ritmo-pagamento/webhook`, evento **Pagamentos**.
3. Supabase → Authentication → URL Configuration → Redirect URLs → `https://consultaia.github.io/consultaia-ritmo/**` (para o "Esqueci a senha" voltar ao Ritmo).

## Sincronização
- Um documento JSON por conta em `ritmo_estado`, com número de revisão (`rev`). O app só grava se a revisão bater; se outro aparelho gravou antes, ele junta as alterações dos dois lados (merge de 3 vias) e grava de novo.

## Segurança
- RLS em todas as tabelas: cada conta só lê e grava o próprio estado; conta vencida lê mas não grava.
- Assinatura e pagamentos só são gravados pela Edge Function (service role). O preço vem do banco e o pagamento é conferido direto na API do Mercado Pago (aviso repetido não credita duas vezes, valor menor não libera).
- Limite de 2 MB por conta; o app arquiva sozinho o histórico com mais de 400 dias.
