#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# MODELO de arquivo de segredos do scraper.
#
# COMO USAR (execução LOCAL no seu Mac):
#   1) Copie este arquivo:   cp scraper_secrets.example.sh scraper_secrets.sh
#   2) Cole sua API key da Zyte no campo ZYTE_API_KEY abaixo.
#   3) Pronto. O baixar_csv.sh carrega "scraper_secrets.sh" automaticamente.
#
# O arquivo real "scraper_secrets.sh" está no .gitignore e NUNCA é versionado.
#
# NO GITHUB ACTIONS (CI) este arquivo NÃO é usado: lá as chaves vêm dos Secrets
# do repositório (Settings → Secrets and variables → Actions). Cadastre:
#   - Secret  ZYTE_API_KEY     = sua API key da Zyte (PRINCIPAL — Método Z)
# ─────────────────────────────────────────────────────────────────────────────

# Zyte API (PRINCIPAL — Método Z). Unlocker anti-bot gerenciado; pegue a API key em
# https://app.zyte.com (Zyte API → Get API key). Crédito grátis mensal cobre ~1 download/dia.
export ZYTE_API_KEY=""

# (OPCIONAL) Monitoramento de uso da Zyte no heartbeat de WhatsApp. A Zyte não tem
# endpoint de "saldo restante"; isto mostra uso/sucesso/gasto dos últimos 7 dias.
#   ZYTE_STATS_KEY = "Zyte dashboard API key" (app.zyte.com → Settings) — NÃO é a key acima
#   ZYTE_ORG_ID    = organization id (na URL: app.zyte.com/o/XXXXXX)
# No GitHub Actions, cadastre os Secrets ZYTE_STATS_KEY e ZYTE_ORG_ID p/ ativar no CI.
export ZYTE_STATS_KEY=""
export ZYTE_ORG_ID=""
