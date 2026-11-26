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

## Colocar no ar
1. **Banco (uma vez):** Supabase → dri-imoveis → SQL Editor → cole e rode o arquivo da migration.
2. **Expor o schema:** Project Settings → Data API → *Exposed schemas* → adicione `ritmo` → Save.
3. **Chave:** Project Settings → API Keys → copie a *publishable key* (ou `anon`) e cole em `SUPABASE_KEY` no topo da seção "Nuvem" do `index.html`.
4. **Login:** Authentication → URL Configuration → em *Redirect URLs* adicione `https://consultaia.github.io/consultaia-ritmo/**`.
5. **Site:** GitHub → Settings → Pages → Branch `main` / root. Endereço: `https://consultaia.github.io/consultaia-ritmo/`.

## Segurança
- Tabela `ritmo.estado`: um documento JSON por usuário, RLS ligada (cada um só lê/grava o seu), `anon` sem acesso, limite de 2 MB.
- Nada no schema `public` do dri-imoveis é lido ou alterado.
