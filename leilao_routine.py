#!/usr/bin/env python3
"""
Leilao PB — Part 2 routine.
Self-contained: parses the newest Caixa PB CSV, scores, offline-geocodes,
overlays Google-Maps-validated coordinates, detects NEW vs a committed
baseline, applies the user's alarms, queues matched properties for Maps
validation, and rebuilds the dashboard.

All working files live next to this script (the always-mounted leilao folder),
so paths survive across sessions regardless of the VM mount prefix.

Subcommands:
  prepare           Build data from newest CSV; write imoveis.json, validate_queue.json,
                    rebuild dashboard. Computes NEW vs baseline + alarm matches.
                    Does NOT touch the baseline. Prints a JSON summary.
  add-coord ID LAT LON [CEP] [PREC]
                    Store a Maps-validated coordinate into the state geocache.
  merge             Re-overlay the geocache onto the data and rebuild (after add-coord).
  commit            Fold the current listing into the baseline (so next run's "new"
                    is truly new) and append this run to history.
  summary           Print the last prepare summary again.
"""
import csv, json, re, unicodedata, hashlib, math, sys, os, glob, datetime, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
STATE     = os.path.join(HERE, 'leilao_state.json')
TEMPLATE  = os.path.join(HERE, 'template.html')
OUT_JSON  = os.path.join(HERE, 'imoveis.json')
QUEUE     = os.path.join(HERE, 'validate_queue.json')
DASHBOARD = os.path.join(HERE, 'dashboard_leilao.html')
SUMMARY   = os.path.join(HERE, 'last_summary.json')
OUTBOX    = os.path.join(HERE, 'whatsapp_outbox.json')
SHORTLINKS = os.path.join(HERE, 'shortlinks.json')       # cache de links encurtados (TinyURL)
DLSTATUS  = os.path.join(HERE, 'download_status.json')   # status do download (escrito por baixar_csv.sh)
RECIPIENTS_FILE = os.path.join(HERE, 'recipients.secret.json')  # destinatários locais (não versionado)
PLANILHAS = os.path.join(HERE, 'planilhas leilao')   # CSVs vivem aqui, p/ não bagunçar o repo

# ----------------------------- helpers -----------------------------
def norm(s):
    return ''.join(ch for ch in unicodedata.normalize('NFD', s or '')
                   if unicodedata.category(ch) != 'Mn').upper().strip()

# Restringe TODO o pipeline a uma cidade, para cortar processamento (parsing,
# geocodificação, validação no Maps, tamanho do dashboard). Padrão: João Pessoa,
# onde as análises acontecem. Override por ambiente:
#   LEILAO_CITY="" -> inclui todas as cidades da PB
#   LEILAO_CITY="Campina Grande" -> outra cidade
_CITY_ENV = os.environ.get('LEILAO_CITY', 'João Pessoa')
CITY_FILTER = norm(_CITY_ENV) if _CITY_ENV.strip() else None

def to_float(s):
    if s is None: return None
    s = s.strip()
    if not s: return None
    s = s.replace('.', '').replace(',', '.')
    try: return float(s)
    except: return None

def area_to_float(s):
    if s is None: return None
    try:
        v = float(s); return v if v > 0 else None
    except: return None

def find_csv():
    cands = []
    for pat in (
        os.path.join(PLANILHAS, 'Lista_imoveis_PB*.csv'),     # casa oficial dos CSVs
        '/sessions/*/mnt/Downloads/Lista_imoveis_PB*.csv',
        os.path.expanduser('~/Downloads/Lista_imoveis_PB*.csv'),
        os.path.join(HERE, 'Lista_imoveis_PB*.csv'),          # legado (raiz do projeto)
    ):
        cands += glob.glob(pat)
    cands = [c for c in cands if os.path.isfile(c)]
    if not cands: return None
    return max(cands, key=os.path.getmtime)

def archive_csv(src):
    """Garante que o CSV usado vive em 'planilhas leilao' (mantém o repo organizado).
    Copia de Downloads/raiz para a pasta, com carimbo de data; se já estiver lá, mantém."""
    os.makedirs(PLANILHAS, exist_ok=True)
    if os.path.dirname(os.path.abspath(src)) == os.path.abspath(PLANILHAS):
        return src
    ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    dst = os.path.join(PLANILHAS, f'Lista_imoveis_PB_{ts}.csv')
    try:
        shutil.copy2(src, dst)
        return dst
    except Exception:
        return src

# ----------------------------- geocoding (offline base) -----------------------------
def build_pb_coords():
    PB = {}
    try:
        from geonamescache import GeonamesCache
        gc = GeonamesCache()
        for cid, c in gc.get_cities().items():
            if c.get('countrycode') == 'BR' and c.get('admin1code') == '17':
                PB[norm(c['name'])] = (c['latitude'], c['longitude'])
    except Exception:
        pass
    MANUAL = {
        'BREJO DO CRUZ': (-6.3489, -37.4953), 'BOM SUCESSO': (-6.4533, -37.9264),
        'CONDADO': (-6.9075, -37.5950), 'GURJAO': (-7.2456, -36.4914),
        'JURIPIRANGA': (-7.3389, -35.1900), 'TEIXEIRA': (-7.2228, -37.2528),
        'JERICO': (-6.5503, -37.7942), 'LUCENA': (-6.9008, -34.8675),
        'MASSARANDUBA': (-7.1906, -35.7861), 'MOGEIRO': (-7.2997, -35.4806),
        'PAULISTA': (-6.6075, -37.6217), 'PILAR': (-7.2658, -35.2603),
        'PUXINANA': (-7.1606, -35.9550), 'RIACHO DOS CAVALOS': (-6.4439, -37.6489),
        'SAO JOAO DO CARIRI': (-7.3811, -36.5328),
        'JOAO PESSOA': (-7.1153, -34.8610), 'CAMPINA GRANDE': (-7.2306, -35.8811),
    }
    for k, v in MANUAL.items():
        PB.setdefault(k, v)
    return PB

PB_CENTER = (-7.12, -35.0)

def stable_offset(key, max_deg):
    h = hashlib.md5(key.encode('utf-8')).hexdigest()
    a = int(h[0:8], 16) / 0xFFFFFFFF
    r = int(h[8:16], 16) / 0xFFFFFFFF
    ang = a * 2 * math.pi
    rad = math.sqrt(r) * max_deg
    return (rad * math.cos(ang), rad * math.sin(ang))

def parse_desc(desc):
    out = {'tipo': None, 'area_total': None, 'area_priv': None, 'area_terreno': None,
           'quartos': None, 'vagas': None}
    if not desc: return out
    out['tipo'] = desc.split(',')[0].strip()
    def g(pat):
        m = re.search(pat, desc); return area_to_float(m.group(1)) if m else None
    out['area_total']   = g(r'([\d.]+)\s*de área total')
    out['area_priv']    = g(r'([\d.]+)\s*de área privativa')
    out['area_terreno'] = g(r'([\d.]+)\s*de área do terreno')
    m = re.search(r'(\d+)\s*qto', desc);  out['quartos'] = int(m.group(1)) if m else None
    m = re.search(r'(\d+)\s*vaga', desc); out['vagas']   = int(m.group(1)) if m else None
    return out

def clean_addr(end):
    s = re.sub(r',', ' ', end or '')
    s = re.sub(r'\bAPTO?\.?\s*\d+', ' ', s, flags=re.I)
    s = re.sub(r'\bAP\.?\s*\d+', ' ', s, flags=re.I)
    s = re.sub(r'\bBLOCO?\.?\s*[A-Z0-9]+', ' ', s, flags=re.I)
    s = re.sub(r'\bCASA\s*[A-Z0-9]?\b', ' ', s, flags=re.I)
    s = re.sub(r'\bCS\.?\s*\d+', ' ', s, flags=re.I)
    s = re.sub(r'\bQD\.?\s*[A-Z0-9]+', ' ', s, flags=re.I)
    s = re.sub(r'\bLT\.?\s*[A-Z0-9]+', ' ', s, flags=re.I)
    s = re.sub(r'\bN[º°.]?\s*SN\b', ' ', s, flags=re.I)
    s = re.sub(r'\bSN\b', ' ', s, flags=re.I)
    s = re.sub(r'\bN[º°.]?\s*(\d+)', r' \1 ', s, flags=re.I)
    s = re.sub(r'\s{2,}', ' ', s).strip()
    return s

def maps_query(r):
    parts = [clean_addr(r['endereco']), r['bairro'], r['cidade'], 'Paraiba', 'Brasil']
    return ', '.join([p for p in parts if p])

# ----------------------------- parse + score -----------------------------
def parse_csv(src):
    with open(src, encoding='latin-1') as f:
        lines = f.readlines()
    PB = build_pb_coords()
    records = []
    for l in lines[4:]:
        if not l.strip(): continue
        p = l.split(';')
        if len(p) < 12: continue
        p = [x.strip() for x in p]
        rid, uf, cidade, bairro, endereco, preco, aval, desc_pct, financ, descr, modal, link = p[:12]
        if CITY_FILTER and norm(cidade) != CITY_FILTER:
            continue   # filtro de cidade (padrão: João Pessoa) — economiza processamento
        preco_v = to_float(preco); aval_v = to_float(aval)
        try: desc_v = float(desc_pct) if desc_pct else None
        except: desc_v = None
        d = parse_desc(descr)
        area_best = d['area_priv'] or d['area_total'] or d['area_terreno']
        ppm2 = (preco_v / area_best) if (preco_v and area_best) else None
        cnorm = norm(cidade)
        if cnorm in PB:
            clat, clon = PB[cnorm]; geo_method = 'city'
        else:
            clat, clon = PB_CENTER; geo_method = 'pb_fallback'
        bo = stable_offset(cnorm + '|' + norm(bairro), 0.018)
        po = stable_offset(rid, 0.004)
        lat = clat + bo[0] + po[0]; lon = clon + bo[1] + po[1]
        records.append({
            'id': rid, 'uf': uf, 'cidade': norm(cidade), 'bairro': norm(bairro), 'endereco': endereco,
            'preco': preco_v, 'avaliacao': aval_v, 'desconto': desc_v,
            'financiamento': financ, 'modalidade': modal,
            'tipo': d['tipo'], 'area_total': d['area_total'], 'area_priv': d['area_priv'],
            'area_terreno': d['area_terreno'], 'quartos': d['quartos'], 'vagas': d['vagas'],
            'area_use': area_best, 'ppm2': round(ppm2, 2) if ppm2 else None,
            'descricao': descr, 'link': link,
            'lat': round(lat, 6), 'lon': round(lon, 6), 'geo': geo_method, 'prec': 'cidade',
        })
    return records

def score_records(records):
    descs = [r['desconto'] for r in records if r['desconto'] is not None]
    dmin, dmax = (min(descs), max(descs)) if descs else (0, 1)
    ppm2s = sorted([r['ppm2'] for r in records if r['ppm2'] is not None])
    def pct_rank(v):
        if not ppm2s or v is None: return None
        lo = sum(1 for x in ppm2s if x < v); return lo / len(ppm2s)
    for r in records:
        dnorm = ((r['desconto'] - dmin) / (dmax - dmin)) if (r['desconto'] is not None and dmax > dmin) else 0
        fin = 1 if (r['financiamento'] or '').lower().startswith('s') else 0
        pr = pct_rank(r['ppm2'])
        cheap = (1 - pr) if pr is not None else 0.5
        r['score'] = round((0.80 * dnorm + 0.12 * cheap + 0.08 * fin) * 100, 1)
    records.sort(key=lambda r: (r['score'] or 0), reverse=True)
    return records

# ----------------------------- alarms -----------------------------
def point_in_geom(r, g):
    """Ray casting / bbox test — mirrors pointInGeom() in template.html."""
    lat, lon = r.get('lat'), r.get('lon')
    if lat is None or lon is None or not g: return False
    if g.get('type') == 'rect':
        b = g.get('bounds') or []
        if len(b) < 2: return False
        s, w = b[0][0], b[0][1]; n, e = b[1][0], b[1][1]
        return s <= lat <= n and w <= lon <= e
    pts = g.get('points') or []
    inside = False; j = len(pts) - 1
    for i in range(len(pts)):
        yi, xi = pts[i][0], pts[i][1]; yj, xj = pts[j][0], pts[j][1]
        if ((yi > lat) != (yj > lat)) and (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside

def _match_nonspatial(r, a):
    """Todos os critérios menos bairro/área (compartilhado entre match preciso e coarse)."""
    if (r.get('score') or 0) < (a.get('scoreMin') or 0): return False
    if (r.get('desconto') or 0) < (a.get('descMin') or 0): return False
    if a.get('precoMax') is not None and (r.get('preco') is None or r['preco'] > a['precoMax']): return False
    if a.get('ppm2Max') is not None and (r.get('ppm2') is None or r['ppm2'] > a['ppm2Max']): return False
    if a.get('quartosMin') and (r.get('quartos') is None or r['quartos'] < a['quartosMin']): return False
    if a.get('financ') and r.get('financiamento') != a['financ']: return False
    if a.get('tipos') and r.get('tipo') not in a['tipos']: return False
    if a.get('cidades') and r.get('cidade') not in a['cidades']: return False
    return True

def match_alarm(r, a):
    """Match PRECISO (pós-refinamento): usa o teste de área ponto-a-ponto."""
    if not _match_nonspatial(r, a): return False
    if a.get('bairros') and (r.get('bairro') or '—') not in a['bairros']: return False
    if a.get('area') and not point_in_geom(r, a['area']): return False
    return True

def alarm_bairro_set(records, a):
    """Conjunto de bairros do alarme = bairros nomeados ∪ bairros que a área abrange.
    O mapeamento área→bairro é confiável mesmo com coords aproximadas (o bairro vem
    exato do CSV), então serve de pré-filtro barato antes do refinamento de endereço."""
    s = set(a.get('bairros') or [])
    if a.get('area'):
        s |= {(r.get('bairro') or '—') for r in records if point_in_geom(r, a['area'])}
    return s

def queue_match(r, a, records):
    """Match COARSE (pré-refinamento): critérios não-espaciais + pré-filtro por bairro
    (nomeados ∪ derivados da área). Decide QUAIS endereços vale a pena refinar."""
    if not _match_nonspatial(r, a): return False
    bs = alarm_bairro_set(records, a)
    if bs and (r.get('bairro') or '—') not in bs: return False
    return True

def wants_refinement(r, alarms, records):
    return any(queue_match(r, a, records) for a in alarms if a.get('enabled'))

def matches_any(r, alarms):
    return any(match_alarm(r, a) for a in alarms if a.get('enabled'))

def fmt_brl(n):
    if n is None: return '—'
    return 'R$ ' + format(int(round(n)), ',d').replace(',', '.')

MSG_MAX_ITEMS = 50  # quantos imóveis listar na mensagem antes de resumir o restante

def build_message_body(alarm, news):
    name = alarm.get('name') or 'Alarme'
    lines = [f"🏠 *{name}* — {len(news)} nova(s) oportunidade(s)", "Leilão Caixa · Paraíba", ""]
    for r in sorted(news, key=lambda r: -(r.get('score') or 0))[:MSG_MAX_ITEMS]:
        d = r.get('desconto')
        lines.append(
            f"• {('%.0f%% off' % d) if d is not None else ''} · {fmt_brl(r.get('preco'))} · "
            f"{r.get('tipo') or ''} — {r.get('cidade')}/{r.get('bairro') or ''} · score {r.get('score')}"
        )
        if r.get('endereco'):
            lines.append(f"  📍 {r['endereco']}")
        lines.append(f"  {r.get('link')}")
    if len(news) > MSG_MAX_ITEMS:
        lines.append(f"…+{len(news) - MSG_MAX_ITEMS} outras no painel.")
    return "\n".join(lines)

def recipients_from_env():
    """Destinatários vêm de uma variável de ambiente (GitHub Secret na nuvem),
    NUNCA do estado commitado, para que telefones não sejam publicados no repo
    público nem no painel. Formato: JSON {"<alarmId>": ["+55...", "grupo-id"]}.
    Vazio => sem override (uso local pode manter recipients no estado privado)."""
    raw = (os.environ.get('LEILAO_RECIPIENTS') or '').strip()
    if not raw:
        # Fallback LOCAL: arquivo não versionado recipients.secret.json no mesmo
        # formato {"<alarmId>": ["+55...", "grupo-id"]}. Em CI esse arquivo não
        # existe e os destinatários vêm do Secret LEILAO_RECIPIENTS acima.
        if os.path.exists(RECIPIENTS_FILE):
            try:
                with open(RECIPIENTS_FILE, encoding='utf-8') as f:
                    m = json.load(f)
                return m if isinstance(m, dict) else {}
            except Exception:
                sys.stderr.write("recipients.secret.json inválido — ignorando.\n")
        return {}
    try:
        m = json.loads(raw)
        return m if isinstance(m, dict) else {}
    except Exception:
        sys.stderr.write("LEILAO_RECIPIENTS não é um JSON válido — ignorando.\n")
        return {}

def alarms_with_recipients(alarms):
    """Cópia dos alarmes com recipients preenchidos a partir do ambiente.
    Usada SÓ para montar o outbox; os objetos originais (que vão para o painel,
    imoveis.json e estado) seguem sem telefone."""
    ov = recipients_from_env()
    if not ov:
        return alarms
    out = []
    for a in alarms:
        b = dict(a)
        rid = str(a.get('id'))
        if ov.get(rid):
            b['recipients'] = list(ov[rid])
        out.append(b)
    return out

def build_outbox(records, alarms, seen):
    """One message per (alarm with recipients) x recipient, only when there are NEW matches."""
    today = datetime.date.today().isoformat()
    messages = []
    for a in alarms:
        if not a.get('enabled'): continue
        recips = [str(x).strip() for x in (a.get('recipients') or []) if str(x).strip()]
        if not recips: continue
        am = [r for r in records if match_alarm(r, a)]
        anew = [r for r in am if r['id'] not in seen]
        if not anew: continue
        body = build_message_body(a, anew)
        bhash = hashlib.md5(body.encode('utf-8')).hexdigest()[:8]
        for to in recips:
            messages.append({
                'key': f"{today}:{a.get('id')}:{to}:{bhash}",
                'to': to, 'body': body,
                'alarmId': a.get('id'), 'alarmName': a.get('name'),
                'newCount': len(anew),
            })
    return {'date': today, 'generatedAt': datetime.datetime.now().isoformat(),
            'messages': messages}

# ----------------------------- heartbeat (status do run) -----------------------------
def load_download_status():
    """Lê download_status.json (escrito por baixar_csv.sh). None se não existir."""
    if os.path.exists(DLSTATUS):
        try:
            with open(DLSTATUS, encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            pass
    return None

def _fmt_kb(n):
    try:
        return f"{round(int(n) / 1024)} KB"
    except Exception:
        return "—"

def _titlecase(s):
    return ' '.join(w.capitalize() for w in str(s).split())

def format_alarm_filters(alarms):
    """Resumo legível dos parâmetros de cada alarme habilitado, para entrar na
    mensagem de status (você vê na hora o que está sendo filtrado)."""
    out = []
    for a in (alarms or []):
        if not a.get('enabled'):
            continue
        out.append(f"🎯 Filtros — \"{a.get('name') or 'Alarme'}\":")
        if a.get('tipos'):
            out.append("   tipo: " + ", ".join(a['tipos']))
        if a.get('cidades'):
            out.append("   cidade: " + ", ".join(_titlecase(c) for c in a['cidades']))
        if a.get('bairros'):
            out.append("   bairros: " + ", ".join(_titlecase(b) for b in a['bairros']))
        crit = []
        if a.get('descMin'):
            crit.append(f"desc ≥ {a['descMin']}%")
        if a.get('precoMax') is not None:
            crit.append(f"preço ≤ {fmt_brl(a['precoMax'])}")
        if a.get('ppm2Max') is not None:
            crit.append(f"R$/m² ≤ {fmt_brl(a['ppm2Max'])}")
        if a.get('quartosMin'):
            crit.append(f"quartos ≥ {a['quartosMin']}")
        if a.get('scoreMin'):
            crit.append(f"score ≥ {a['scoreMin']}")
        if a.get('financ'):
            crit.append("aceita financiamento" if str(a['financ']).lower().startswith('s') else "sem financiamento")
        if a.get('area'):
            crit.append("dentro da área desenhada")
        if crit:
            out.append("   " + " · ".join(crit))
    return out

def build_status_message(s, dl, alarms=None):
    """Mensagem de status (heartbeat): confirma que o run aconteceu, COMO o CSV foi
    baixado (método/arquivo/tamanho), o que o alarme achou — inclusive quando o
    resultado é 'nada novo' — e QUAIS são os parâmetros do alarme. É o que dá a você
    a visão clara via WhatsApp."""
    run = s.get('lastRun') or ''
    L = [f"🤖 *Leilão PB — status do run* · {run}"]
    if dl and dl.get('ok') and dl.get('fresh'):
        metodo = {'Z': 'Zyte (Método Z)', 'D': 'curl direto (Método D)'}.get(
            dl.get('method'), str(dl.get('method')))
        L.append("✅ Rodou e baixou planilha NOVA")
        L.append(f"📥 via {metodo}")
        L.append(f"   {dl.get('csv')} · {_fmt_kb(dl.get('bytes'))}")
    elif dl is not None and not dl.get('fresh'):
        L.append("⚠️ Rodou, mas NÃO baixou planilha nova hoje")
        L.append(f"📥 download falhou (Zyte + curl direto) — usei o último CSV bom:")
        L.append(f"   {s.get('csv')}")
        L.append("   ⚠️ confira o saldo da Zyte e os logs do GitHub Actions")
    else:
        L.append("✅ Rodou")
        L.append(f"📥 CSV usado: {s.get('csv')}")
    L.append(f"🏙️ João Pessoa: {s.get('total')} imóveis · {s.get('new')} novo(s) desde a baseline")
    mn = s.get('matchedNew') or 0
    m = s.get('matched') or 0
    if mn > 0:
        L.append(f"🔔 Alarme: {m} no filtro · {mn} NOVO(S) → alerta enviado ✅")
    else:
        L.append(f"🔔 Alarme: {m} no filtro · 0 novos → nada a avisar 👍")
    # Uso da Zyte (7 dias) — só aparece se baixar_csv.sh conseguiu consultar a Stats API.
    z = (dl or {}).get('zyte') if isinstance(dl, dict) else None
    if z:
        pct = z.get('successPct')
        pcts = f"{pct}% ok" if pct is not None else "—"
        L.append(f"💳 Zyte (7d): {z.get('reqs7d')} req · {pcts} · ~US$ {z.get('costUsd7d')}")
    flt = format_alarm_filters(alarms)
    if flt:
        L.append("")
        L.extend(flt)
    return "\n".join(L)

def status_signature(s, dl):
    """Assinatura ESTÁVEL do quadro do run (sem timestamp nem nome do CSV), para o
    heartbeat sair 1x/dia e só repetir se algo mudar (download falhou↔ok, ou surgiu
    imóvel novo no alarme). Reruns idênticos no mesmo dia geram a mesma chave e o
    sender (idempotente) não reenvia."""
    sig = {
        'ok': bool(dl and dl.get('ok')),
        'fresh': bool(dl and dl.get('fresh')),
        'method': (dl or {}).get('method'),
        'matchedNew': s.get('matchedNew') or 0,
    }
    return hashlib.md5(json.dumps(sig, sort_keys=True).encode('utf-8')).hexdigest()[:8]

def add_status_messages(outbox, s, dl, alarms):
    """Acrescenta a mensagem de status ao outbox, para os MESMOS destinatários dos
    alarmes habilitados. Chave = data + assinatura do quadro ⇒ 1x/dia, reenvia só
    quando o quadro muda."""
    today = outbox.get('date')
    sig = status_signature(s, dl)
    body = build_status_message(s, dl, alarms)
    recips = []
    for a in alarms:
        if not a.get('enabled'):
            continue
        for x in (a.get('recipients') or []):
            x = str(x).strip()
            if x and x not in recips:
                recips.append(x)
    for to in recips:
        outbox['messages'].append({
            'key': f"{today}:status:{to}:{sig}", 'to': to, 'body': body,
            'alarmId': 'status', 'alarmName': 'Status do run', 'newCount': 0,
        })
    return outbox

# ----------------------------- state -----------------------------
def load_state():
    if os.path.exists(STATE):
        try:
            with open(STATE, encoding='utf-8') as f:
                s = json.load(f)
        except Exception:
            s = {}
    else:
        s = {}
    s.setdefault('alarms', [])
    s.setdefault('seen', [])
    s.setdefault('seenMeta', {'at': None})
    # accept either 'geocache' or dashboard's 'geoCache'
    s['geocache'] = s.get('geocache') or s.get('geoCache') or {}
    s.setdefault('runs', [])
    s.setdefault('lastIds', [])
    return s

def save_state(s):
    s2 = {k: v for k, v in s.items() if k != 'geoCache'}
    with open(STATE, 'w', encoding='utf-8') as f:
        json.dump(s2, f, ensure_ascii=False, indent=1)

# ----------------------------- build / overlay / render -----------------------------
def overlay_geocache(records, geocache):
    n = 0
    for r in records:
        c = geocache.get(r['id'])
        if c and c.get('lat') is not None:
            r['lat'] = round(float(c['lat']), 6)
            r['lon'] = round(float(c['lon']), 6)
            r['prec'] = c.get('prec', 'endereco')
            if c.get('cep'): r['cep'] = c['cep']
            n += 1
    return n

def render_dashboard(records, meta):
    if not os.path.exists(TEMPLATE):
        return False
    with open(TEMPLATE, encoding='utf-8') as f:
        tpl = f.read()
    data = json.dumps({'meta': meta, 'records': records}, ensure_ascii=False).replace('</', '<\\/')
    with open(DASHBOARD, 'w', encoding='utf-8') as f:
        f.write(tpl.replace('__DATA__', data))
    return True

def build(write_queue=False):
    state = load_state()
    src = find_csv()
    if not src:
        print(json.dumps({'error': "nenhum CSV encontrado (coloque Lista_imoveis_PB*.csv em 'planilhas leilao', ou em Downloads)"}))
        sys.exit(2)
    src = archive_csv(src)   # CSV passa a viver em 'planilhas leilao'
    records = score_records(parse_csv(src))
    validated = overlay_geocache(records, state['geocache'])

    seen = set(state['seen'])
    alarms = state['alarms']
    new_ids = [r['id'] for r in records if r['id'] not in seen]
    matched = [r for r in records if matches_any(r, alarms)]
    matched_new = [r for r in matched if r['id'] not in seen]

    # fila de refinamento de endereço: pré-filtrada por bairro (nomeados ∪ derivados
    # da área de cada alarme), antes de gastar esforço validando endereços no Maps.
    # Coords pré-refinamento são aproximadas, então filtrar por bairro (exato no CSV)
    # é mais confiável que testar a área ponto-a-ponto aqui.
    queue = []
    for r in records:
        if not wants_refinement(r, alarms, records):
            continue
        c = state['geocache'].get(r['id'])
        if not (c and c.get('prec') == 'endereco'):
            queue.append({'id': r['id'], 'query': maps_query(r),
                          'cidade': r['cidade'], 'bairro': r['bairro'],
                          'endereco': r['endereco'], 'link': r['link'],
                          'score': r['score'], 'desconto': r['desconto']})

    now = datetime.datetime.now().strftime('%d/%m/%Y %H:%M')
    meta = {
        'source': os.path.basename(src),
        'count': len(records),
        'cities': len(set(r['cidade'] for r in records)),
        'lastRun': now,
        'newCount': len(new_ids),
        'newIds': new_ids,
        'matchedCount': len(matched),
        'matchedNewCount': len(matched_new),
        'validatedCount': validated,
        'pendingValidation': len(queue),
        'alarms': alarms,
        'seenBaseline': list(seen),
        'seenMeta': state['seenMeta'],
        'baselineSet': bool(seen),
    }
    with open(OUT_JSON, 'w', encoding='utf-8') as f:
        json.dump({'meta': meta, 'records': records}, f, ensure_ascii=False)
    if write_queue:
        with open(QUEUE, 'w', encoding='utf-8') as f:
            json.dump(queue, f, ensure_ascii=False, indent=1)
    # WhatsApp outbox: mensagens prontas para o sender nativo.
    # Inclui (a) alertas de imóveis novos por alarme e (b) o HEARTBEAT de status do
    # run (sempre presente, mesmo sem novidade — é a confirmação de que rodou).
    alarms_r = alarms_with_recipients(alarms)
    dl = load_download_status()
    outbox = build_outbox(records, alarms_r, seen)
    status_summary = {
        'lastRun': now, 'csv': os.path.basename(src), 'total': len(records),
        'new': len(new_ids), 'matched': len(matched), 'matchedNew': len(matched_new),
    }
    add_status_messages(outbox, status_summary, dl, alarms_r)
    with open(OUTBOX, 'w', encoding='utf-8') as f:
        json.dump(outbox, f, ensure_ascii=False, indent=1)
    render_dashboard(records, meta)

    state['lastIds'] = [r['id'] for r in records]
    save_state(state)

    summary = {
        'csv': os.path.basename(src), 'total': len(records),
        'new': len(new_ids), 'matched': len(matched),
        'matchedNew': len(matched_new), 'toValidate': len(queue),
        'alreadyValidated': validated, 'baselineSet': bool(seen),
        'whatsappQueued': len(outbox['messages']),
        'lastRun': now,
        'topNew': [
            {'id': r['id'], 'score': r['score'], 'desconto': r['desconto'],
             'preco': r['preco'], 'cidade': r['cidade'], 'bairro': r['bairro'],
             'tipo': r['tipo'], 'link': r['link']}
            for r in sorted(matched_new, key=lambda r: -(r['score'] or 0))[:15]
        ],
    }
    with open(SUMMARY, 'w', encoding='utf-8') as f:
        json.dump(summary, f, ensure_ascii=False, indent=2)
    return summary

# ----------------------------- subcommands -----------------------------
def cmd_prepare():
    print(json.dumps(build(write_queue=True), ensure_ascii=False, indent=2))

def cmd_merge():
    print(json.dumps(build(write_queue=False), ensure_ascii=False, indent=2))

def cmd_add_coord(args):
    if len(args) < 3:
        print('usage: add-coord ID LAT LON [CEP] [PREC]'); sys.exit(1)
    rid, lat, lon = args[0], float(args[1]), float(args[2])
    cep = args[3] if len(args) > 3 else None
    prec = args[4] if len(args) > 4 else 'endereco'
    state = load_state()
    state['geocache'][rid] = {'lat': lat, 'lon': lon, 'prec': prec, 'cep': cep,
                              'ts': datetime.datetime.now().isoformat()}
    save_state(state)
    print(json.dumps({'ok': True, 'id': rid, 'lat': lat, 'lon': lon, 'prec': prec, 'cep': cep}))

def cmd_commit():
    state = load_state()
    ids = state.get('lastIds') or []
    if not ids:
        # fall back to current CSV
        src = find_csv()
        if src:
            ids = [r['id'] for r in parse_csv(src)]
    before = len(set(state['seen']))
    seen = set(state['seen']); seen.update(ids)
    state['seen'] = list(seen)
    state['seenMeta'] = {'at': datetime.datetime.now().strftime('%d/%m/%Y %H:%M')}
    summ = {}
    if os.path.exists(SUMMARY):
        with open(SUMMARY, encoding='utf-8') as f: summ = json.load(f)
    state['runs'].append({'at': state['seenMeta']['at'], 'total': len(ids),
                          'new': summ.get('new'), 'matched': summ.get('matched'),
                          'matchedNew': summ.get('matchedNew')})
    state['runs'] = state['runs'][-60:]
    save_state(state)
    print(json.dumps({'ok': True, 'baselineBefore': before, 'baselineAfter': len(seen),
                      'committed': len(ids)}))

def cmd_summary():
    if os.path.exists(SUMMARY):
        print(open(SUMMARY, encoding='utf-8').read())
    else:
        print(json.dumps({'error': 'no summary yet; run prepare first'}))

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'prepare'
    if cmd == 'prepare': cmd_prepare()
    elif cmd == 'merge': cmd_merge()
    elif cmd == 'add-coord': cmd_add_coord(sys.argv[2:])
    elif cmd == 'commit': cmd_commit()
    elif cmd == 'summary': cmd_summary()
    else:
        print('unknown command: ' + cmd); sys.exit(1)

if __name__ == '__main__':
    main()
