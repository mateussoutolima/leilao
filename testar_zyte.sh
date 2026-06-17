#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# TESTE PONTA-A-PONTA do download via Zyte + pipeline de análise/alarme.
#
# Diferente do baixar_csv.sh (que cai pro curl direto quando a Zyte falha), este
# teste é FOCADO na Zyte: se a Zyte falhar, ele ACUSA — para você saber se o
# problema é key/saldo, sem o fallback mascarar.
#
# USO:
#   ./testar_zyte.sh              # REAL: chama a Zyte de verdade (rode no seu Mac)
#   ./testar_zyte.sh --mock FILE  # OFFLINE: simula a resposta da Zyte com um CSV
#                                  # local, exercitando decode→validação→parse→alarme
#                                  # (sem rede; serve pra validar o pipeline)
#
# A key vem de scraper_secrets.sh (local) ou da env ZYTE_API_KEY (CI).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$DIR/scraper_secrets.sh" ] && source "$DIR/scraper_secrets.sh"

URL="https://venda-imoveis.caixa.gov.br/listaweb/Lista_imoveis_PB.csv"
TMP_CSV="$(mktemp /tmp/teste_zyte_csv.XXXXXX)"
ZRESP="$(mktemp /tmp/teste_zyte_resp.XXXXXX)"
trap 'rm -f "$TMP_CSV" "$ZRESP"' EXIT

ok(){   echo "  ✓ $*"; }
bad(){  echo "  ✗ $*"; }
hr(){   echo "────────────────────────────────────────────────────────"; }

MOCK_FILE=""
if [ "${1:-}" = "--mock" ]; then MOCK_FILE="${2:-}"; fi

# ── Modo --stats: testa SÓ a Stats API da Zyte (uso/sucesso/gasto 7 dias) ─────
if [ "${1:-}" = "--stats" ]; then
  echo "TESTE STATS ZYTE — $(date '+%d/%m/%Y %H:%M:%S')"
  hr
  if [ -z "${ZYTE_STATS_KEY:-}" ] || [ -z "${ZYTE_ORG_ID:-}" ]; then
    bad "ZYTE_STATS_KEY e/ou ZYTE_ORG_ID vazias em scraper_secrets.sh"; exit 1
  fi
  ok "ZYTE_STATS_KEY presente (****${ZYTE_STATS_KEY: -4}) · org ${ZYTE_ORG_ID}"
  RESP="$(mktemp /tmp/teste_stats.XXXXXX)"; trap 'rm -f "$RESP"' EXIT
  HTTP=$(curl -sS --connect-timeout 15 --max-time 40 --compressed \
       --user "${ZYTE_STATS_KEY}:" -w '%{http_code}' \
       "https://zyte-api-stats.zyte.com/api/stats?organization_id=${ZYTE_ORG_ID}" \
       -o "$RESP" 2>/dev/null)
  if [ "$HTTP" != "200" ]; then
    bad "Stats API devolveu HTTP $HTTP (≠200)."
    echo "      Corpo (início):"; head -c 500 "$RESP" | sed 's/^/      /'; echo ""
    echo "      401 = key errada (use a *dashboard* API key, não a ZYTE_API_KEY) · 422 = org id inválido."
    exit 1
  fi
  ok "Stats API respondeu HTTP 200"
  python3 - "$RESP" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); rows = d.get("results") or []
reqs = sum(int(r.get("request_count") or 0) for r in rows)
ok = 0; cost = 0.0
for r in rows:
    cost += float(r.get("cost_microusd_total") or 0)
    for sc in (r.get("status_codes") or []):
        if sc.get("code") == 200: ok += int(sc.get("count") or 0)
pct = round(100*ok/reqs) if reqs else None
print(f"      → últimos 7 dias: {reqs} req · {pct}% ok · ~US$ {round(cost/1e6,4)}")
print(f"      linha do heartbeat: 💳 Zyte (7d): {reqs} req · {pct}% ok · ~US$ {round(cost/1e6,4)}")
PY
  hr; ok "TESTE STATS CONCLUÍDO"; exit 0
fi

echo "TESTE ZYTE — $(date '+%d/%m/%Y %H:%M:%S')"
hr

# ── 1) Obter a resposta (real via Zyte, ou mock a partir de um CSV local) ──────
if [ -n "$MOCK_FILE" ]; then
  echo "[1] Modo MOCK — simulando resposta da Zyte a partir de: $MOCK_FILE"
  if [ ! -s "$MOCK_FILE" ]; then bad "arquivo mock não existe/está vazio"; exit 1; fi
  # Monta {"httpResponseBody":"<base64 do CSV>"} exatamente como a Zyte devolveria.
  python3 - "$MOCK_FILE" "$ZRESP" <<'PY'
import base64, json, sys
raw = open(sys.argv[1], "rb").read()
json.dump({"httpResponseBody": base64.b64encode(raw).decode()}, open(sys.argv[2], "w"))
PY
  ok "resposta simulada gravada"
else
  echo "[1] Modo REAL — chamando a Zyte (httpResponseBody, geolocation=BR)…"
  if [ -z "${ZYTE_API_KEY:-}" ]; then
    bad "ZYTE_API_KEY vazia — cole a key em scraper_secrets.sh"; exit 1
  fi
  ok "ZYTE_API_KEY presente (****${ZYTE_API_KEY: -4})"
  HTTP=$(curl -sS --connect-timeout 30 --max-time 300 \
       --user "${ZYTE_API_KEY}:" \
       --header 'Content-Type: application/json' \
       --data "{\"url\":\"${URL}\",\"httpResponseBody\":true,\"geolocation\":\"BR\"}" \
       -w '%{http_code}' \
       "https://api.zyte.com/v1/extract" -o "$ZRESP" 2>/dev/null)
  if [ "$HTTP" != "200" ]; then
    bad "Zyte devolveu HTTP $HTTP (≠200)."
    echo "      Corpo da resposta (início), útil pra diagnóstico:"
    head -c 600 "$ZRESP" | sed 's/^/      /'
    echo ""
    echo "      Causas comuns: 401/403 = key inválida · 429/402 = saldo de créditos esgotado · 5xx = Radware derrubou."
    exit 1
  fi
  ok "Zyte respondeu HTTP 200"
fi

# ── 2) Decodificar httpResponseBody (base64) → CSV ────────────────────────────
echo "[2] Decodificando httpResponseBody (base64) → CSV…"
python3 - "$ZRESP" "$TMP_CSV" <<'PY'
import base64, json, sys
try:
    d = json.load(open(sys.argv[1]))
    body = d.get("httpResponseBody")
    if not body:
        print("      (sem campo httpResponseBody na resposta)"); sys.exit(3)
    open(sys.argv[2], "wb").write(base64.b64decode(body))
except Exception as e:
    print("      erro ao decodificar:", e); sys.exit(3)
PY
[ $? -eq 0 ] || { bad "falha ao decodificar a resposta"; exit 1; }
SZ=$(stat -f%z "$TMP_CSV" 2>/dev/null || stat -c%s "$TMP_CSV" 2>/dev/null || echo 0)
ok "CSV decodificado (${SZ} bytes)"

# ── 3) Validar que é o CSV real da Caixa (não página anti-robô) ───────────────
echo "[3] Validando conteúdo…"
if head -c 3000 "$TMP_CSV" | grep -qiE "radware|captcha|bot manager|<html|<head|<!doctype|window\.SSJSInternal"; then
  bad "veio página anti-robô (HTML/CAPTCHA), não o CSV — a Zyte não furou o Radware."
  exit 1
fi
if [ "${SZ:-0}" -lt 100000 ]; then
  bad "arquivo pequeno demais (${SZ} bytes) para a lista completa."; exit 1
fi
if ! head -c 6000 "$TMP_CSV" | iconv -f latin1 -t utf-8 2>/dev/null | grep -qiE "endere|bairro|munic|valor|im[oó]vel"; then
  bad "conteúdo não parece a lista de imóveis da Caixa."; exit 1
fi
ok "é um CSV válido da Caixa"

# ── 4) Parse + alarme (pipeline real do projeto) ──────────────────────────────
echo "[4] Rodando parse + alarme (leilao_routine.py)…"
python3 - "$TMP_CSV" "$DIR" <<'PY'
import sys, os, json
csv_path, here = sys.argv[1], sys.argv[2]
sys.path.insert(0, here)
import leilao_routine as L
state = L.load_state()
records = L.score_records(L.parse_csv(csv_path))
L.overlay_geocache(records, state["geocache"])
seen = set(state["seen"]); alarms = state["alarms"]
total_jp   = len(records)
matched    = [r for r in records if L.matches_any(r, alarms)]
matched_nw = [r for r in matched if r["id"] not in seen]
new_ids    = [r["id"] for r in records if r["id"] not in seen]
print(f"      linhas João Pessoa : {total_jp}")
print(f"      novos vs baseline   : {len(new_ids)}")
print(f"      casam com alarme    : {len(matched)}")
print(f"      casam E são novos   : {len(matched_nw)}  <- isso vira mensagem WhatsApp")
PY
[ $? -eq 0 ] || { bad "pipeline de análise falhou"; exit 1; }

hr
ok "TESTE PONTA-A-PONTA CONCLUÍDO"
[ -n "$MOCK_FILE" ] && echo "  (modo mock: tudo validado menos a chamada de rede real à Zyte)"
exit 0
