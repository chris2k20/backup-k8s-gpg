#!/usr/bin/env bash
#
# backup-k8s-gpg.sh
#
# Backup / View tool for Kubernetes ConfigMaps & Secrets.
#
# MODES:
#   Backup (default): fetch resources, normalize, and sync encrypted files.
#   View (--view):    decrypt and display local encrypted files.
#
# FILE FORMAT:
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
# Examples:
#   Asymmetric backup: ./backup-k8s-gpg.sh -n prod -o backup/prod -r KEYID
#   Symmetric backup:  ./backup-k8s-gpg.sh -n prod -o backup/prod -s
#   View all:          ./backup-k8s-gpg.sh --view -o backup/prod
#   View filtered:     ./backup-k8s-gpg.sh --view postgres -o backup/prod
#   Redacted + no pager: ./backup-k8s-gpg.sh --view --redact --no-pager -o backup/prod
#
set -euo pipefail

VERSION="1.2.0"

# MODE variables
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
backup-k8s-gpg.sh - Backup and View for Kubernetes Secrets/ConfigMaps.

MODES:
  (Default) Backup mode:
    -n, --namespace <ns>   Namespace
    -o, --output    <dir>  Output directory
    -r, --recipient <id>   GPG recipient (repeatable)
    -s, --symmetric        Symmetric encryption (AES256)
        --prune            Remove local orphaned files
    -i, --ignore   <pat>   Ignore resources (repeatable)
                           Matches on "<kind>-<name>", e.g. "configmap-kube-root-ca"
        --context <ctx>    kubectl context
        --kubeconfig <path>

  View mode:
    --view [pattern]       Decrypts & displays files from -o
                           pattern = substring (optional). Empty => all.
    --redact               Mask secret values
    --no-pager             No less, print to STDOUT

Common options:
  -q, --quiet              Less output
  -h, --help               Help
      --version            Print version and exit

Examples:
  Backup:     ./backup-k8s-gpg.sh -n prod -o out -r KEYID
  View all:   ./backup-k8s-gpg.sh --view -o out
  View filt.: ./backup-k8s-gpg.sh --view postgres -o out
  Redact:     ./backup-k8s-gpg.sh --view --redact -o out

WARNING: View prints secrets in plaintext unless --redact is used.
EOF
  exit 0
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --view)
      mode="view"
      # optional pattern (if the next argument is not an option)
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
    *) die "Unknown argument: $1";;
  esac
done

# MODE: VIEW
if [[ "$mode" == "view" ]]; then
  [[ -z "$output_dir" ]] && die "For --view, -o/--output is required."
  command -v gpg >/dev/null 2>&1 || die "gpg is required for view mode."
  [[ -d "$output_dir" ]] || die "Output directory does not exist: $output_dir"

  pattern="${view_pattern:-}"
  shopt -s nullglob
  # Substring match: *pattern*
  if [[ -n "$pattern" ]]; then
    files=( "${output_dir}"/*"${pattern}"*.yml.gpg )
  else
    files=( "${output_dir}"/*.yml.gpg )
  fi
  if [[ ${#files[@]} -eq 0 ]]; then
    die "No files found for pattern '${pattern}'."
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
        # Redact: mask secret values
          # Decrypt and process line by line
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
        # Simple output
        if ! gpg -d "$f" 2>/dev/null; then
          echo "# ERROR: File could not be decrypted."
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
[[ -z "$namespace" ]] && die "Namespace is required (-n) in backup mode."
[[ -z "$output_dir" ]] && die "Output directory is required (-o) in backup mode."
if [[ $symmetric -eq 1 && ${#recipients[@]} -gt 0 ]]; then
  die "Do not use both symmetric (-s) and recipients (-r) at the same time."
fi
if [[ $symmetric -eq 0 && ${#recipients[@]} -eq 0 ]]; then
  die "Provide at least one recipient (-r) or use -s for symmetric encryption."
fi

for bin in kubectl jq gpg; do
  command -v "$bin" >/dev/null 2>&1 || die "Required tool missing: $bin"
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
  log "Note: yq not found – will write JSON (in a .yml file)."
fi

mkdir -p "$output_dir"
[[ -d "$output_dir" ]] || die "Cannot create output directory: $output_dir"

KCTL=(kubectl)
[[ -n "$kube_context" ]] && KCTL+=(--context "$kube_context")
[[ -n "$kubeconfig" ]] && KCTL+=(--kubeconfig "$kubeconfig")

"${KCTL[@]}" get ns "$namespace" >/dev/null 2>&1 || die "Namespace not reachable: $namespace"

log "Fetching ConfigMaps..."
mapfile -t configmaps < <("${KCTL[@]}" get configmaps -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)
log "Fetching Secrets..."
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
      echo "# WARN: No yq installation – content is JSON"
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
    log "Error reading ${kind}/${name} – skipping."
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
      log "Existing file cannot be decrypted – writing fresh."
      changed=1
    fi
  else
    changed=1
  fi

  if [[ $changed -eq 1 ]]; then
    log "Updating ${lower_kind}/${name} -> $(basename "$outfile")"
    encrypt_and_write "$tmp_plain" "$outfile"
  else
    log "Unchanged ${lower_kind}/${name}"
  fi

  rm -f "$tmp_plain" "$tmp_dec"
}

declare -A should_exist=()
for cm in "${configmaps[@]}"; do
  [[ -n "$cm" ]] || continue
  if should_ignore "configmap-${cm}"; then
    log "Ignoring configmap/${cm}"
    continue
  fi
  should_exist["configmap-${cm}.yml.gpg"]=1
  process_resource "ConfigMap" "$cm"
done
for sec in "${secrets[@]}"; do
  [[ -n "$sec" ]] || continue
  if [[ "$sec" =~ ^default-token- ]] || [[ "$sec" =~ -token- ]]; then
    log "Ignoring secret/${sec} (ServiceAccount token)"
    continue
  fi
  if should_ignore "secret-${sec}"; then
    log "Ignoring secret/${sec}"
    continue
  fi
  should_exist["secret-${sec}.yml.gpg"]=1
  process_resource "Secret" "$sec"
done

if [[ $prune -eq 1 ]]; then
  log "Pruning orphaned files..."
  shopt -s nullglob
  for f in "${output_dir}"/*.yml.gpg; do
    base=$(basename "$f")
    if [[ -z "${should_exist[$base]:-}" ]]; then
      log "Removing orphan: $base"
      rm -f "$f"
    fi
  done
fi

log "Done. Output: $output_dir"
exit 0