# Plano de implementação — Proxy residencial brasileiro no download da Caixa

> Documento de handoff. Foi escrito para ser executado numa **sessão nova**, por alguém
> (ou uma IA) que **não acompanhou** a conversa anterior. Leia da seção 1 à 8 na ordem.

---

## 1. Contexto (leia primeiro)

**O projeto** (`leilao`, repo `github.com/mateussoutolima/leilao`) baixa todo dia o CSV de
imóveis de leilão da Caixa para a Paraíba, analisa/filtra e envia alertas no WhatsApp (Z-API).
Roda no **GitHub Actions** (cron 10:00 UTC, arquivo `.github/workflows/diario.yml`) e também
pode rodar localmente no Mac (`rodar_diario.sh`).

**O problema central:** a URL do CSV
(`https://venda-imoveis.caixa.gov.br/listaweb/Lista_imoveis_PB.csv`) é protegida pelo
**Radware Bot Manager**, que devolve uma página de desafio (CAPTCHA/JS) no lugar do CSV
quando detecta **IP de datacenter** (como o do GitHub Actions). Para passar, precisa de um
**IP residencial brasileiro**.

**O que já foi testado:**
- ScraperAPI **funciona** (pegou o CSV de ~323 KB em 14/06/2026), mas o trial está acabando e
  o plano com geo do Brasil é o **Business ($299/mês)** — caro demais. O Hobby ($49) só tem
  geo US/EU, não serve.
- Scrape.do (plano grátis) **NÃO funciona**: mesmo com residencial + render, o Radware
  bloqueia o pool de IPs dela (`502 ROTATION_FAILED`).
- Rodar no Mac com auto-wake foi **descartado**: o Mac fica na bateria/tampa fechada e não
  acorda de forma confiável.

**Evidência técnica que orienta este plano:** o **Método B do ScraperAPI funcionou SEM
render** — apenas com IP residencial BR + "aquecimento" de sessão (visitar a origem e a
página de download antes de baixar o CSV). Ou seja, **o Radware da Caixa confia em IP
residencial BR de verdade; não é obrigatório executar JS**. Um proxy residencial cru deve,
portanto, funcionar com simples `curl` + warmup.

---

## 2. Decisão e por quê

Usar um **proxy residencial brasileiro pay-as-you-go** (pago por banda, por GB), conectado
ao download via `curl` (e, se necessário, via Playwright). Motivos:

- **Barato a ponto de ser quase grátis:** o download diário é ~300 KB (com warmup, poucos MB).
  Isso dá **~0,15 GB/mês**. A banda residencial BR custa **$0,49–$1,75/GB**, ou seja
  **< $0,30/mês**. Na prática, uma recarga mínima (~$1–$5) dura **anos**.
- **Roda 24/7 na nuvem**, sem depender do Mac ligado.
- **Reaproveita o código existente** (a lógica de warmup do Método D e o proxy do Método C).
- **Mesmo tipo de IP** que já venceu esse Radware (residencial BR), então a chance de
  sucesso é alta — diferente da Scrape.do.

---

## 3. Pré-requisito: contratar o proxy (feito pelo Mateus, fora do código)

Escolher **um** provedor com pay-as-you-go residencial e geo Brasil. Sugestões (mais baratos):
- **Evomi** (~$0,49/GB) — evomi.com
- **IPRoyal** (~$1,75/GB, créditos não expiram) — iproyal.com
- **Databay** (~$0,55/GB) — databay.com
- (qualquer provedor residencial reputado com saída no Brasil serve)

Passos genéricos no painel do provedor:
1. Criar conta e comprar **Residential / Rotating** no modelo **pay-as-you-go** (recarga
   mínima, ~$1–$5).
2. Em "proxy access"/"endpoint", **selecionar país = Brazil**.
3. Copiar a string de conexão. Ela costuma vir como **host, porta, usuário e senha**, às vezes
   com o país embutido no usuário. Exemplos (NÃO copiar literalmente; use o do seu painel):
   - IPRoyal: `geo.iproyal.com:12321`, user `SEUUSER_country-br`, pass `SUASENHA`
   - Evomi:  `rp.evomi.com:1000` (porta/host conforme painel), com flag de país conforme doc
4. Montar a URL única no formato:
   ```
   http://USUARIO:SENHA@HOST:PORTA
   ```
   Guardar essa URL — ela será o segredo `BR_PROXY` (seção 4.1).

> **Antes de mexer no código, validar o proxy** (seção 5). Só seguir para a implementação
> depois que o teste local trouxer o CSV de verdade (~300 KB).

---

## 4. Implementação no código

### 4.1 Cadastrar o segredo `BR_PROXY`

**No GitHub (obrigatório, é onde roda):**
- Repositório → **Settings → Secrets and variables → Actions → New repository secret**
- Name: `BR_PROXY`
- Secret: a URL completa `http://USUARIO:SENHA@HOST:PORTA` (sem aspas)

**Wirar no workflow** — em `.github/workflows/diario.yml`, no passo
`1/4 — Baixar CSV da Caixa`, adicionar a variável de ambiente (junto das que já existem):
```yaml
        env:
          BR_PROXY: ${{ secrets.BR_PROXY }}
          SCRAPEDO_TOKEN: ${{ secrets.SCRAPEDO_TOKEN }}
          SCRAPERAPI_KEY: ${{ secrets.SCRAPERAPI_KEY }}
          SCRAPERAPI_ULTRA: ${{ vars.SCRAPERAPI_ULTRA }}
```

**No local (opcional)** — o arquivo `scraper_secrets.sh` (já existe, está no `.gitignore`)
ganha mais uma linha:
```bash
export BR_PROXY="http://USUARIO:SENHA@HOST:PORTA"
```
E atualizar o modelo `scraper_secrets.example.sh` com a mesma linha (com valor vazio).

### 4.2 Adicionar "Método P" no `baixar_csv.sh`

O `baixar_csv.sh` já tem uma cascata de métodos. O arquivo carrega os segredos locais no topo
(`source scraper_secrets.sh`), define `is_valid_csv()`, e hoje tenta: Método 0 (Scrape.do),
A/B (ScraperAPI), C (Playwright), D (curl direto).

**Tarefa:** inserir o **Método P (proxy residencial BR)** como **método principal**, logo
após a função `is_valid_csv()` e ANTES do Método 0. Ele aquece a sessão pelo proxy e baixa o
CSV — espelhando o Método B do ScraperAPI, que funcionou sem render.

Snippet a inserir (ajustar se o array `CH_HEADERS` ainda não estiver definido neste ponto —
ele hoje é definido dentro do Método D; mover a definição de `CH_HEADERS` para perto do topo,
logo após as variáveis `UA`/`URL`/`PAGE`/`ORIGIN`, para os dois métodos reusarem):

```bash
# ─────────────────────────────────────────────────────────────────────────────
# MÉTODO P: proxy residencial brasileiro (pay-as-you-go)  [PRINCIPAL]
# Usa BR_PROXY como gateway (-x). Aquece a sessão (origem -> download-lista.asp)
# e baixa o CSV com os mesmos cookies/IP. Evidência: o Método B do ScraperAPI
# funcionou só com IP residencial BR + warmup (sem render).
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${BR_PROXY:-}" ]; then
  echo "[$(ts)] Método P: proxy residencial BR (warmup + download)…"
  for n in 1 2 3; do
    # Warmup 1: origem
    curl -fsSL -x "$BR_PROXY" -A "$UA" -c "$JAR" -b "$JAR" "${CH_HEADERS[@]}" \
         -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
         --connect-timeout 30 --max-time 90 "$ORIGIN" -o /dev/null 2>/dev/null || true
    sleep 1
    # Warmup 2: página de download (acumula cookies/referrer)
    curl -fsSL -x "$BR_PROXY" -A "$UA" -c "$JAR" -b "$JAR" "${CH_HEADERS[@]}" \
         -e "$ORIGIN" -H "Referer: $ORIGIN" \
         --connect-timeout 30 --max-time 90 "$PAGE" -o /dev/null 2>/dev/null || true
    sleep 1
    # Download do CSV com a sessão aquecida
    curl -fSL -x "$BR_PROXY" -A "$UA" -e "$PAGE" -b "$JAR" -c "$JAR" "${CH_HEADERS[@]}" \
         -H "Accept: text/csv,application/octet-stream,application/vnd.ms-excel,*/*" \
         -H "Referer: $PAGE" \
         --connect-timeout 30 --max-time 120 -o "$OUT" "$URL" 2>/dev/null || true
    if is_valid_csv "$OUT"; then
      SZ=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
      echo "[$(ts)] ✓ Método P OK: $OUT (${SZ} bytes) — tentativa $n"
      exit 0
    fi
    echo "[$(ts)] Método P tentativa $n falhou."
    rm -f "$OUT"; [ "$n" -lt 3 ] && sleep $((n * 5))
  done
  echo "[$(ts)] Método P falhou — tentando próximos métodos…"
fi
```

### 4.3 (Plano B, só se o Método P apanhar do Radware) Playwright pelo proxy

Se o warmup com `curl` não bastar (Radware exigir execução de JS), reaproveitar o
`baixar_csv_playwright.py` (Método C), que já roda um Chromium real através de um proxy.
Hoje ele monta o proxy a partir da chave do ScraperAPI; adaptar a função `build_proxy()`
para aceitar um proxy genérico no formato `http://user:pass@host:port` (ou seja, ler `BR_PROXY`
e quebrar em `server`, `username`, `password` para o Playwright). Chamar esse caminho dentro
do Método P como fallback antes de cair para os métodos antigos.

---

## 5. Teste (rodar ANTES e DEPOIS de mexer no código)

No Terminal do Mac (substituir pela URL real do proxy):

```bash
BR_PROXY='http://USUARIO:SENHA@HOST:PORTA'

echo "== 1) o proxy sai pelo Brasil? (espera BR) =="
curl -s -x "$BR_PROXY" https://ipinfo.io/country; echo

echo "== 2) consegue baixar o CSV da Caixa? (espera ~300KB+) =="
curl -s -x "$BR_PROXY" -o /tmp/caixa.csv -w 'HTTP %{http_code} | %{size_download}b\n' \
  -A 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36' \
  'https://venda-imoveis.caixa.gov.br/listaweb/Lista_imoveis_PB.csv'
echo '--- início da resposta: ---'; head -c 200 /tmp/caixa.csv; echo
```

Interpretação:
- Teste 1 deve responder **BR**. Se não, ajustar o país no painel/usuário do proxy.
- Teste 2: se vier **~300 KB+** e começar com cabeçalhos de planilha (ex.: contém
  "Endereço", "Bairro", "Município", "Valor"), **funcionou** → seguir com a implementação.
- Se vier HTML pequeno com "radware"/"captcha", o `curl` simples não bastou → testar com o
  **warmup** (rodar `bash baixar_csv.sh` localmente com `BR_PROXY` setado) e, se ainda falhar,
  ir para o Plano B (Playwright, seção 4.3).

Validar a sintaxe após editar: `bash -n baixar_csv.sh`.

---

## 6. Limpeza e segurança

- **Token da Scrape.do vazou** numa conversa anterior (`867280ac74918a2576baf2d3e5b21a59`).
  Gerar um token novo no painel (ou simplesmente abandonar a conta) e **remover o secret
  `SCRAPEDO_TOKEN`** do GitHub, já que a Scrape.do não funciona aqui.
- Pode-se **remover o Método 0 (Scrape.do)** do `baixar_csv.sh` (não funciona) para deixar a
  cascata limpa: Método P (proxy) → A/B/C (ScraperAPI, enquanto o trial durar) → D (curl local).
- Quando o Método P estiver estável por alguns dias, **remover ScraperAPI** (secret
  `SCRAPERAPI_KEY` + Métodos A/B/C) para simplificar.
- Segredos (proxy, tokens) **nunca** vão em arquivo versionado — só no Secret do GitHub e no
  `scraper_secrets.sh` local (que está no `.gitignore`).

---

## 7. Arquivos e convenções de referência

- `baixar_csv.sh` — cascata de download. Carrega `scraper_secrets.sh` no topo. Variáveis úteis
  já definidas: `URL` (CSV), `PAGE` (download-lista.asp), `ORIGIN` (raiz do site), `UA`,
  `OUT` (arquivo de saída), `JAR` (cookies), função `ts()` e `is_valid_csv()`.
- `baixar_csv_playwright.py` — Método C, Chromium via proxy (base para o Plano B).
- `.github/workflows/diario.yml` — pipeline diário; passo "1/4" roda `baixar_csv.sh` e recebe
  os segredos via `env`. Há um passo final que **falha o job de propósito** (e manda e-mail) se
  nenhum método trouxe CSV novo — atualizar a mensagem de erro para citar o Método P.
- `scraper_secrets.example.sh` / `scraper_secrets.sh` — modelo e arquivo real (gitignored) de
  chaves para execução local.
- `rodar_diario.sh` — ciclo completo local (download → análise → WhatsApp → baseline).

**Como os segredos fluem:** no GitHub Actions vêm dos **Secrets** (via `env` no workflow); no
Mac vêm do arquivo `scraper_secrets.sh`. O `baixar_csv.sh` lê tudo de variáveis de ambiente
(`BR_PROXY`, etc.), então funciona nos dois lugares sem mudança.

---

## 8. Checklist final

- [ ] Contratar proxy residencial BR pay-as-you-go e montar a URL `http://user:pass@host:porta`
- [ ] Teste local (seção 5): país = BR e CSV ~300 KB
- [ ] Criar Secret `BR_PROXY` no GitHub
- [ ] Adicionar `BR_PROXY` ao `env` do passo "1/4" em `diario.yml`
- [ ] Inserir o **Método P** no `baixar_csv.sh` (e mover `CH_HEADERS` para o topo)
- [ ] (Local) adicionar `BR_PROXY` em `scraper_secrets.sh` e no `.example`
- [ ] `bash -n baixar_csv.sh` (checar sintaxe)
- [ ] Commit + push
- [ ] Rodar o workflow manualmente (**Actions → Run workflow**) e ver `✓ Método P OK` no log
- [ ] Remover Scrape.do (Método 0 + secret) e rotacionar o token vazado
- [ ] Depois de estável: remover ScraperAPI (Métodos A/B/C + secret)
