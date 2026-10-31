#!/bin/bash
# savant_seed.sh - Automatic Homes
# Saca la asignacion ACTUAL de IDs del bridge Savant<->HA (version < 1.1.82)
# y la guarda como semilla en la carpeta config de HA, ANTES de actualizar a 1.1.82.
# Uso (en Terminal & SSH de HA):  bash /config/savant_seed.sh
# No modifica el add-on ni lo reinicia. Solo lee y guarda un archivo.

SEED=/config/savant_entity_ids.json
PORT=8080

echo "== 1. Localizando el add-on =="
SLUG=$(ha apps list --raw-json 2>/dev/null | jq -r '.data.addons[]? , .data.apps[]? | select(.name=="Savant Home Assistant Proxy") | .slug' | head -1)
if [ -z "$SLUG" ]; then
  SLUG=$(ha addons list --raw-json 2>/dev/null | jq -r '.data.addons[] | select(.name=="Savant Home Assistant Proxy") | .slug' | head -1)
fi
[ -z "$SLUG" ] && { echo "ERROR: no encontre el add-on Savant Home Assistant Proxy"; exit 1; }
INFO=$(ha apps info "$SLUG" --raw-json 2>/dev/null || ha addons info "$SLUG" --raw-json)
VER=$(echo "$INFO" | jq -r '.data.version')
STATE=$(echo "$INFO" | jq -r '.data.state')
AUTO=$(echo "$INFO" | jq -r '.data.auto_update')
echo "slug: $SLUG | version: $VER | estado: $STATE | auto_update: $AUTO"

if [ "$STATE" != "started" ]; then
  echo "ERROR: el add-on no esta corriendo. Inicialo y espera que Savant conecte."; exit 1
fi
case "$VER" in 1.1.8[2-9]|1.1.9*|1.[2-9]*)
  echo "Este sitio ya tiene $VER (con persistencia). No hace falta semilla."; exit 0;;
esac
[ "$AUTO" = "true" ] && echo "AVISO: auto_update esta ACTIVO. Desactivalo en la pestana Info del add-on antes de publicar 1.1.82 / actualizar."

echo "== 2. Pidiendo registry_export al bridge =="
HOST=$(ha network info --raw-json | jq -r '[.data.interfaces[] | select(.primary==true) | .ipv4.address[0]][0]' | cut -d/ -f1)
[ -z "$HOST" ] || [ "$HOST" = "null" ] && HOST=127.0.0.1
echo "bridge: $HOST:$PORT"

RAW=$( { printf 'registry_export\n'; sleep 3; } | nc "$HOST" "$PORT" 2>/dev/null | tr -d '\r' | grep -m1 '^registry_json===' )
if [ -z "$RAW" ]; then
  # Respaldo sin nc: /dev/tcp de bash
  RAW=$( exec 3<>/dev/tcp/$HOST/$PORT && printf 'registry_export\n' >&3 && timeout 3 cat <&3 | tr -d '\r' | grep -m1 '^registry_json===' )
fi
[ -z "$RAW" ] && { echo "ERROR: el bridge no respondio a registry_export (version muy vieja o puerto distinto)."; exit 1; }

TMP=$(mktemp)
echo "${RAW#registry_json===}" > "$TMP"
N=$(jq '.entities | length' "$TMP" 2>/dev/null)
if [ -z "$N" ] || [ "$N" = "null" ] || [ "$N" -eq 0 ]; then
  echo "ERROR: el registro vino VACIO o invalido. NO actualices este sitio."
  echo "Puede que Savant no haya conectado desde el ultimo arranque. Revisa y repite."
  rm -f "$TMP"; exit 1
fi

echo "== 3. Asignacion actual ($N entidades) =="
jq -r '.entities[] | [(.id|tostring|("00"+.)[-3:]), .entity_id, (.friendly_name // ""), (if .active==false then "MISSING" else "" end)] | @tsv' "$TMP" | sort | sed 's/\t/   /g'

if [ -f "$SEED" ]; then
  cp "$SEED" "$SEED.bak.$(date +%Y%m%d-%H%M%S)"
  echo "(habia una semilla previa; respaldada como $SEED.bak.*)"
fi
mv "$TMP" "$SEED"
echo
echo "OK: semilla guardada en $SEED"
echo "SIGUIENTE: compara esta lista con el data table de Savant."
echo "  - Si coincide: ha store reload && ha apps update $SLUG"
echo "  - Si NO coincide: el sitio ya se renumero antes; corrige la semilla (o el data table) ANTES de actualizar."
