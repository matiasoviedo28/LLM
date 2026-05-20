#!/usr/bin/env bash
# Valida que el stack Ramon esté 100% operativo.
# Exit 0 = todo OK. Exit 1 = algo falló.

set -euo pipefail

# ─── Colores ──────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; FAILED=1; }
info() { echo -e "  ${YELLOW}→${RESET} $1"; }

FAILED=0

# Leer puertos desde .env si existe, si no usar defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
OLLAMA_PORT=11500
WEBUI_PORT=3500

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source <(grep -E '^(OLLAMA_PORT|WEBUI_PORT|MODEL|BIND_ADDRESS)=' "$ENV_FILE")
fi

MODEL="${MODEL:-gemma3:4b}"
BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════${RESET}"
echo -e "${BOLD}     Healthcheck — Stack Ramon              ${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════${RESET}"
echo ""

# ─── 1. Contenedor ramon-ollama corriendo ─────────────────────────────────
echo -e "${BOLD}[1] Contenedor ramon-ollama${RESET}"
STATUS=$(docker inspect --format='{{.State.Status}}' ramon-ollama 2>/dev/null || echo "not_found")
if [[ "$STATUS" == "running" ]]; then
  ok "ramon-ollama está corriendo"
else
  fail "ramon-ollama no está corriendo (estado: $STATUS)"
fi

# ─── 2. Contenedor ramon-webui corriendo ──────────────────────────────────
echo -e "${BOLD}[2] Contenedor ramon-webui${RESET}"
STATUS=$(docker inspect --format='{{.State.Status}}' ramon-webui 2>/dev/null || echo "not_found")
if [[ "$STATUS" == "running" ]]; then
  ok "ramon-webui está corriendo"
else
  fail "ramon-webui no está corriendo (estado: $STATUS)"
fi

# ─── 3. API de Ollama responde ────────────────────────────────────────────
echo -e "${BOLD}[3] API Ollama en localhost:${OLLAMA_PORT}${RESET}"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:${OLLAMA_PORT}/api/tags" 2>/dev/null || echo "000")
if [[ "$HTTP" == "200" ]]; then
  ok "API Ollama responde HTTP $HTTP"
else
  fail "API Ollama no responde (HTTP $HTTP)"
fi

# ─── 4. Open WebUI responde ───────────────────────────────────────────────
echo -e "${BOLD}[4] Open WebUI en localhost:${WEBUI_PORT}${RESET}"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost:${WEBUI_PORT}" 2>/dev/null || echo "000")
if [[ "$HTTP" == "200" || "$HTTP" == "302" ]]; then
  ok "Open WebUI responde HTTP $HTTP"
else
  fail "Open WebUI no responde (HTTP $HTTP)"
fi

# ─── 5. Modelo disponible en Ollama ──────────────────────────────────────
echo -e "${BOLD}[5] Modelo ${MODEL} disponible${RESET}"
MODEL_LIST=$(curl -s --max-time 5 "http://localhost:${OLLAMA_PORT}/api/tags" 2>/dev/null || echo "{}")
if echo "$MODEL_LIST" | grep -q "\"name\"" && echo "$MODEL_LIST" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = [m['name'] for m in data.get('models', [])]
target = '${MODEL}'
# Aceptar match exacto o con sufijo :latest implícito
found = any(m == target or m.startswith(target.split(':')[0]) for m in models)
sys.exit(0 if found else 1)
" 2>/dev/null; then
  ok "Modelo ${MODEL} está disponible"
else
  info "Modelo ${MODEL} no encontrado — corré: docker exec ramon-ollama ollama pull ${MODEL}"
  # No es fallo fatal, el stack puede estar OK sin modelo descargado aún
fi

# ─── 6. Red ramon-net existe ─────────────────────────────────────────────
echo -e "${BOLD}[6] Red Docker ramon-net${RESET}"
if docker network inspect ramon-net &>/dev/null; then
  ok "Red ramon-net existe"
else
  fail "Red ramon-net no encontrada"
fi

# ─── 7. Binding de puertos correcto ──────────────────────────────────────
echo -e "${BOLD}[7] Binding de puertos (BIND_ADDRESS=${BIND_ADDRESS})${RESET}"
# ss muestra "127.0.0.1:PORT" o "0.0.0.0:PORT" según el binding
OLLAMA_BIND=$(ss -tlnp 2>/dev/null | awk -v port=":${OLLAMA_PORT}" '$4 ~ port {print $4}' | head -1)
WEBUI_BIND=$(ss -tlnp 2>/dev/null | awk -v port=":${WEBUI_PORT}" '$4 ~ port {print $4}' | head -1)

OLLAMA_ACTUAL="${OLLAMA_BIND%%:*}"
WEBUI_ACTUAL="${WEBUI_BIND%%:*}"

# Función que evalúa un servicio
check_bind() {
  local svc="$1" actual="$2"
  if [[ -z "$actual" ]]; then
    fail "$svc: puerto no encontrado en ss (¿el contenedor levantó?)"
    return
  fi
  if [[ "$actual" == "$BIND_ADDRESS" ]]; then
    ok "$svc escuchando en ${actual} ✓"
  elif [[ "$BIND_ADDRESS" == "0.0.0.0" && "$actual" == "0.0.0.0" ]]; then
    ok "$svc escuchando en ${actual} ✓"
  else
    fail "$svc: esperaba ${BIND_ADDRESS}, encontró ${actual}"
  fi
}

check_bind "Ollama (${OLLAMA_PORT})" "$OLLAMA_ACTUAL"
check_bind "WebUI  (${WEBUI_PORT})"  "$WEBUI_ACTUAL"

if [[ "$BIND_ADDRESS" == "0.0.0.0" ]]; then
  echo -e "  ${YELLOW}⚠  ADVERTENCIA: stack expuesto a la red local${RESET}"
  echo -e "  ${YELLOW}   Cualquier dispositivo en tu red puede acceder a Open WebUI y Ollama.${RESET}"
  echo -e "  ${YELLOW}   Nunca uses 0.0.0.0 en redes públicas (cafés, coworkings, aeropuertos).${RESET}"
  echo -e "  ${YELLOW}   Considerá activar WEBUI_AUTH=True si vas a compartirlo.${RESET}"
fi

# ─── Resultado final ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════${RESET}"
if [[ "$FAILED" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}  RESULTADO: TODO OK ✓${RESET}"
  echo ""
  echo -e "  Open WebUI: ${BOLD}http://localhost:${WEBUI_PORT}${RESET}"
  echo -e "  Ollama API: ${BOLD}http://localhost:${OLLAMA_PORT}${RESET}"
else
  echo -e "${RED}${BOLD}  RESULTADO: FALLÓ — revisá los errores arriba ✗${RESET}"
fi
echo -e "${BOLD}═══════════════════════════════════════════${RESET}"
echo ""

exit "$FAILED"
