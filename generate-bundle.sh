#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=module_defaults
. "${SCRIPT_DIR}/module_defaults"

# Runtime options
BUNDLE_NAME=""
CLOUD_NAME=""
MODEL_NAME=""
CREATE_MODEL=true
NO_CREATE_MODEL_EXPLICIT=false
DRY_RUN=false
RUN_DEPLOY=false
REPLAY=false
LIST_BUNDLES=false
DEBUG_TRACE=false

CORE_ONLY=false
ENABLE_HA=false
ENABLE_CEPH=false
ENABLE_MICROCEPH=false

UA_TOKEN_VAL="${UA_TOKEN:-}"
LXD_STORAGE=""
PROXY_URL=""
CUSTOM_NO_PROXY=""
DISABLE_PROXY=false
declare -a EXTRA_MODEL_CONFIG=()
declare -a CACHED_ARGS=("$@")
declare -a OVERLAYS=()
declare -a POST_MSGS=()

usage() {
    cat <<EOF
USAGE: $(basename "$0") [OPTIONS]

Generate (and optionally deploy) a Juju overlay bundle for Anbox Cloud
on PS7, PS6, or any Juju 3.x cloud.

OPTIONS:
  -n, --name <name>              Bundle directory name (b/<name>) and Juju model name.
                                 Supports <model>:<cloud> format.
      --no-create-model          Do not create or switch to a Juju model.
      --dry-run                  Generate files only; skip all Juju CLI calls.
      --run                      Execute the generated 'juju deploy' command.
      --replay                   Replay the last generated command for --name.
      --list                     List existing generated bundles under b/.

  --core                         Deploy 'anbox-cloud-core' (no streaming stack).
  -c, --channel <channel>        Anbox Cloud bundle channel (default: ${ANBOX_CHANNEL}).
  -s, --series <series>          Ubuntu series for machines (default: ${ANBOX_SERIES}).
  --ua-token <token>             Ubuntu Pro token (prefer exporting UA_TOKEN env var;
                                 CLI arguments are visible in 'ps').
                                 Requires a full Ubuntu Pro subscription (not Infra-only).

  --lxd-units <N>                Number of LXD worker units (default: ${LXD_UNITS}).
  --lxd-storage <pool,size,cnt>  Juju storage constraint for LXD pool (e.g. cinder,100G,1).
  --lxd-constraints <str>        LXD machine constraints (default: "${LXD_CONSTRAINTS}").
  --control-constraints <str>    Control/streaming constraints (default: "${CONTROL_CONSTRAINTS}").

  --ha                           Enable HA (3x AMS + ams-load-balancer, 3x etcd;
                                 for full bundle also 3x gateway & stream-agent).
  --ceph                         Configure LXD with storage_type=ceph (for external Ceph).
  --microceph                    Implies --ceph and deploys microceph in the same model.

  --proxy <url>                  HTTP/HTTPS proxy URL (auto-detects PS7 if unset).
  --no-proxy <list>              Extra comma-separated no_proxy entries.
  --disable-proxy                Disable PS7/env proxy auto-detection.
  --model-config <k=v>           Additional Juju model-config entry (repeatable).

  --debug                        Enable bash debug tracing (set -x).
  -h, --help                     Show this help message.

EXAMPLES:
  # Dry-run generation for PS7 full Anbox Cloud stack
  UA_TOKEN=<token> ./generate-bundle.sh -n anbox-test --dry-run

  # Deploy full stack on PS7 with 2 LXD nodes and Cinder storage
  UA_TOKEN=<token> ./generate-bundle.sh -n anbox-ps7 --lxd-units 2 --lxd-storage cinder,100G,1 --run

  # Deploy core-only with HA and MicroCeph
  UA_TOKEN=<token> ./generate-bundle.sh -n anbox-core-ha --core --ha --microceph --run
EOF
}

render_overlay() {
    local template="$1"
    local dest="$2"

    # Disable xtrace while handling UA_TOKEN so --debug never logs the secret,
    # and pass values via environment variables so UA_TOKEN never appears in argv/ps.
    local had_xtrace=false
    if [[ $- == *x* ]]; then
        had_xtrace=true
        { set +x; } 2>/dev/null
    fi

    STS_UA_TOKEN="${UA_TOKEN_VAL}" \
    STS_SERIES="${ANBOX_SERIES}" \
    STS_CONTROL_CONSTRAINTS="${CONTROL_CONSTRAINTS}" \
    STS_LXD_CONSTRAINTS="${LXD_CONSTRAINTS}" \
    STS_LXD_UNITS="${LXD_UNITS}" \
    STS_LXD_STORAGE="${LXD_STORAGE}" \
    STS_PROXY_URL="${PROXY_URL}" \
    STS_NO_PROXY="${RESOLVED_NO_PROXY}" \
    STS_HA_AMS_UNITS="${HA_AMS_UNITS}" \
    STS_HA_ETCD_UNITS="${HA_ETCD_UNITS}" \
    STS_HA_STREAMING_UNITS="${HA_STREAMING_UNITS}" \
    STS_MICROCEPH_CHANNEL="${MICROCEPH_CHANNEL}" \
    STS_MICROCEPH_UNITS="${MICROCEPH_UNITS}" \
    STS_MICROCEPH_CONSTRAINTS="${MICROCEPH_CONSTRAINTS}" \
    STS_MICROCEPH_OSD_STORAGE="${MICROCEPH_OSD_STORAGE}" \
    python3 -c '
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
mapping = {
    "__UA_TOKEN__": os.environ["STS_UA_TOKEN"],
    "__SERIES__": os.environ["STS_SERIES"],
    "__CONTROL_CONSTRAINTS__": os.environ["STS_CONTROL_CONSTRAINTS"],
    "__LXD_CONSTRAINTS__": os.environ["STS_LXD_CONSTRAINTS"],
    "__LXD_UNITS__": os.environ["STS_LXD_UNITS"],
    "__LXD_STORAGE__": os.environ["STS_LXD_STORAGE"],
    "__PROXY_URL__": os.environ["STS_PROXY_URL"],
    "__NO_PROXY__": os.environ["STS_NO_PROXY"],
    "__HA_AMS_UNITS__": os.environ["STS_HA_AMS_UNITS"],
    "__HA_ETCD_UNITS__": os.environ["STS_HA_ETCD_UNITS"],
    "__HA_STREAMING_UNITS__": os.environ["STS_HA_STREAMING_UNITS"],
    "__MICROCEPH_CHANNEL__": os.environ["STS_MICROCEPH_CHANNEL"],
    "__MICROCEPH_UNITS__": os.environ["STS_MICROCEPH_UNITS"],
    "__MICROCEPH_CONSTRAINTS__": os.environ["STS_MICROCEPH_CONSTRAINTS"],
    "__MICROCEPH_OSD_STORAGE__": os.environ["STS_MICROCEPH_OSD_STORAGE"],
}
with open(src, "r", encoding="utf-8") as fh:
    text = fh.read()
for key, val in mapping.items():
    # JSON-escape values inside double-quoted YAML scalars to prevent YAML injection
    text = text.replace(f"\"{key}\"", json.dumps(val))
    text = text.replace(key, val)
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(text)
' "${SCRIPT_DIR}/overlays/${template}" "${dest}"

    if ${had_xtrace}; then
        set -x
    fi
}

detect_proxy() {
    if ${DISABLE_PROXY}; then
        PROXY_URL=""
        return
    fi

    if [[ -n "${PROXY_URL}" ]]; then
        return
    fi

    if [[ -n "${http_proxy:-}" ]]; then
        PROXY_URL="${http_proxy}"
        echo "INFO: using proxy from \$http_proxy: ${PROXY_URL}"
    elif timeout 1s nc -vz egress.ps7.internal 3128 &>/dev/null; then
        PROXY_URL="http://egress.ps7.internal:3128"
        echo "INFO: detected PS7 proxy: ${PROXY_URL}"
    fi
}

fetch_and_strip_upstream_bundle() {
    local dest_yaml="$1"
    # Store the temporary download inside BUNDLE_DIR rather than /tmp, because
    # strictly-confined Juju snaps cannot write to the host's /tmp directory.
    local bundle_zip="${BUNDLE_DIR}/${UPSTREAM_BUNDLE}.bundle"
    rm -f "${bundle_zip}"

    echo "INFO: downloading upstream bundle '${UPSTREAM_BUNDLE}' (channel: ${ANBOX_CHANNEL})..."
    if [[ -n "${PROXY_URL}" ]]; then
        http_proxy="${PROXY_URL}" https_proxy="${PROXY_URL}" \
            juju download "${UPSTREAM_BUNDLE}" --channel "${ANBOX_CHANNEL}" --filepath "${bundle_zip}"
    else
        juju download "${UPSTREAM_BUNDLE}" --channel "${ANBOX_CHANNEL}" --filepath "${bundle_zip}"
    fi

    # Extract bundle.yaml and strip hardcoded charm revision pins so Juju
    # resolves the revision matching the target series/base and architecture
    # (upstream 1.29 bundles pin 22.04 revisions despite specifying series: noble).
    python3 -c '
import re, sys, zipfile
zip_path, out_path = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path) as zf:
    content = zf.read("bundle.yaml").decode("utf-8")
stripped = re.sub(r"^[ \t]*revision:[ \t]*\d+[ \t]*\n", "", content, flags=re.MULTILINE)
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(stripped)
' "${bundle_zip}" "${dest_yaml}"

    rm -f "${bundle_zip}"
}

dedupe_csv() {
    python3 -c '
import sys
seen = set()
out = []
for part in sys.argv[1].split(","):
    part = part.strip()
    if part and part not in seen:
        seen.add(part)
        out.append(part)
print(",".join(out))
' "$1"
}

check_proxy_anbox_access() {
    [[ -n "${PROXY_URL}" ]] || return 0
    command -v curl &>/dev/null || return 0

    local host out code connect blocked=false unreachable=false
    for host in archive.anbox-cloud.io images.anbox-cloud.io; do
        # For HTTPS via an HTTP proxy, Squid's denial is returned on CONNECT
        # and recorded by curl in %{http_connect} (while %{http_code} is 000).
        out="$(curl -s -o /dev/null -w '%{http_code} %{http_connect}' --max-time 5 -x "${PROXY_URL}" "https://${host}/" 2>/dev/null || true)"
        read -r code connect <<<"${out:-000 000}"
        code="${code:-000}"
        connect="${connect:-000}"

        if [[ "${code}" == "403" || "${connect}" == "403" ]]; then
            echo "WARNING: proxy ${PROXY_URL} returned HTTP 403 Forbidden for https://${host}/ (http=${code}, connect=${connect})" >&2
            blocked=true
        elif [[ "${code}" == "000" && "${connect}" == "000" ]]; then
            echo "WARNING: could not reach https://${host}/ via proxy ${PROXY_URL} (unreachable or timed out)" >&2
            unreachable=true
        fi
    done

    if ${blocked}; then
        cat >&2 <<EOF
WARNING: One or more Anbox Cloud domains are blocked by ${PROXY_URL}.
         'pro enable anbox-cloud' and AMS image sync will fail until
         archive.anbox-cloud.io and images.anbox-cloud.io are allowlisted
         on the egress proxy (or an alternative --proxy is provided).
EOF
    elif ${unreachable}; then
        echo "WARNING: Verify that ${PROXY_URL} is reachable from this host and your Juju model." >&2
    fi
}

require_arg() {
    if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: option '$1' requires a value" >&2
        exit 1
    fi
}

# Parse CLI arguments
while (($# > 0)); do
    case "$1" in
        -n|--name)
            require_arg "$@"
            if [[ "$2" == *:* ]]; then
                BUNDLE_NAME="${2%%:*}"
                CLOUD_NAME="${2#*:}"
            else
                BUNDLE_NAME="$2"
            fi
            shift
            ;;
        --no-create-model)
            CREATE_MODEL=false
            NO_CREATE_MODEL_EXPLICIT=true
            ;;
        --dry-run)
            DRY_RUN=true
            CREATE_MODEL=false
            ;;
        --run)
            RUN_DEPLOY=true
            ;;
        --replay)
            REPLAY=true
            ;;
        --list)
            LIST_BUNDLES=true
            ;;
        --core)
            CORE_ONLY=true
            ;;
        -c|--channel)
            require_arg "$@"
            ANBOX_CHANNEL="$2"
            shift
            ;;
        -s|--series)
            require_arg "$@"
            ANBOX_SERIES="$2"
            shift
            ;;
        --ua-token)
            require_arg "$@"
            UA_TOKEN_VAL="$2"
            shift
            ;;
        --lxd-units)
            require_arg "$@"
            LXD_UNITS="$2"
            shift
            ;;
        --lxd-storage)
            require_arg "$@"
            LXD_STORAGE="$2"
            shift
            ;;
        --lxd-constraints)
            require_arg "$@"
            LXD_CONSTRAINTS="$2"
            shift
            ;;
        --control-constraints)
            require_arg "$@"
            CONTROL_CONSTRAINTS="$2"
            shift
            ;;
        --ha)
            ENABLE_HA=true
            ;;
        --ceph)
            ENABLE_CEPH=true
            ;;
        --microceph)
            ENABLE_CEPH=true
            ENABLE_MICROCEPH=true
            ;;
        --proxy)
            require_arg "$@"
            PROXY_URL="$2"
            shift
            ;;
        --no-proxy)
            require_arg "$@"
            CUSTOM_NO_PROXY="$2"
            shift
            ;;
        --disable-proxy)
            DISABLE_PROXY=true
            ;;
        --model-config)
            require_arg "$@"
            EXTRA_MODEL_CONFIG+=("$2")
            shift
            ;;
        --debug)
            DEBUG_TRACE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

# Enable xtrace only after argument parsing so --ua-token is never traced
if ${DEBUG_TRACE}; then
    set -x
fi

BUNDLES_ROOT="${SCRIPT_DIR}/b"

if ${LIST_BUNDLES}; then
    if [[ -d "${BUNDLES_ROOT}" ]]; then
        echo "Existing bundles under ${BUNDLES_ROOT}:"
        find "${BUNDLES_ROOT}" -mindepth 1 -maxdepth 1 -type d ! -name o -printf "  %f\n" | sort
    else
        echo "There are currently no bundles."
    fi
    exit 0
fi

if [[ -n "${BUNDLE_NAME}" ]]; then
    BUNDLE_DIR="${BUNDLES_ROOT}/${BUNDLE_NAME}"
else
    BUNDLE_DIR="${BUNDLES_ROOT}"
fi

# Handle --replay before regenerating anything
if ${REPLAY}; then
    if [[ ! -f "${BUNDLE_DIR}/command" ]]; then
        echo "ERROR: ${BUNDLE_DIR}/command does not exist" >&2
        exit 1
    fi
    echo "INFO: replaying last known command (from ${BUNDLE_DIR}/command)"
    cat "${BUNDLE_DIR}/command"
    if ${RUN_DEPLOY}; then
        if ${DRY_RUN}; then
            echo "INFO: --dry-run set, skipping execution"
        else
            bash "${BUNDLE_DIR}/command"
        fi
    fi
    exit 0
fi

# Validate options (disable xtrace while checking UA_TOKEN_VAL)
{ set +x; } 2>/dev/null
if [[ -z "${UA_TOKEN_VAL}" ]]; then
    echo "ERROR: Ubuntu Pro token is required. Export UA_TOKEN (preferred) or pass --ua-token <token>." >&2
    exit 1
fi
if ${DEBUG_TRACE}; then
    set -x
fi

if ! [[ "${LXD_UNITS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: --lxd-units must be a positive integer (got '${LXD_UNITS}')" >&2
    exit 1
fi

if ${RUN_DEPLOY} && ! ${DRY_RUN} && [[ -z "${BUNDLE_NAME}" ]] && ! ${NO_CREATE_MODEL_EXPLICIT}; then
    echo "ERROR: refusing to --run without -n/--name (pass -n <model>, or pass --no-create-model explicitly to target the current model)" >&2
    exit 1
fi

if [[ -n "${LXD_STORAGE}" ]] && ${ENABLE_CEPH}; then
    echo "ERROR: --lxd-storage (local ZFS block storage) and --ceph/--microceph are mutually exclusive" >&2
    exit 1
fi

if [[ "${ANBOX_SERIES}" != "noble" && "${ANBOX_SERIES}" != "jammy" ]]; then
    echo "WARNING: Anbox Cloud officially supports 'noble' and 'jammy' (got '${ANBOX_SERIES}')" >&2
fi

# Detect proxy & build deduplicated no_proxy list
detect_proxy

RESOLVED_NO_PROXY="${DEFAULT_NO_PROXY}"
if [[ -n "${no_proxy:-}" ]]; then
    RESOLVED_NO_PROXY="${RESOLVED_NO_PROXY},${no_proxy}"
fi
if [[ -n "${CUSTOM_NO_PROXY}" ]]; then
    RESOLVED_NO_PROXY="${RESOLVED_NO_PROXY},${CUSTOM_NO_PROXY}"
fi
RESOLVED_NO_PROXY="$(dedupe_csv "${RESOLVED_NO_PROXY}")"

# Determine upstream Charmhub bundle name
if ${CORE_ONLY}; then
    UPSTREAM_BUNDLE="anbox-cloud-core"
    OVERLAYS+=("ua-core.yaml.template:ua.yaml")
    OVERLAYS+=("machines-core.yaml.template:machines.yaml")
else
    UPSTREAM_BUNDLE="anbox-cloud"
    OVERLAYS+=("ua-full.yaml.template:ua.yaml")
    OVERLAYS+=("machines-full.yaml.template:machines.yaml")
fi

if ((LXD_UNITS > 1)); then
    OVERLAYS+=("lxd-scale.yaml.template:lxd-scale.yaml")
fi

if [[ -n "${LXD_STORAGE}" ]]; then
    OVERLAYS+=("lxd-storage.yaml.template:lxd-storage.yaml")
fi

if [[ -n "${PROXY_URL}" ]]; then
    OVERLAYS+=("ams-proxy.yaml.template:ams-proxy.yaml")
fi

if ${ENABLE_HA}; then
    OVERLAYS+=("ha-core.yaml.template:ha-core.yaml")
    if ! ${CORE_ONLY}; then
        OVERLAYS+=("ha-streaming.yaml.template:ha-streaming.yaml")
    fi
fi

if ${ENABLE_CEPH}; then
    OVERLAYS+=("ceph.yaml.template:ceph.yaml")
    if ${ENABLE_MICROCEPH}; then
        OVERLAYS+=("microceph.yaml.template:microceph.yaml")
    else
        POST_MSGS+=("Integrate LXD with your Ceph provider after deploy:")
        POST_MSGS+=("  juju integrate lxd:ceph ceph-mon:client   # or ceph-proxy:client")
    fi
fi

# Build Juju model-config arguments
declare -a MODEL_CONFIG_ARGS=()
for kv in ${DEFAULT_MODEL_CONFIG}; do
    MODEL_CONFIG_ARGS+=("${kv}")
done
if [[ -n "${PROXY_URL}" ]]; then
    # Ubuntu Pro CLI ('pro') ignores http_proxy/https_proxy env vars and only
    # reads /etc/ubuntu-advantage/uaclient.conf, so configure it via cloud-init
    # preruncmd before charm install hooks run.
    PRO_CLOUDINIT_USERDATA="$(printf 'preruncmd:\n  - pro config set http_proxy=%s\n  - pro config set https_proxy=%s\n' "${PROXY_URL}" "${PROXY_URL}")"
    MODEL_CONFIG_ARGS+=(
        "juju-http-proxy=${PROXY_URL}"
        "juju-https-proxy=${PROXY_URL}"
        "juju-no-proxy=${RESOLVED_NO_PROXY}"
        "apt-http-proxy=${PROXY_URL}"
        "apt-https-proxy=${PROXY_URL}"
        "snap-http-proxy=${PROXY_URL}"
        "snap-https-proxy=${PROXY_URL}"
        "cloudinit-userdata=${PRO_CLOUDINIT_USERDATA}"
    )
fi
if ((${#EXTRA_MODEL_CONFIG[@]} > 0)); then
    MODEL_CONFIG_ARGS+=("${EXTRA_MODEL_CONFIG[@]}")
fi

# Create/switch Juju model and apply model-config (unless --dry-run)
if [[ -n "${BUNDLE_NAME}" ]]; then
    MODEL_NAME="${BUNDLE_NAME}"
fi

if ! ${DRY_RUN}; then
    check_proxy_anbox_access

    if ! command -v juju &>/dev/null; then
        echo "ERROR: 'juju' CLI not found. Install Juju 3.x or pass --dry-run to generate files only." >&2
        exit 1
    fi

    if ${CREATE_MODEL} && [[ -n "${BUNDLE_NAME}" ]]; then
        if juju models --format=short 2>/dev/null | awk '{print $1}' | sed 's/\*$//' | grep -qx "${BUNDLE_NAME}"; then
            echo "INFO: switching to existing Juju model '${BUNDLE_NAME}'"
            juju switch "${BUNDLE_NAME}"
        else
            echo "INFO: creating Juju model '${BUNDLE_NAME}'"
            if [[ -n "${CLOUD_NAME}" ]]; then
                juju add-model "${BUNDLE_NAME}" "${CLOUD_NAME}"
            else
                juju add-model "${BUNDLE_NAME}"
            fi
        fi
    elif [[ -z "${MODEL_NAME}" ]]; then
        MODEL_NAME="$(juju switch 2>/dev/null | awk -F: '{print $2}' | awk '{print $1}')"
        if [[ -z "${MODEL_NAME}" ]]; then
            echo "ERROR: could not determine current Juju model. Pass -n <name> or select a model with 'juju switch'." >&2
            exit 1
        fi
        echo "INFO: targeting current Juju model '${MODEL_NAME}'"
    fi

    if ((${#MODEL_CONFIG_ARGS[@]} > 0)); then
        echo "INFO: applying Juju model-config to model '${MODEL_NAME}'"
        juju model-config -m "${MODEL_NAME}" "${MODEL_CONFIG_ARGS[@]}"
    fi
fi

# Render overlays into BUNDLE_DIR/o/
mkdir -p "${BUNDLE_DIR}/o"
chmod 700 "${BUNDLE_DIR}"
rm -rf "${BUNDLE_DIR}/o/"*

DEPLOY_TARGET="${UPSTREAM_BUNDLE} --channel ${ANBOX_CHANNEL}"
if ! ${DRY_RUN}; then
    LOCAL_BUNDLE_YAML="${BUNDLE_DIR}/bundle.yaml"
    fetch_and_strip_upstream_bundle "${LOCAL_BUNDLE_YAML}"
    DEPLOY_TARGET="$(printf '%q' "${LOCAL_BUNDLE_YAML}")"
fi

declare -a OVERLAY_PATHS=()
echo "Created ${UPSTREAM_BUNDLE} (${ANBOX_CHANNEL}, ${ANBOX_SERIES}) overlays in ${BUNDLE_DIR}/o:"
for spec in "${OVERLAYS[@]}"; do
    tmpl="${spec%%:*}"
    out_name="${spec#*:}"
    out_path="${BUNDLE_DIR}/o/${out_name}"
    render_overlay "${tmpl}" "${out_path}"
    OVERLAY_PATHS+=("${out_path}")
    echo "  + ${out_name}"
done

# Ensure no unrendered template variables remain
if unrendered=$(grep -rn '__[A-Z0-9_]*__' "${BUNDLE_DIR}/o" 2>/dev/null); then
    echo -e "ERROR: unrendered variables found in overlays:\n${unrendered}" >&2
    exit 1
fi

# Save commands for replayability (disable xtrace while redacting UA_TOKEN_VAL)
{ set +x; } 2>/dev/null
{
    printf '%s' "${SCRIPT_DIR}/generate-bundle.sh"
    for arg in "${CACHED_ARGS[@]}"; do
        if [[ "${arg}" == "${UA_TOKEN_VAL}" ]]; then
            printf ' %q' "<REDACTED>"
        else
            printf ' %q' "${arg}"
        fi
    done
    printf '\n'
} > "${BUNDLE_DIR}/generate-command"
if ${DEBUG_TRACE}; then
    set -x
fi

if ((${#MODEL_CONFIG_ARGS[@]} > 0)); then
    {
        printf 'juju model-config'
        if [[ -n "${MODEL_NAME}" ]]; then
            printf ' -m %q' "${MODEL_NAME}"
        fi
        for kv in "${MODEL_CONFIG_ARGS[@]}"; do
            printf ' %q' "${kv}"
        done
        printf '\n'
    } > "${BUNDLE_DIR}/model-config-command"
fi

{
    printf 'juju deploy'
    if [[ -n "${MODEL_NAME}" ]]; then
        printf ' -m %q' "${MODEL_NAME}"
    fi
    printf ' %s' "${DEPLOY_TARGET}"
    for path in "${OVERLAY_PATHS[@]}"; do
        printf ' \\\n  --overlay %q' "${path}"
    done
    printf '\n'
} > "${BUNDLE_DIR}/command"

chmod 600 "${BUNDLE_DIR}/o/ua.yaml"

echo ""
if ${DRY_RUN} && [[ -f "${BUNDLE_DIR}/model-config-command" ]]; then
    echo "Model config command (skipped due to --dry-run):"
    cat "${BUNDLE_DIR}/model-config-command"
    echo ""
fi

echo "Command to deploy:"
cat "${BUNDLE_DIR}/command"

POST_MSGS+=(
    "Monitor deployment: watch -c juju status${MODEL_NAME:+ -m ${MODEL_NAME}} --color --relations=true"
    "Once deployed, run: ./configure${MODEL_NAME:+ -m ${MODEL_NAME}}"
)

echo ""
echo "Post-Deployment Info/Actions:"
for msg in "${POST_MSGS[@]}"; do
    echo "  - ${msg}"
done

if ${RUN_DEPLOY}; then
    if ${DRY_RUN}; then
        echo ""
        echo "INFO: --dry-run set, skipping deploy execution."
    else
        echo ""
        echo "INFO: deploying ${UPSTREAM_BUNDLE}..."
        bash "${BUNDLE_DIR}/command"
    fi
fi
