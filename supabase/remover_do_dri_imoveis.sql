-- Rode UMA vez no SQL Editor do projeto dri-imoveis para tirar o Ritmo de lá.
-- Apaga só o schema "ritmo" (contas de teste). Não toca em nada do imobiliário.
drop schema if exists ritmo cascade;
-- Depois, no painel do dri-imoveis: apague a Edge Function "ritmo-pagamento", o Secret MP_ACCESS_TOKEN,
-- a Redirect URL do Ritmo e tire "ritmo" de Data API > Exposed schemas.
