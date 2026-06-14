#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# MODELO de arquivo de segredos do scraper.
#
# COMO USAR (execução LOCAL no seu Mac):
#   1) Copie este arquivo:   cp scraper_secrets.example.sh scraper_secrets.sh
#   2) Cole seu token da Scrape.do no campo SCRAPEDO_TOKEN abaixo.
#   3) Pronto. O baixar_csv.sh carrega "scraper_secrets.sh" automaticamente.
#
# O arquivo real "scraper_secrets.sh" está no .gitignore e NUNCA é versionado.
#
# NO GITHUB ACTIONS (CI) este arquivo NÃO é usado: lá as chaves vêm dos Secrets
# do repositório (Settings → Secrets and variables → Actions). Cadastre:
#   - Secret  ZYTE_API_KEY     = sua API key da Zyte (PRINCIPAL — Método Z)
#   - Secret  BR_PROXY         = http://USUARIO:SENHA@HOST:PORTA  (proxy residencial BR)
#   - Secret  SCRAPEDO_TOKEN   = seu token da Scrape.do
# ─────────────────────────────────────────────────────────────────────────────

# Zyte API (PRINCIPAL — Método Z). Unlocker anti-bot gerenciado; pegue a API key em
# https://app.zyte.com (Zyte API → Get API key). Crédito grátis mensal cobre ~1 download/dia.
export ZYTE_API_KEY=""

# Proxy residencial brasileiro (fallback — Método P). Formato completo:
#   http://USUARIO:SENHA@HOST:PORTA
# Garanta que o endpoint sai pelo Brasil (no IPRoyal o usuário vira ...country-br).
export BR_PROXY=""

# Scrape.do — token da API. Pegue em https://dashboard.scrape.do (plano grátis: 1.000 créditos/mês).
export SCRAPEDO_TOKEN=""

# (Legado/opcional) ScraperAPI — mantido só como fallback enquanto a chave durar.
# Deixe em branco se você não usa mais o ScraperAPI.
export SCRAPERAPI_KEY=""
export SCRAPERAPI_ULTRA="true"
