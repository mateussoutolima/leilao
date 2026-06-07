# Leilão PB — Contexto para nova sessão

Cole este arquivo (ou peça para o Claude lê-lo) ao abrir uma nova sessão.

## Objetivo
Ferramenta em duas partes para achar bons negócios em leilões de imóveis da Caixa na Paraíba (PB).

- **Parte 1 (pronta):** dashboard interativo — mapa, filtros por coluna, KPIs, seleção de área no mapa, fallback de endereço garantindo coordenadas no Brasil, filtro por bairro, configuração de alarmes, controle novo-vs-visto, camada de confiança de localização.
- **Parte 2 (pronta):** rotina diária que baixa o CSV, recalcula oportunidades segundo os alarmes, marca NOVAS oportunidades, valida endereços via Google Maps (Chrome) e gera notificações (chat + painel + WhatsApp).
- **WhatsApp (pronto):** envio via Z-API (zapi.io) das oportunidades que dispararam alarme, com destinatários configuráveis por alarme. Sem sandbox, sem opt-in — funciona como WhatsApp normal.

## Execução na nuvem (GitHub Actions) — ARQUITETURA ATUAL (jun/2026)
O ciclo diário roda 100% na nuvem, **sem depender do Mac estar ligado** (motivo da migração: o launchd só rodava com o Mac acordado).
- **Repo:** `mateusslima92/leilao` (PÚBLICO — necessário para o GitHub Pages grátis).
- **Workflow:** `.github/workflows/diario.yml`. Cron `0 10 * * *` (10:00 UTC = **07:00 BRT**) + botão "Run workflow". Etapas: baixar CSV → `prepare` → `whatsapp_sender.py` → `commit` → commit-back do estado no repo → publicar painel no Pages.
- **Painel sempre online:** https://mateusslima92.github.io/leilao/ (deploy via GitHub Pages a cada rodada).
- **Download do CSV na nuvem:** IP de datacenter do GitHub é bloqueado pelo Radware (CAPTCHA). Solução: `baixar_csv.sh` tenta primeiro via **ScraperAPI** (IP residencial BR, Secret `SCRAPERAPI_KEY`; opcional Variable `SCRAPERAPI_ULTRA=true`), com fallback para o download direto e, por fim, para o último CSV bom commitado.
- **Privacidade (repo público):** os telefones dos destinatários NÃO ficam no repo nem no painel. Vêm do Secret `LEILAO_RECIPIENTS` (JSON `{"<alarmId>": ["+55...","grupo-id"]}`), injetados só no `build_outbox` por `alarms_with_recipients()` em `leilao_routine.py`. O `leilao_state.json` commitado tem `recipients: []`.
- **Secrets no repo:** `ZAPI_INSTANCE_ID`, `ZAPI_TOKEN`, `ZAPI_CLIENT_TOKEN`, `LEILAO_RECIPIENTS`, `SCRAPERAPI_KEY`. (Arquivo local `recipients.secret.json` é gitignored e guarda os destinatários para colar no Secret.)
- **Aviso de falha:** se num dia não vier CSV novo, o workflow roda tudo com o último CSV bom e então **falha de propósito** no último passo, disparando o e-mail nativo do GitHub (Settings → Notifications → Actions).
- **Como mudar alarmes:** edite os critérios no painel local → dê push do `leilao_state.json` (mantendo `recipients` vazio). Para mudar quem recebe, edite o Secret `LEILAO_RECIPIENTS`. Guia completo em `README_DEPLOY.md`.
- **Comandos via gh CLI** estão no `README_DEPLOY.md` (criar repo, secrets, ativar Pages, rodar).

## Arquitetura importante
- O sandbox do Cowork **NÃO alcança a internet aberta** (Twilio, Google, Caixa bloqueados). Por isso:
  - O **download do CSV** usa o LINK DIRETO da Caixa: `https://venda-imoveis.caixa.gov.br/listaweb/Lista_imoveis_PB.csv` (sem formulário/Chrome/ponte JS — era o que falhava). Roda NO MAC, pois o sandbox é bloqueado (proxy 403). Mecanismos: `baixar_csv.sh` (núcleo), `Baixar Lista Caixa.command` (duplo-clique), e o launchd `com.mateus.leilao-download` (diário 07:00). Salvam direto em `planilhas leilao/` com carimbo de data.
  - **Organização dos CSVs:** ficam em `planilhas leilao/` (subpasta do projeto). `prepare` também arquiva automaticamente um CSV mais novo de Downloads/raiz para lá (`archive_csv()`); `find_csv()` procura nessa pasta primeiro. Mantém o repo limpo.
  - Diagnóstico (jun/2026): a falha de download era a automação do formulário (dropdown + ponte JS do Chrome, que caía) somada ao bloqueio de rede do sandbox. Resolvido pelo link direto + download no Mac.
  - O **envio de WhatsApp roda nativamente no Mac** via `whatsapp_sender.py` (a rotina do Cowork só escreve `whatsapp_outbox.json`).
- Scripts se auto-localizam (`os.path.dirname(__file__)` + glob em `/sessions/*/mnt/...`) porque o prefixo `/sessions/<nome>/` muda a cada sessão.

## Arquivos no projeto (`/Users/mateuslima/Desktop/Claude Code Projects/leilao`)
- `leilao_routine.py` — motor da Parte 2. Subcomandos: `prepare`, `merge`, `add-coord ID LAT LON [CEP] [PREC]`, `commit`, `summary`. Gera `imoveis.json`, `dashboard_leilao.html`, `validate_queue.json`, `last_summary.json`, `whatsapp_outbox.json`.
- `template.html` — template do dashboard (campo de destinatários WhatsApp por alarme; seed de alarmes/seen a partir do META).
- `whatsapp_sender.py` — envia o outbox via Twilio (nativo no Mac). Modos: padrão, `--dry-run`, `--test +NUMERO`. Idempotente via `whatsapp_sent.json`.
- `whatsapp_secrets.example.json` — modelo. Copiar para `whatsapp_secrets.json` e preencher com `instance_id` e `token` do Z-API (NUNCA compartilhar/commitar).
- `com.mateus.leilao-whatsapp.plist` — job launchd diário 07:20 que roda o sender.
- `leilao_state.json` — estado limpo (um alarme de exemplo desativado, sem destinatários, seen/geocache vazios).

## Dados (CSV da Caixa)
Latin-1, separado por `;`, dados a partir da linha 4. ~855 imóveis PB, 40 cidades. Só 36 financiáveis ("Sim"); desconto máx 77,17%; 146 com desc≥50; 10 com desc≥62.
Score = 0.80*descontoNorm + 0.12*rankPpm2barato + 0.08*financiável (0–100).

## Filtro de cidade (reduz processamento) — padrão João Pessoa
`leilao_routine.py` restringe TODO o pipeline a uma cidade já no parsing do CSV (antes de score/geocode/validação/dashboard), para cortar processamento do schedule e dos alarmes. Padrão = **João Pessoa** (432 imóveis vs 855 da PB). Override por ambiente:
- `LEILAO_CITY=""` → inclui todas as cidades da PB
- `LEILAO_CITY="Campina Grande"` → outra cidade
Constante `CITY_FILTER` no topo do script. O dashboard, fila de validação, alarmes e outbox passam a refletir só a cidade filtrada.

## Filtros de alarme (dashboard + motor)
Além de score/desconto/preço/R$m²/quartos/financ/tipos/cidades, o alarme agora tem:
- **bairros**: multi-seleção no editor (depende das cidades escolhidas); campo `a.bairros` no estado.
- **área no mapa**: desenhe ▭/⬠ no mapa e clique "Usar área desenhada"; salvo em `a.area` como `{type:'rect',bounds:[[s,w],[n,e]]}` ou `{type:'polygon',points:[[lat,lon],…]}`. Testado por ray casting tanto no navegador (`pointInGeom`) quanto na rotina (`point_in_geom` em leilao_routine.py) — então o WhatsApp diário respeita bairro+área.
- Cuidado: matching de área usa as coords do imóvel; pins aproximados (cidade) podem cair fora. Rode "Corrigir endereços" antes para áreas pequenas.

## Pré-filtro por bairro antes do refinamento de endereço
Para economizar refinamento (Maps/Nominatim, ~1 req/s), o refinamento de endereço só roda nos **bairros-alvo** = bairros nomeados no alarme/sidebar ∪ bairros que a ÁREA abrange. O mapeamento área→bairro é confiável mesmo com coords aproximadas (bairro vem exato do CSV).
- Python (`leilao_routine.py`): `alarm_bairro_set()`, `queue_match()`, `wants_refinement()`; `validate_queue.json` é construído só com imóveis nesses bairros. Match final do WhatsApp continua preciso (`match_alarm` com teste de área ponto-a-ponto, já com coords refinadas após o merge).
- Dashboard (`template.html`): `refinementTargetBairros()` + `pendingForRefinement()`; "Corrigir endereços" refina só os bairros do filtro/área e mostra o escopo na geobar.
- Refatoração: `_match_nonspatial()` é compartilhado entre o match preciso e o coarse.

## Validação de endereço (Google Maps via Control_Chrome)
`open_url` na busca do Maps → esperar ~5s → `get_current_tab` → se a URL tem `/place/`, extrair coords de `!3d<lat>!4d<lon>` (ou `/@lat,lon`) + CEP; se ficar em `/search/`, **pular (nunca inventar coordenadas)**.

## Execução diária autônoma — JOB ÚNICO NO MAC (LEGADO / backup local — substituído pela nuvem)
`rodar_diario.sh` faz o ciclo completo 100% no Mac, sem Cowork e sem Chrome: baixar CSV (link direto) → `prepare` → `whatsapp_sender.py` → `commit`. Log em `rodar_diario.log`.
- launchd `com.mateus.leilao-diario` (diário 07:00) chama o script. Instala com `cp` p/ ~/Library/LaunchAgents + `launchctl load`.
- Manual: duplo-clique em `Rodar Agora.command` (ou o botão "⚡ Rodar workflow" no painel, ou `python3 leilao_routine.py prepare && python3 whatsapp_sender.py`).
- Hibernação: launchd sozinho roda no próximo wake; para disparar no horário mesmo dormindo, `sudo pmset repeat wakeorpoweron MTWRFSU 06:58:00` (acorda 06:58). Wake do sono é confiável; ligar do desligado total só em alguns Macs.
- Dispensa: os jobs separados `com.mateus.leilao-download` e `com.mateus.leilao-whatsapp`, e a tarefa do Cowork `leilao-pb-diario` (pode desativar para não duplicar). O sender é idempotente, então duplicar não reenvia.
- Trade-off vs. Cowork: perde a validação de endereço no Google Maps (coords precisas) e o resumo no chat. Como os alarmes filtram por bairros exatos, o WhatsApp não é afetado; a validação de endereço pode ser feita sob demanda no painel ("Corrigir endereços").

## Tarefa agendada antiga (Cowork — opcional/legado)
`leilao-pb-diario` — cron `0 7 * * *` (com botão "Run now"). Orquestra: localizar $LEILAO → baixar CSV (Chrome direto, best-effort) → `prepare` → validar no Maps → `merge` → `commit` → resumo no chat. Só roda com o app do Cowork aberto. Substituída pelo job único do Mac acima.

## WhatsApp — Z-API (configurado)
Sender migrado de Twilio para Z-API (zapi.io). Sem sandbox, sem opt-in para destinatários.
`whatsapp_secrets.json` precisa de:
- `instance_id` — ID da instância no painel Z-API
- `token` — token DA INSTÂNCIA
- `client_token` — **Token de Segurança da Conta** (aba Security do painel). Enviado como header `Client-Token`. OBRIGATÓRIO se o recurso "Account Security Token" estiver ativado — sem ele toda chamada falha (`{"error":"null not allowed"}` / HTTP 4xx) mesmo com instance_id/token corretos. Esta foi a causa do "não funciona".
- `from_phone` — só informativo (Z-API usa o WhatsApp conectado automaticamente)

Setup inicial: criar conta em z-api.io → criar instância → escanear QR code com o WhatsApp remetente → copiar o Token de Segurança da Conta (aba Security) para `client_token`.

Diagnóstico rápido: `python3 whatsapp_sender.py --status` (verifica conexão da instância sem enviar nada). `--test +55DDDNUMERO` envia uma mensagem de teste.

## Próximos passos depois que o teste funcionar
- Confirmar instalação do launchd (`cp` do .plist para `~/Library/LaunchAgents/` + `launchctl load`).
- Usuário define alarmes reais (exporta `leilao_state.json` para a pasta leilao com `recipients`).
- Clicar "Run now" em `leilao-pb-diario` para pré-aprovar Chrome + Downloads.

## Restrições de segurança a preservar
- Claude NUNCA digita credenciais/tokens do usuário; o usuário preenche `whatsapp_secrets.json` sozinho e nunca compartilha/commita.
- Envio a terceiros via WhatsApp exige opt-in ou templates aprovados.
- Nunca inventar coordenadas (pular se não houver `/place/`).
- Nunca burlar restrições de rede/conteúdo com métodos alternativos de fetch.
