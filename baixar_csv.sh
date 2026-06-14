#!/bin/bash
# Baixa a lista de imóveis PB da Caixa e salva em "planilhas leilao" com carimbo de data.
#
# ESTRATÉGIA ANTI-RADWARE (5 métodos em cascata):
#
# A Caixa protege o endpoint com Radware Bot Manager, que devolve uma página de desafio
# JavaScript (~18 KB de HTML) no lugar do CSV quando detecta IP de datacenter ou curl puro.
# O curl direto NUNCA passa em GitHub Actions (IP de datacenter). A cadeia abaixo resolve:
#
#  Método 0 — Scrape.do (PRINCIPAL) — substituto do ScraperAPI
#    Proxy gerenciado com bypass anti-bot embutido. geoCode=br fixa IP residencial
#    brasileiro (sem custo extra) e super=true usa a rede residencial/móvel.
#    Cobra créditos SÓ em caso de sucesso (plano grátis: 1.000 créditos/mês).
#      0a) super=true (residencial, 10 créditos) — tenta primeiro, mais barato
#      0b) super=true + render=true (25 créditos) — fallback que executa o JS do Radware
#    Token via env SCRAPEDO_TOKEN (Secret no CI; arquivo local scraper_secrets.sh).
#
#  Método A — ScraperAPI + render=true
#    O ScraperAPI lança um Chromium headless que executa o desafio JS do Radware,
#    obtém o cookie de validação dentro da mesma sessão e devolve o CSV real.
#    É a correção principal: sem render=true, o ScraperAPI retornava a página de desafio.
#
#  Método B — ScraperAPI + session warmup (mesmo IP para toda a sessão)
#    Usa session_number para fixar o mesmo IP residencial BR em 3 requisições:
#    GET origem → GET download-lista.asp → GET CSV.
#    Fallback sem renderização JS; funciona se Radware confiar no IP após warmup.
#
#  Método C — Playwright com ScraperAPI como proxy HTTP residencial
#    Playwright (browser real, não curl) roda localmente no Actions, mas todo o
#    tráfego passa pelo proxy ScraperAPI (IP residencial BR). O Chromium executa
#    o JS do Radware; o ScraperAPI fornece o IP. Mais pesado, mas muito confiável.
#    Ativado apenas se o pacote playwright estiver instalado.
#
#  Método D — curl direto com session warmup (último recurso)
#    Funciona no Mac do usuário (internet aberta), mas falha no CI. Mantido para
#    rodar o script localmente sem precisar de SCRAPERAPI_KEY.
#
# Se NADA funcionar, sai com erro sem salvar lixo.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Em execução LOCAL, carrega as chaves de um arquivo NÃO versionado (ignorado no .gitignore).
# Em CI (GitHub Actions), as chaves chegam pelo ambiente (Secrets) e este arquivo não existe.
[ -f "$DIR/scraper_secrets.sh" ] && source "$DIR/scraper_secrets.sh"

DEST="$DIR/planilhas leilao"
URL="https://venda-imoveis.caixa.gov.br/listaweb/Lista_imoveis_PB.csv"
PAGE="https://venda-imoveis.caixa.gov.br/sistema/download-lista.asp"
ORIGIN="https://venda-imoveis.caixa.gov.br/"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

# Cabeçalhos de navegador reusados pelos métodos baseados em curl (P e D).
CH_HEADERS=(
  -H 'sec-ch-ua: "Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"'
  -H 'sec-ch-ua-mobile: ?0'
  -H 'sec-ch-ua-platform: "macOS"'
  -H 'Upgrade-Insecure-Requests: 1'
  -H 'Accept-Language: pt-BR,pt;q=0.9,en;q=0.8'
)

mkdir -p "$DEST"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="$DEST/Lista_imoveis_PB_${TS}.csv"
JAR="$(mktemp /tmp/leilao_cookies.XXXXXX)"
trap 'rm -f "$JAR"' EXIT

ts(){ date '+%d/%m/%Y %H:%M:%S'; }

# Valida se o arquivo é um CSV real da Caixa. Retorna 0 = válido, 1 = inválido.
is_valid_csv() {
  local f="$1"
  [ -s "$f" ] || return 1
  local sz; sz=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
  # Rejeita página anti-robô / HTML
  if head -c 3000 "$f" | grep -qiE "radware|captcha|bot manager|<html|<head|<!doctype|window\.SSJSInternal"; then
    echo "  → veio página anti-robô (CAPTCHA/HTML), não o CSV."
    return 1
  fi
  # CSV real da Caixa tem ~300 KB; abaixo de 100 KB é suspeito
  if [ "${sz:-0}" -lt 100000 ]; then
    echo "  → arquivo pequeno demais (${sz} bytes) para ser a lista completa."
    return 1
  fi
  # Confere colunas típicas do CSV da Caixa (encoding latin1)
  if ! head -c 6000 "$f" | iconv -f latin1 -t utf-8 2>/dev/null | grep -qiE "endere|bairro|munic|valor|im[oó]vel"; then
    echo "  → conteúdo não parece a lista de imóveis da Caixa."
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# MÉTODO Z: Zyte API (PRINCIPAL) — "unlocker" anti-bot gerenciado + geo BR
# Endpoint: POST https://api.zyte.com/v1/extract  (auth Basic: chave como usuário).
# Pede httpResponseBody (corpo bruto, base64) com geolocation=BR; a Zyte resolve o
# desafio do Radware no servidor dela e devolve o CSV. Cobra só em sucesso e tem
# crédito grátis mensal — barato/grátis para 1 download/dia.
# Decodifica o base64 com python3 (portável Mac/Linux; evita jq e base64 BSD).
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${ZYTE_API_KEY:-}" ]; then
  echo "[$(ts)] Método Z: Zyte API (httpResponseBody, geolocation=BR)…"
  ZRESP="$(mktemp /tmp/zyte_resp.XXXXXX)"
  for n in 1 2 3; do
    curl -fsS --connect-timeout 30 --max-time 300 \
         --user "${ZYTE_API_KEY}:" \
         --header 'Content-Type: application/json' \
         --data "{\"url\":\"${URL}\",\"httpResponseBody\":true,\"geolocation\":\"BR\"}" \
         "https://api.zyte.com/v1/extract" -o "$ZRESP" 2>/dev/null || true
    # Extrai .httpResponseBody e grava o CSV decodificado em $OUT
    python3 - "$ZRESP" "$OUT" <<'PY' 2>/dev/null || true
import json, base64, sys
try:
    d = json.load(open(sys.argv[1]))
    body = d.get("httpResponseBody")
    if body:
        with open(sys.argv[2], "wb") as f:
            f.write(base64.b64decode(body))
except Exception:
    pass
PY
    if is_valid_csv "$OUT"; then
      SZ=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
      echo "[$(ts)] ✓ Método Z OK: $OUT (${SZ} bytes) — tentativa $n"
      rm -f "$ZRESP"; exit 0
    fi
    echo "[$(ts)] Método Z tentativa $n falhou."
    rm -f "$OUT"; [ "$n" -lt 3 ] && sleep $((n * 5))
  done
  rm -f "$ZRESP"
  echo "[$(ts)] Método Z falhou — tentando próximos métodos…"
fi

# ─────────────────────────────────────────────────────────────────────────────
# MÉTODO P: proxy residencial brasileiro (pay-as-you-go)  [fallback]
# Usa BR_PROXY como gateway (-x). Aquece a sessão (origem -> download-lista.asp)
# e baixa o CSV com os mesmos cookies/IP. Evidência: o Método B do ScraperAPI
# funcionou só com IP residencial BR + warmup (sem render).
# Se o warmup com curl não bastar (Radware exigir JS), cai para o Playwright pelo
# mesmo proxy (Plano B), reusando baixar_csv_playwright.py.
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

  # Plano B: Playwright (Chromium real) pelo mesmo proxy residencial BR.
  # Só roda se o pacote playwright estiver instalado.
  if python3 -c "import playwright" 2>/dev/null; then
    echo "[$(ts)] Método P (Plano B): Playwright pelo proxy residencial BR…"
    if BR_PROXY="$BR_PROXY" python3 "$DIR/baixar_csv_playwright.py" "$OUT" 2>&1; then
      if is_valid_csv "$OUT"; then
        SZ=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
        echo "[$(ts)] ✓ Método P (Playwright) OK: $OUT (${SZ} bytes)"
        exit 0
      fi
    fi
    rm -f "$OUT"
  fi
  echo "[$(ts)] Método P falhou — tentando próximos métodos…"
fi

# ─────────────────────────────────────────────────────────────────────────────
# MÉTODO 0: Scrape.do (PRINCIPAL) — residencial BR + bypass anti-bot gerenciado
# Endpoint: https://api.scrape.do/?token=...&url=...&super=true&geoCode=br[&render=true]
# - geoCode=br não custa créditos extras (custo definido só por super/render).
# - Cobra apenas em caso de sucesso (2xx). Tentativas que falham são gratuitas.
# - Doc de custos: https://scrape.do/documentation/request-costs/
# Estratégia: tenta primeiro só residencial (10 créditos); se vier a página
# anti-robô, repete com render=true (25 créditos) para executar o JS do Radware.
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${SCRAPEDO_TOKEN:-}" ]; then
  # Args base (nunca vazio → seguro com `set -u` no bash 3.2 do macOS).
  SD_ARGS=(
    -fsS --connect-timeout 30 --max-time 300
    -G "https://api.scrape.do/"
    --data-urlencode "token=${SCRAPEDO_TOKEN}"
    --data-urlencode "url=${URL}"
    --data-urlencode "super=true"
    --data-urlencode "geoCode=br"
  )

  echo "[$(ts)] Método 0a: Scrape.do residencial BR (super=true, geoCode=br)…"
  curl "${SD_ARGS[@]}" -o "$OUT" 2>/dev/null || true
  if is_valid_csv "$OUT"; then
    SZ=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
    echo "[$(ts)] ✓ Método 0a OK: $OUT (${SZ} bytes)"
    exit 0
  fi
  rm -f "$OUT"

  echo "[$(ts)] Método 0b: Scrape.do residencial BR + render (executa o JS do Radware)…"
  curl "${SD_ARGS[@]}" --data-urlencode "render=true" -o "$OUT" 2>/dev/null || true
  if is_valid_csv "$OUT"; then
    SZ=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
    echo "[$(ts)] ✓ Método 0b OK: $OUT (${SZ} bytes)"
    exit 0
  fi
  echo "[$(ts)] Método 0 (Scrape.do) falhou — tentando ScraperAPI / curl direto…"
  rm -f "$OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# MÉTODO A: ScraperAPI + render=true
# O Radware exige execução de JS para emitir cookie de validação. Sem render=true
# o ScraperAPI faz um GET simples e recebe a página de desafio no lugar do CSV.
# Com render=true o ScraperAPI usa Chromium headless → executa o JS → recebe o CSV.
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${SCRAPERAPI_KEY:-}" ]; then
  premium_param="premium=true"
  [ "${SCRAPERAPI_ULTRA:-}" = "true" ] && premium_param="ultra_premium=true"

  echo "[$(ts)] Método A: ScraperAPI render=true ($premium_param, country_code=br)…"
  curl -fsS --connect-timeout 30 --max-time 300 \
       -G "https://api.scraperapi.com/" \
       --data-urlencode "api_key=${SCRAPERAPI_KEY}" \
       --data-urlencode "url=${URL}" \
       --data-urlencode "render=true" \
       --data-urlencode "$premium_param" \
       --data-urlencode "country_code=br" \
       -o "$OUT" 2>/dev/null || true
  if is_valid_csv "$OUT"; then
    SZ=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
    echo "[$(ts)] ✓ Método A OK: $OUT (${SZ} bytes)"
    exit 0
  fi
  echo "[$(ts)] Método A falhou — tentando Método B…"
  rm -f "$OUT"

  # ───────────────────────────────────────────────────────────────────────────
  # MÉTODO B: ScraperAPI + session warmup (sem render, mesmo IP residencial BR)
  # Usa session_number para fixar o mesmo IP residencial em 3 chamadas consecutivas:
  # origem → download-lista.asp → CSV. Ajuda quando Radware libera após ver o IP
  # visitando o site de forma sequencial (sem JS, mas com IP residencial confiável).
  # ───────────────────────────────────────────────────────────────────────────
  SESSION_NUM=$(( (RANDOM * RANDOM) % 9000 + 1000 ))
  echo "[$(ts)] Método B: ScraperAPI session warmup (session=$SESSION_NUM, $premium_param)…"

  # Warmup 1: visita a origem com o mesmo IP residencial
  curl -fsS --connect-timeout 30 --max-time 60 \
       -G "https://api.scraperapi.com/" \
       --data-urlencode "api_key=${SCRAPERAPI_KEY}" \
       --data-urlencode "url=${ORIGIN}" \
       --data-urlencode "session_number=${SESSION_NUM}" \
       --data-urlencode "country_code=br" \
       -o /dev/null 2>/dev/null || true
  sleep 2

  # Warmup 2: visita a página de download (coleta cookies e referrer)
  curl -fsS --connect-timeout 30 --max-time 60 \
       -G "https://api.scraperapi.com/" \
       --data-urlencode "api_key=${SCRAPERAPI_KEY}" \
       --data-urlencode "url=${PAGE}" \
       --data-urlencode "session_number=${SESSION_NUM}" \
       --data-urlencode "country_code=br" \
       -o /dev/null 2>/dev/null || true
  sleep 2

  # Download: mesmo IP da sessão aquecida
  curl -fsS --connect-timeout 30 --max-time 180 \
       -G "https://api.scraperapi.com/" \
       --data-urlencode "api_key=${SCRAPERAPI_KEY}" \
       --data-urlencode "url=${URL}" \
       --data-urlencode "session_number=${SESSION_NUM}" \
       --data-urlencode "$premium_param" \
       --data-urlencode "country_code=br" \
       -o "$OUT" 2>/dev/null || true
  if is_valid_csv "$OUT"; then
    SZ=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
    echo "[$(ts)] ✓ Método B OK: $OUT (${SZ} bytes)"
    exit 0
  fi
  echo "[$(ts)] Método B falhou — tentando Método C…"
  rm -f "$OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
# MÉTODO C: Playwright com ScraperAPI como proxy HTTP residencial
# Playwright lança um Chromium real que executa o JS do Radware. Todo o tráfego
# passa pelo proxy ScraperAPI (IP residencial BR). Combinação mais confiável:
# browser real + IP residencial. Requer pacote `playwright` instalado.
# ─────────────────────────────────────────────────────────────────────────────
if python3 -c "import playwright" 2>/dev/null; then
  echo "[$(ts)] Método C: Playwright + ScraperAPI proxy…"
  if python3 "$(dirname "${BASH_SOURCE[0]}")/baixar_csv_playwright.py" \
       "$OUT" "${SCRAPERAPI_KEY:-}" "${SCRAPERAPI_ULTRA:-false}" 2>&1; then
    if is_valid_csv "$OUT"; then
      SZ=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
      echo "[$(ts)] ✓ Método C OK: $OUT (${SZ} bytes)"
      exit 0
    fi
  fi
  echo "[$(ts)] Método C falhou — tentando Método D (curl direto)…"
  rm -f "$OUT"
else
  echo "[$(ts)] Método C ignorado (playwright não instalado) — tentando Método D…"
fi

# ─────────────────────────────────────────────────────────────────────────────
# MÉTODO D: curl direto com session warmup
# Funciona no Mac do usuário (IP residencial, internet aberta). Em GitHub Actions
# (IP de datacenter) quase sempre falha, mas é mantido como último recurso e para
# uso local sem SCRAPERAPI_KEY.
# ─────────────────────────────────────────────────────────────────────────────
echo "[$(ts)] Método D: curl direto (${SCRAPERAPI_KEY:+sem chave disponível, }internet aberta)…"

ATTEMPTS=4
for n in $(seq 1 $ATTEMPTS); do
  # Aquece sessão: origem → download-lista.asp (acumula cookies)
  curl -fsSL -A "$UA" -c "$JAR" -b "$JAR" "${CH_HEADERS[@]}" \
       -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
       -H 'Sec-Fetch-Dest: document' -H 'Sec-Fetch-Mode: navigate' \
       -H 'Sec-Fetch-Site: none' -H 'Sec-Fetch-User: ?1' \
       --connect-timeout 20 --max-time 60 "$ORIGIN" -o /dev/null 2>/dev/null || true
  sleep 1
  curl -fsSL -A "$UA" -c "$JAR" -b "$JAR" "${CH_HEADERS[@]}" \
       -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
       -e "$ORIGIN" -H "Referer: $ORIGIN" \
       -H 'Sec-Fetch-Dest: document' -H 'Sec-Fetch-Mode: navigate' \
       -H 'Sec-Fetch-Site: same-origin' -H 'Sec-Fetch-User: ?1' \
       --connect-timeout 20 --max-time 60 "$PAGE" -o /dev/null 2>/dev/null || true
  sleep 1

  # Baixa o CSV com cookies da sessão aquecida
  curl -fSL --connect-timeout 20 --max-time 120 \
       -A "$UA" -e "$PAGE" -b "$JAR" -c "$JAR" "${CH_HEADERS[@]}" \
       -H "Accept: text/csv,application/octet-stream,application/vnd.ms-excel,*/*" \
       -H "Referer: $PAGE" \
       -H 'Sec-Fetch-Dest: empty' -H 'Sec-Fetch-Mode: cors' -H 'Sec-Fetch-Site: same-origin' \
       -o "$OUT" "$URL" 2>/dev/null || true

  if is_valid_csv "$OUT"; then
    SZ=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo 0)
    echo "[$(ts)] ✓ Método D OK: $OUT (${SZ} bytes) — tentativa $n/$ATTEMPTS"
    exit 0
  fi

  echo "[$(ts)] Método D tentativa $n/$ATTEMPTS falhou."
  rm -f "$OUT"
  [ "$n" -lt "$ATTEMPTS" ] && sleep $((n * 15))
done

echo "[$(ts)] ERRO: todos os métodos falharam (A/B/C/D). O Radware bloqueou todas as tentativas."
echo "[$(ts)] Nada foi salvo — o ciclo seguirá com o último CSV bom."
exit 1
