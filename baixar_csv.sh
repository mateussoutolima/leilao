#!/bin/bash
# Baixa a lista de imóveis PB da Caixa e salva em "planilhas leilao" com carimbo de data.
#
# ESTRATÉGIA ANTI-RADWARE (2 métodos em cascata):
#
# A Caixa protege o endpoint com Radware Bot Manager, que devolve uma página de desafio
# JavaScript no lugar do CSV quando detecta IP de datacenter ou curl puro. O curl direto
# NUNCA passa em GitHub Actions (IP de datacenter). A cadeia abaixo resolve:
#
#  Método Z — Zyte API (PRINCIPAL)
#    "Unlocker" anti-bot gerenciado: a Zyte resolve o desafio do Radware no servidor
#    dela, com geolocalização BR, e devolve o CSV bruto. Funciona no CI. Cobra só em
#    sucesso e tem crédito grátis mensal — grátis/barato para ~1 download/dia.
#    Chave via env ZYTE_API_KEY (Secret no CI; arquivo local scraper_secrets.sh).
#
#  Método D — curl direto com session warmup (fallback local)
#    Funciona no Mac do usuário (IP residencial, internet aberta), mas falha no CI
#    (IP de datacenter). Mantido para rodar o script localmente sem a chave da Zyte.
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

# Cabeçalhos de navegador usados pelo Método D (curl direto).
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
  echo "[$(ts)] Método Z falhou — tentando Método D (curl direto)…"
fi

# ─────────────────────────────────────────────────────────────────────────────
# MÉTODO D: curl direto com session warmup (fallback local)
# Funciona no Mac do usuário (IP residencial, internet aberta). Em GitHub Actions
# (IP de datacenter) quase sempre falha, mas é mantido como último recurso e para
# uso local sem ZYTE_API_KEY.
# ─────────────────────────────────────────────────────────────────────────────
echo "[$(ts)] Método D: curl direto (internet aberta)…"

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

echo "[$(ts)] ERRO: todos os métodos falharam (Z/D). O Radware bloqueou todas as tentativas."
echo "[$(ts)] Nada foi salvo — o ciclo seguirá com o último CSV bom."
exit 1
