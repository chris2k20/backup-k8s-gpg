#!/usr/bin/env bash
#
# backup-k8s-gpg.sh
#
# Backup / View Tool für Kubernetes ConfigMaps & Secrets.
#
# MODI:
#   Backup (Default): Ressourcen holen, normalisieren, verschlüsselt synchronisieren.
#   View (--view):    Lokale verschlüsselte Dateien entschlüsseln & anzeigen.
#
# DATEIFORMAT:
#   configmap-<name>.yml.gpg
#   secret-<name>.yml.gpg
#
# USAGE (Backup):
#   backup-k8s-gpg.sh -n <namespace> -o <output_dir> -r <recipient>
#   backup-k8s-gpg.sh -n <namespace> -o <output_dir> -s
#
# USAGE (View):
#   backup-k8s-gpg.sh --view [pattern] -o <output_dir> [--redact] [--no-pager]
#
# Beispiele:
#   Backup asymmetrisch: ./backup-k8s-gpg.sh -n prod -o backup/prod -r KEYID
#   Backup symmetrisch:  ./backup-k8s-gpg.sh -n prod -o backup/prod -s
#   Anzeigen alles:      ./backup-k8s-gpg.sh --view -o backup/prod
#   Anzeigen gefiltert:  ./backup-k8s-gpg.sh --view postgres -o backup/prod
#   Reduziert + no pager:./backup-k8s-gpg.sh --view --redact --no-pager -o backup/prod
#
set -euo pipefail

VERSION="1.2.0"

# MODE Variablen
mode="backup"
view_pattern=""
redact=0
use_pager=1

namespace=""
output_dir=""
declare -a recipients=()
declare -a ignore_patterns=()
symmetric=0
prune=0
quiet=0
kube_context=""
kubeconfig=""

log() { [[ $quiet -eq 0 ]] && printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
backup-k8s-gpg.sh - Backup & Anzeige (View) von Kubernetes Secrets/ConfigMaps.

MODI:
  (Default) Backup-Modus:
    -n, --namespace <ns>   Namespace
    -o, --output    <dir>  Zielverzeichnis
    -r, --recipient <id>   GPG Empfänger (mehrfach möglich)
    -s, --symmetric        Symmetrische Verschlüsselung
        --prune            Entfernt lokale verwaiste Dateien
    -i, --ignore   <pat>   Ignoriere Ressourcen nach Muster (mehrfach möglich)
                           Muster gilt auf "<kind>-<name>", z.B. "configmap-kube-root-ca"
        --context <ctx>    kubectl context
        --kubeconfig <pfad>

  View-Modus:
    --view [pattern]       Entschlüsselt & zeigt Dateien aus -o
                           pattern = Substring (optional). Ohne => alle.
    --redact               Secret-Werte maskieren
    --no-pager             Kein less, direkt STDOUT

Gemeinsame Optionen:
  -q, --quiet              Weniger Ausgabe
  -h, --help               Hilfe
      --version            Version ausgeben

Beispiele:
  Backup:     ./backup-k8s-gpg.sh -n prod -o out -r KEYID
  View alle:  ./backup-k8s-gpg.sh --view -o out
  View filt.: ./backup-k8s-gpg.sh --view postgres -o out
  Redact:     ./backup-k8s-gpg.sh --view --redact -o out

WARNUNG: View zeigt Secrets im Klartext (sofern nicht --redact).
EOF
  exit 0
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --view)
      mode="view"
      # optional pattern (falls nächstes Argument nicht Option ist)
      if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then
        view_pattern="$2"
        shift 2
      else
        shift
      fi
      ;;
    --redact) redact=1; shift;;
    --no-pager) use_pager=0; shift;;
    -n|--namespace) namespace="$2"; shift 2;;
    -o|--output) output_dir="$2"; shift 2;;
    -r|--recipient) recipients+=("$2"); shift 2;;
    -i|--ignore) ignore_patterns+=("$2"); shift 2;;
    -s|--symmetric) symmetric=1; shift;;
    --prune) prune=1; shift;;
    --context) kube_context="$2"; shift 2;;
    --kubeconfig) kubeconfig="$2"; shift 2;;
    -q|--quiet) quiet=1; shift;;
    -h|--help) usage;;
    --version) echo "$VERSION"; exit 0;;
    *) die "Unbekanntes Argument: $1";;
  esac
done

# MODE: VIEW
if [[ "$mode" == "view" ]]; then
  [[ -z "$output_dir" ]] && die "Für --view ist -o/--output erforderlich."
  command -v gpg >/dev/null 2>&1 || die "gpg wird für View benötigt."
  [[ -d "$output_dir" ]] || die "Output-Verzeichnis existiert nicht: $output_dir"

  pattern="${view_pattern:-}"
  shopt -s nullglob
  # Substring-Match: *pattern*
  if [[ -n "$pattern" ]]; then
    files=( "${output_dir}"/*"${pattern}"*.yml.gpg )
  else
    files=( "${output_dir}"/*.yml.gpg )
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    die "Keine Dateien gefunden für Pattern '${pattern}'."
  fi

  tmp_agg=$(mktemp)
  trap 'rm -f "$tmp_agg"' EXIT

  for f in "${files[@]}"; do
    base=$(basename "$f")
    {
      echo "===== ${base} ====="
      if gpg -d "$f" 2>/dev/null > /dev/null; then
        :
      fi
      if [[ $redact -eq 1 && "$base" == secret-* ]]; then
        # Redact: Secret Daten maskieren
          # Entschlüsseln -> verarbeiten Zeile für Zeile
        gpg -d "$f" 2>/dev/null \
          | awk -v indata=0 '
              /^data:[[:space:]]*$/ { print; indata=1; next }
              indata==1 && /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*/ {
                sub(/:.*/, ": REDACTED_BASE64")
                print
                next
              }
              /^[^[:space:]]/ { indata=0; print; next }
              { print }
            '
      else
        # Einfach ausgeben
        if ! gpg -d "$f" 2>/dev/null; then
          echo "# FEHLER: Datei konnte nicht entschlüsselt werden."
        fi
      fi
      echo
    } >> "$tmp_agg"
  done

  if [[ $use_pager -eq 1 && -t 1 && -t 0 ]] && command -v less >/dev/null 2>&1; then
    less -R "$tmp_agg"
  else
    cat "$tmp_agg"
  fi
  exit 0
fi

# MODE: BACKUP
[[ -z "$namespace" ]] && die "Namespace erforderlich (-n) im Backup-Modus."
[[ -z "$output_dir" ]] && die "Output-Verzeichnis erforderlich (-o) im Backup-Modus."
if [[ $symmetric -eq 1 && ${#recipients[@]} -gt 0 ]]; then
  die "Nicht gleichzeitig symmetrisch (-s) und Empfänger (-r) nutzen."
fi
if [[ $symmetric -eq 0 && ${#recipients[@]} -eq 0 ]]; then
  die "Mindestens Empfänger (-r) oder -s angeben."
fi

for bin in kubectl jq gpg; do
  command -v "$bin" >/dev/null 2>&1 || die "Benötigtes Tool fehlt: $bin"
done

# yq optional
YQ_MODE="none"
if command -v yq >/dev/null 2>&1; then
  if yq --version 2>&1 | grep -qi 'mikefarah'; then
    YQ_MODE="mikefarah"
  else
    YQ_MODE="python"
  fi
else
  log "Hinweis: yq nicht gefunden – es wird JSON (als YAML-Datei) geschrieben."
fi

mkdir -p "$output_dir"
[[ -d "$output_dir" ]] || die "Kann Output-Verzeichnis nicht anlegen: $output_dir"

KCTL=(kubectl)
[[ -n "$kube_context" ]] && KCTL+=(--context "$kube_context")
[[ -n "$kubeconfig" ]] && KCTL+=(--kubeconfig "$kubeconfig")

"${KCTL[@]}" get ns "$namespace" >/dev/null 2>&1 || die "Namespace nicht erreichbar: $namespace"

log "Hole ConfigMaps..."
mapfile -t configmaps < <("${KCTL[@]}" get configmaps -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)
log "Hole Secrets..."
mapfile -t secrets < <("${KCTL[@]}" get secrets -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)

normalize_resource() {
  local kind="$1" name="$2"
  local json
  if ! json=$("${KCTL[@]}" get "$kind" "$name" -n "$namespace" -o json 2>/dev/null); then
    return 1
  fi
  json=$(printf '%s' "$json" | jq 'del(
      .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
      .metadata.creationTimestamp,
      .metadata.resourceVersion,
      .metadata.uid,
      .metadata.managedFields,
      .metadata.generation,
      .metadata.selfLink,
      .metadata.ownerReferences,
      .metadata.annotations."deployment.kubernetes.io/revision",
      .status
    )' | jq -S '.')
  case "$YQ_MODE" in
    mikefarah) printf '%s' "$json" | yq -P ;;
    python)    printf '%s' "$json" | yq -y '.' ;;
    none)
      echo "# WARN: Keine yq Installation – Inhalt ist JSON"
      printf '%s\n' "$json"
      ;;
  esac
}

encrypt_and_write() {
  local infile="$1" outfile="$2"
  local tmp_enc="${outfile}.tmp"
  if [[ $symmetric -eq 1 ]]; then
    gpg --quiet --batch --yes --symmetric --cipher-algo AES256 -o "$tmp_enc" "$infile"
  else
    local gargs=()
    for r in "${recipients[@]}"; do gargs+=(-r "$r"); done
    gpg --quiet --batch --yes --encrypt "${gargs[@]}" -o "$tmp_enc" "$infile"
  fi
  mv "$tmp_enc" "$outfile"
}

# returns 0 (true) if the combined key ("<kind>-<name>") should be ignored
should_ignore() {
  local key="$1"
  for pat in "${ignore_patterns[@]:-}"; do
    [[ -n "$pat" ]] || continue
    if [[ "$key" == *"$pat"* ]]; then
      return 0
    fi
  done
  return 1
}

process_resource() {
  local kind="$1" name="$2"
  local lower_kind
  lower_kind=$(echo "$kind" | tr '[:upper:]' '[:lower:]')
  local outfile="${output_dir}/${lower_kind}-${name}.yml.gpg"
  local tmp_plain tmp_dec
  tmp_plain=$(mktemp); tmp_dec=$(mktemp)
  local changed=0

  if ! normalize_resource "$kind" "$name" > "$tmp_plain"; then
    log "Fehler beim Lesen ${kind}/${name} – überspringe."
    rm -f "$tmp_plain" "$tmp_dec"
    return
  fi
  echo >> "$tmp_plain"

  if [[ -f "$outfile" ]]; then
    if gpg --quiet -d "$outfile" > "$tmp_dec" 2>/dev/null; then
      if ! diff -q "$tmp_plain" "$tmp_dec" >/dev/null 2>&1; then
        changed=1
      fi
    else
      log "Bestehende Datei nicht entschlüsselbar – schreibe neu."
      changed=1
    fi
  else
    changed=1
  fi

  if [[ $changed -eq 1 ]]; then
    log "Aktualisiere ${lower_kind}/${name} -> $(basename "$outfile")"
    encrypt_and_write "$tmp_plain" "$outfile"
  else
    log "Unverändert ${lower_kind}/${name}"
  fi

  rm -f "$tmp_plain" "$tmp_dec"
}

declare -A should_exist=()
for cm in "${configmaps[@]}"; do
  [[ -n "$cm" ]] || continue
  if should_ignore "configmap-${cm}"; then
    log "Ignoriere configmap/${cm}"
    continue
  fi
  should_exist["configmap-${cm}.yml.gpg"]=1
  process_resource "ConfigMap" "$cm"
done
for sec in "${secrets[@]}"; do
  [[ -n "$sec" ]] || continue
  if [[ "$sec" =~ ^default-token- ]] || [[ "$sec" =~ -token- ]]; then
    log "Ignoriere secret/${sec} (ServiceAccount-Token)"
    continue
  fi
  if should_ignore "secret-${sec}"; then
    log "Ignoriere secret/${sec}"
    continue
  fi
  should_exist["secret-${sec}.yml.gpg"]=1
  process_resource "Secret" "$sec"
done

if [[ $prune -eq 1 ]]; then
  log "Prune verwaister Dateien..."
  shopt -s nullglob
  for f in "${output_dir}"/*.yml.gpg; do
    base=$(basename "$f")
    if [[ -z "${should_exist[$base]:-}" ]]; then
      log "Lösche verwaist: $base"
      rm -f "$f"
    fi
  done
fi

log "Fertig. Output: $output_dir"
exit 0