<p align="center">
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/python-3.8+-blue.svg" alt="Python">
</p>

# 📜 Over Scripts

Coleção de scripts úteis do dia a dia — automação, scraping, bypass e utilitários diversos.

---

## Índice

- [scraper.py — Web Scraper Genérico](#scraperpy--web-scraper-genérico)
- [bypass.py — Bypass Tester](#bypasspy--bypass-tester)
- [watcher.sh — Directory Watcher](#watchersh--directory-watcher)
- [network_check.sh — Network Connectivity Check](#network_checksh--network-connectivity-check)
- [Instalação](#instalação)
- [Requisitos](#requisitos)

---

## scraper.py — Web Scraper Genérico

Extrai **títulos**, **links** e **texto visível** de uma página web.

- Usa `requests` + `BeautifulSoup` como backend primário.
- Fallback automático para **regex** se o BeautifulSoup não estiver instalado.
- Suporta `--force-regex` para forçar o uso do fallback.
- Saída formatada em JSON no stdout ou em arquivo via `--output`.

### Uso

```bash
# Scrape básico (saída no terminal)
python scraper.py https://example.com

# Salvar resultado em JSON
python scraper.py https://example.com --output resultado.json

# User-Agent personalizado + timeout maior
python scraper.py https://httpbin.org/html \
    --user-agent "Mozilla/5.0 (X11; Linux x86_64)" \
    --timeout 15

# Forçar fallback regex (sem BeautifulSoup)
python scraper.py https://example.com --force-regex

# Modo verbose para debug
python scraper.py https://example.com --verbose
```

### Exemplo de saída

```json
{
  "url": "https://example.com",
  "status": 200,
  "title": "Example Domain",
  "links": [
    {"url": "https://www.iana.org/domains/example", "text": "More information..."}
  ],
  "text": "Example Domain\nThis domain is for use in illustrative examples..."
}
```

---

## bypass.py — Bypass Tester

Testa técnicas de bypass de segurança:

1. **Path Traversal** — dezenas de payloads ( `../`, `..\\`, `%2e%2e%2f`, double encoding, overlong UTF-8, etc.)
2. **Basic Auth Brute-force** — testa combinações de usuário/senha com wordlists embutidas ou customizadas.
3. **Threaded** — requisições concorrentes para velocidade.

### Uso

```bash
# Teste completo (traversal + auth)
python bypass.py https://example.com

# Apenas path traversal, profundidade 6
python bypass.py https://example.com/files/ \
    --traversal-only --depth 6

# Apenas auth com wordlists customizadas
python bypass.py https://example.com/admin \
    --auth-only \
    --auth-list users.txt \
    --pass-list passwords.txt \
    --threads 20

# Alvo específico de traversal (e.g. windows config)
python bypass.py https://example.com/ \
    --traversal-target "Windows/System32/drivers/etc/hosts"

# Timeout mais curto, modo silencioso
python bypass.py https://example.com --timeout 3 --verbose
```

### Payloads de traversal incluídos

`../`, `..\\`, `....//`, `....\\\\`, `..;/`, `.././`, `..%252f`, `%2e%2e/`, `%2e%2e%2f`, `..%00/`, `..%00\\`, `%c0%ae%c0%ae/`, `%252e%252e%252f`, `..%5c`, `..%252f`, `/../`, `/..%252f/`, `....//....//`, `..\\/`, `..\\..\\`, e variações com profundidade configurável.

---

## watcher.sh — Directory Watcher

Monitora um diretório em tempo real e loga todas as mudanças (criação, deleção, modificação, movimentação).

- **Backend primário:** `inotifywait` (Linux nativo) — reativo, sem polling.
- **Fallback:** polling via `stat` quando inotifywait não está disponível (macOS, WSL antigo).
- Suporta filtro `--exclude` com regex, log em arquivo, e monitoramento recursivo.

### Uso

```bash
# Monitorar diretório atual
./watcher.sh /var/log

# Monitorar recursivamente, log em arquivo
./watcher.sh ~/projects --recursive --log /tmp/watcher.log

# Excluir arquivos .tmp e .git
./watcher.sh /data --recursive --exclude '\.(tmp|git)$'

# Polling explícito (sem inotify), intervalo 5s
./watcher.sh /mnt/nfs --poll-interval 5

# Apenas eventos de criação e deleção
./watcher.sh /uploads --events create,delete
```

### Formato do log

```
[2026-06-20 00:15:30] [CHANGE] create | /home/user/projects/novo_arquivo.txt
[2026-06-20 00:15:35] [CHANGE] modify | /home/user/projects/arquivo_modificado.py
[2026-06-20 00:15:40] [CHANGE] delete | /home/user/projects/arquivo_removido.log
```

---

## network_check.sh — Network Connectivity Check

Testa conectividade de rede contra uma lista de hosts: **DNS resolution**, **ICMP ping** e **TCP port check**.

- Usa `dig`/`host` para DNS, `ping` para ICMP, e `/dev/tcp`/`nc`/`nmap` para TCP.
- Suporta arquivo de hosts customizado (formato `host:porta` por linha).
- Saída em tabela ou JSON.

### Uso

```bash
# Testar hosts padrão (google.com, github.com, cloudflare.com, 8.8.8.8, 1.1.1.1)
./network_check.sh

# Usar lista customizada
echo "api.example.com:443" > hosts.txt
echo "db.internal:5432" >> hosts.txt
./network_check.sh --hosts hosts.txt

# Saída JSON para integrar com outras ferramentas
./network_check.sh --hosts hosts.txt --json-output

# Apenas ping, sem teste de porta
./network_check.sh --ping-only

# Timeout TCP customizado
./network_check.sh --tcp-timeout 5

# Modo detalhado
./network_check.sh --verbose
```

### Exemplo de saída (tabela)

```
HOST                      PORT   DNS              PING     RTT(ms)  TCP
----                      ----   ---              ----     -------  ---
google.com                443    ok/142.250.80.46  ok       12.3     ok
github.com                443    ok/140.82.121.3   ok       8.1      ok
cloudflare.com            443    ok/104.16.124.96  ok       3.2      ok
8.8.8.8                   53     ok/8.8.8.8        ok       2.1      ok
1.1.1.1                   443    ok/1.1.1.1        ok       1.8      ok
```

### Exemplo de saída (JSON)

```json
[
  {"host":"google.com","port":"443","dns":"ok","ip":"142.250.80.46","ping":"ok","rtt":"12.3","tcp":"ok"},
  {"host":"github.com","port":"443","dns":"ok","ip":"140.82.121.3","ping":"ok","rtt":"8.1","tcp":"ok"}
]
```

---

## Instalação

```bash
git clone https://github.com/overlord111111/over-scripts.git
cd over-scripts

# Dependências Python (para scraper.py e bypass.py)
pip install -r requirements.txt
```

Os scripts bash (`.sh`) não requerem instalação — apenas permissão de execução:

```bash
chmod +x *.sh
```

## Requisitos

### Python

| Pacote          | Versão mínima | Instalação               |
|-----------------|---------------|--------------------------|
| `requests`      | 2.31.0        | `pip install requests`   |
| `beautifulsoup4`| 4.12.0        | `pip install beautifulsoup4` |

> **Nota:** `scraper.py` funciona **sem** BeautifulSoup usando fallback regex. `bypass.py` depende de `requests`.

### Bash

- `watcher.sh`: `inotifywait` (opcional, do pacote `inotify-tools`)
- `network_check.sh`: `dig`/`host`, `ping`, `nc`/`nmap` (cada ferramenta é opcional — o script tenta todas as disponíveis)

---

| Script | Descrição |
|--------|-----------|
| `scraper.py` | Web scraping genérico com fallback regex |
| `bypass.py` | Bypass de path traversal e autenticação |
| `watcher.sh` | Monitoramento de diretório em tempo real |
| `network_check.sh` | Teste de conectividade DNS/ping/TCP |

Feito com ☕ e 🎯
