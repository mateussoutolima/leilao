#!/usr/bin/env python3
"""
Método C do baixar_csv.sh — Playwright com ScraperAPI como proxy HTTP residencial.

Por que isso funciona onde curl puro falha:
  - Radware Bot Manager exige execução de JavaScript para emitir um cookie de validação.
  - curl não executa JS → recebe a página de desafio em vez do CSV.
  - Playwright lança um Chromium REAL → executa o desafio JS → obtém o cookie.
  - O ScraperAPI é usado como proxy HTTP para fornecer um IP residencial brasileiro,
    evitando o bloqueio por reputação de IP de datacenter (GitHub Actions).

Uso:
  python3 baixar_csv_playwright.py <destino.csv> [scraperapi_key] [ultra=true|false]

Retorna 0 se o CSV foi salvo com sucesso, 1 caso contrário.
"""

import sys
import os
import time


CSV_URL  = "https://venda-imoveis.caixa.gov.br/listaweb/Lista_imoveis_PB.csv"
ORIGIN   = "https://venda-imoveis.caixa.gov.br/"
PAGE_URL = "https://venda-imoveis.caixa.gov.br/sistema/download-lista.asp"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)


def is_valid_csv(data: bytes) -> tuple[bool, str]:
    """Valida o conteúdo do CSV da Caixa. Retorna (válido, motivo)."""
    if not data:
        return False, "resposta vazia"
    if len(data) < 100_000:
        return False, f"muito pequeno ({len(data)} bytes)"
    # Detecta página de desafio / HTML
    sample = data[:3000].lower()
    if any(kw in sample for kw in (b"radware", b"captcha", b"bot manager",
                                    b"<html", b"<!doctype", b"window.ssjsinternal")):
        return False, "veio página anti-robô (CAPTCHA/HTML)"
    # Confere colunas típicas do CSV (latin1)
    try:
        text_sample = data[:6000].decode("latin1")
    except Exception:
        text_sample = data[:6000].decode("utf-8", errors="replace")
    keywords = ("endere", "bairro", "munic", "valor", "imóvel", "imovel")
    if not any(kw in text_sample.lower() for kw in keywords):
        return False, "conteúdo não parece lista de imóveis da Caixa"
    return True, "ok"


def build_proxy(api_key: str, ultra: bool) -> dict | None:
    """Monta a config de proxy para o Playwright usar o ScraperAPI como gateway."""
    if not api_key:
        return None
    # O ScraperAPI suporta parâmetros extras no username:
    #   scraperapi.country_code=br.ultra_premium=true:API_KEY@proxy.scraperapi.com:8001
    flags = "country_code=br"
    if ultra:
        flags += ".ultra_premium=true"
    return {
        "server":   "http://proxy.scraperapi.com:8001",
        "username": f"scraperapi.{flags}",
        "password": api_key,
    }


def download(dest: str, api_key: str, ultra: bool) -> bool:
    try:
        from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout
    except ImportError:
        print("[playwright] ERRO: pacote playwright não instalado.", flush=True)
        return False

    proxy = build_proxy(api_key, ultra)
    if proxy:
        print(f"[playwright] Proxy: {proxy['server']} (user={proxy['username'][:40]}…)", flush=True)
    else:
        print("[playwright] Sem proxy — usando conexão direta (funciona apenas no Mac).", flush=True)

    csv_body: bytes | None = None

    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True)
        ctx = browser.new_context(
            proxy=proxy,
            ignore_https_errors=True,   # necessário porque ScraperAPI é proxy MITM
            user_agent=UA,
            accept_downloads=True,
            extra_http_headers={
                "Accept-Language": "pt-BR,pt;q=0.9,en;q=0.8",
            },
        )
        page = ctx.new_page()

        # Intercepta a resposta do CSV antes de o browser tentar "renderizar" o binário
        def on_response(response):
            nonlocal csv_body
            if "Lista_imoveis_PB.csv" in response.url and response.status == 200:
                try:
                    body = response.body()
                    ok, reason = is_valid_csv(body)
                    print(f"[playwright] Resposta capturada: {len(body)} bytes — {reason}", flush=True)
                    if ok:
                        csv_body = body
                except Exception as exc:
                    print(f"[playwright] Aviso ao capturar body: {exc}", flush=True)

        page.on("response", on_response)

        # Passo 1 — aquece a sessão na origem para o Radware conhecer o IP
        print(f"[playwright] Aquecendo sessão em {ORIGIN} …", flush=True)
        try:
            page.goto(ORIGIN, wait_until="domcontentloaded", timeout=60_000)
            time.sleep(2)
        except PWTimeout:
            print("[playwright] Timeout na origem (continuando).", flush=True)
        except Exception as exc:
            print(f"[playwright] Aviso na origem: {exc}", flush=True)

        # Passo 2 — visita a página de download (como usuário real faria)
        print(f"[playwright] Visitando página de download …", flush=True)
        try:
            page.goto(PAGE_URL, wait_until="domcontentloaded", timeout=60_000)
            time.sleep(2)
        except PWTimeout:
            print("[playwright] Timeout na página de download (continuando).", flush=True)
        except Exception as exc:
            print(f"[playwright] Aviso na página de download: {exc}", flush=True)

        # Passo 3 — navega para a URL do CSV; o handler on_response captura o body
        print(f"[playwright] Navegando para o CSV: {CSV_URL} …", flush=True)
        try:
            page.goto(CSV_URL, wait_until="domcontentloaded", timeout=120_000)
            time.sleep(3)
        except PWTimeout:
            print("[playwright] Timeout no CSV (verificando se body foi capturado).", flush=True)
        except Exception as exc:
            print(f"[playwright] Aviso no CSV: {exc}", flush=True)

        browser.close()

    if csv_body:
        with open(dest, "wb") as f:
            f.write(csv_body)
        print(f"[playwright] ✓ Salvo em {dest} ({len(csv_body)} bytes)", flush=True)
        return True

    print("[playwright] Nenhum CSV válido capturado.", flush=True)
    return False


def main():
    dest    = sys.argv[1] if len(sys.argv) > 1 else "/tmp/Lista_imoveis_PB.csv"
    api_key = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("SCRAPERAPI_KEY", "")
    ultra   = (sys.argv[3].lower() == "true") if len(sys.argv) > 3 else (
                  os.environ.get("SCRAPERAPI_ULTRA", "").lower() == "true")

    success = download(dest, api_key, ultra)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
