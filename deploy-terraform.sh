#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=module_defaults
. "${SCRIPT_DIR}/module_defaults"

# Runtime options
DEPLOY_NAME="terraform"
DRY_RUN=false
DO_PLAN=false
DO_APPLY=false
DO_DESTROY=false
LIST_DEPLOYMENTS=false
DEBUG_TRACE=false

TF_REF=""
TF_REF_EXPLICIT=false
TF_LOCAL_DIR=""
RECLONE=false
FORCE_CHANGE=false
CHANNEL="${TF_ANBOX_CHANNEL}"
BASE="${TF_BASE}"
CONSTRAINTS="${TF_CONSTRAINTS}"
LXD_CONSTRAINTS="${TF_LXD_CONSTRAINTS}"
LXD_STORAGE=""
SSH_KEY_PATH=""
UA_TOKEN_VAL="${UA_TOKEN:-}"

ENABLE_HA=false
ENABLE_LB=false
ENABLE_COS=false
DEPLOY_REGISTRY=false
DEFAULT_REGISTRY_MODE="client"
ENABLE_DEBUG_MODE=false

PROXY_URL=""
CUSTOM_NO_PROXY=""
DISABLE_PROXY=false

declare -a RAW_SUBCLUSTERS=()
declare -a SUBCLUSTERS=()
declare -A SUBCLUSTER_REG_MODES=()
declare -a CACHED_ARGS=("$@")

usage() {
    cat <<EOF
USAGE: $(basename "$0") [OPTIONS]

Deploy Anbox Cloud >= 1.30 on PS7, PS6, or any Juju 3.x cloud using the
official upstream anbox-cloud-terraform plan with ProdStack proxy and
constraint overrides.

NOTE: Upstream anbox-cloud-terraform uses fixed Juju model names
('anbox-controller', 'anbox-subcluster-<suffix>', 'anbox-registry'), so
only one Terraform deployment is supported per Juju controller.

OPTIONS:
  -n, --name <name>              Workspace name under b/<name> (default: ${DEPLOY_NAME}).
      --dry-run                  Generate deploy.tfvars and override files only;
                                 skip git clone and terraform execution.
      --plan                     Run 'terraform init' and 'terraform plan'.
      --run, --apply             Run 'terraform init', 'plan', and 'apply -parallelism=1'.
      --destroy                  Run 'terraform destroy -parallelism=1' for -n <name>.
      --list                     List existing Terraform workspaces under b/.

  -c, --channel <channel>        Anbox Cloud charm channel (default: ${TF_ANBOX_CHANNEL}).
      --ref <git-ref>            anbox-cloud-terraform branch or tag. Defaults to
                                 '${TF_REPO_REF_1_30}' for 1.30/* channels, otherwise '${TF_REPO_REF}'.
      --tf-dir <path>            Copy an existing local anbox-cloud-terraform checkout
                                 instead of cloning from GitHub.
      --reclone                  Re-clone/re-copy the Terraform workspace when switching
                                 --ref or --tf-dir (preserves terraform.tfstate*).
      --force                    Allow destructive deploy-time-only changes (e.g. changing
                                 --lxd-storage on an existing deployment).
  -b, --base <base>              Ubuntu base (default: ${TF_BASE}).
      --ua-token <token>         Ubuntu Pro token (prefer exporting UA_TOKEN env var;
                                 CLI arguments are visible in 'ps').
      --ssh-key <path>           SSH public key to inject into Juju models
                                 (auto-detects ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub).

      --subcluster <name[:mode]> Subcluster suffix (repeatable; default: "a" -> anbox-subcluster-a).
                                 Optional :client or :publisher suffix wires AAR registry mode
                                 (implies --registry). Names must match ^[a-z0-9][a-z0-9-]*$.
      --lxd-units <N>            LXD worker count per subcluster (default: ${LXD_UNITS}).
      --lxd-constraints <str>    LXD machine constraints (default: "${TF_LXD_CONSTRAINTS}").
                                 NOTE: Changing constraints replaces existing LXD machines.
      --lxd-storage <pool,sz,n>  Juju storage directive for LXD pool (e.g. cinder,100G,1).
                                 Deploy-time only; changing replaces the LXD application.
      --constraints <str>        General application constraints (default: "${TF_CONSTRAINTS}").
                                 NOTE: Changing constraints replaces existing machines.

      --ha                       Enable HA mode (enable_ha = true).
      --enable-lb                Deploy HAProxy load balancer in anbox-controller.
      --cos                      Enable COS / grafana-agent integration.
      --registry                 Deploy Anbox Application Registry (anbox-registry model) and
                                 connect subclusters using --registry-mode (default: client).
      --registry-mode <mode>     Default AAR mode for subclusters when --registry is enabled:
                                 'client' (default) or 'publisher'.
      --debug-mode               Enable debug logging on Anbox charms.

      --proxy <url>              HTTP/HTTPS proxy URL (auto-detects PS7 if unset).
      --no-proxy <list>          Extra comma-separated no_proxy entries.
      --disable-proxy            Disable PS7/env proxy auto-detection.

      --debug                    Enable bash debug tracing (set -x).
  -h, --help                     Show this help message.

EXAMPLES:
  # Dry-run preview for PS7 (no cloud changes)
  UA_TOKEN=<token> ./deploy-terraform.sh -n tf-test --dry-run

  # Plan only (clones anbox-cloud-terraform, runs terraform init + plan)
  UA_TOKEN=<token> ./deploy-terraform.sh -n tf-anbox -c 1.30/stable --plan

  # Full deploy with 2 LXD nodes and HAProxy LB
  UA_TOKEN=<token> ./deploy-terraform.sh -n tf-anbox -c 1.30/stable --lxd-units 2 --enable-lb --run

  # Tear down deployment
  ./deploy-terraform.sh -n tf-anbox --destroy
EOF
}

require_arg() {
    if [[ $# -lt 2 || -z "$2" ]]; then
        echo "ERROR: option '$1' requires a value" >&2
        exit 1
    fi
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

filter_non_cidr_csv() {
    # AMS core.proxy_ignore_hosts rejects CIDR entries (e.g. 10.0.0.0/8); keep only hosts/IPs
    python3 -c '
import sys
out = [p.strip() for p in sys.argv[1].split(",") if p.strip() and "/" not in p]
print(",".join(out))
' "$1"
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

detect_ssh_key() {
    if [[ -n "${SSH_KEY_PATH}" ]]; then
        return
    fi
    # Prefer Juju's own SSH key (used by 'juju ssh' by default), rewriting the
    # reserved 'juju-client-key' comment to 'juju-tf' so Juju's juju_ssh_key
    # resource accepts it.
    if [[ -f "${HOME}/.local/share/juju/ssh/juju_id_rsa.pub" ]]; then
        mkdir -p "${WORK_DIR}"
        awk '{print $1, $2, "juju-tf"}' "${HOME}/.local/share/juju/ssh/juju_id_rsa.pub" > "${WORK_DIR}/juju_id_rsa.pub"
        SSH_KEY_PATH="${WORK_DIR}/juju_id_rsa.pub"
    elif [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
        SSH_KEY_PATH="${HOME}/.ssh/id_ed25519.pub"
    elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
        SSH_KEY_PATH="${HOME}/.ssh/id_rsa.pub"
    else
        echo "WARNING: No Juju or ~/.ssh public key found; 'juju ssh' may fail unless --ssh-key is provided." >&2
    fi
}

check_model_collisions() {
    command -v juju &>/dev/null || return 0

    local state_list
    state_list="$(terraform -chdir="${TF_WORK_DIR}" state list 2>/dev/null || true)"

    local -a checks=("anbox-controller:module.controller.juju_model.controller")
    local sc
    for sc in "${SUBCLUSTERS[@]}"; do
        checks+=("anbox-subcluster-${sc}:module.subcluster[\"${sc}\"].juju_model.subcluster")
    done
    if ${DEPLOY_REGISTRY}; then
        checks+=("anbox-registry:module.registry[0].juju_model.registry")
    fi

    local entry model_name tf_addr collision=false
    for entry in "${checks[@]}"; do
        model_name="${entry%%:*}"
        tf_addr="${entry#*:}"
        if juju show-model "${model_name}" &>/dev/null; then
            if ! grep -Fqx "${tf_addr}" <<<"${state_list}"; then
                echo "ERROR: Juju model '${model_name}' already exists on the current controller and is not managed by workspace '${DEPLOY_NAME}'." >&2
                collision=true
            fi
        fi
    done

    if ${collision}; then
        cat >&2 <<EOF
ERROR: Upstream anbox-cloud-terraform uses fixed Juju model names, so only one
       Terraform deployment is supported per Juju controller.
       Reuse the existing workspace (-n <existing-name>) or destroy the existing
       deployment before applying a new one.
EOF
        exit 1
    fi
}

check_upstream_override_drift() {
    local cp_tf="${TF_WORK_DIR}/modules/subcluster/control_plane.tf"
    [[ -f "${cp_tf}" && -n "${PROXY_URL}" ]] || return 0

    python3 -c '
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"resource\s+\"juju_application\"\s+\"ams\"\s*\{(.*?)\n\}", text, re.S)
if not m:
    sys.exit(0)
cm = re.search(r"config\s*=\s*\{(.*?)\}", m.group(1), re.S)
if not cm:
    sys.exit(0)
keys = set(re.findall(r"^\s*([A-Za-z0-9_-]+)\s*=", cm.group(1), re.M))
known = {"use_embedded_etcd", "snap_risk_level", "ua_token", "log_level"}
extra = sorted(keys - known)
if extra:
    print(f"WARNING: upstream juju_application.ams config has new key(s) not in sts_override.tf: {extra}", file=sys.stderr)
    print("         Review modules/subcluster/control_plane.tf and update build_subcluster_extra_overrides.", file=sys.stderr)
' "${cp_tf}"
}

copy_local_tf_dir() {
    local src="$1"
    local dst="$2"
    python3 -c '
import shutil, sys
src, dst = sys.argv[1], sys.argv[2]
ignore = shutil.ignore_patterns(
    ".terraform", ".terraform.lock.hcl",
    "*.tfstate", "*.tfstate.*",
    "tfplan", "*.tfvars", "*.tfvars.json",
    ".git",
)
shutil.copytree(src, dst, ignore=ignore)
' "${src}" "${dst}"
}

hcl_quote() {
    # Produce a safely quoted HCL string literal (JSON escaping + HCL template escaping)
    STS_VAL="$1" python3 -c '
import json, os
s = os.environ["STS_VAL"].replace("${", "$${").replace("%{", "%%{")
print(json.dumps(s), end="")
'
}

hcl_heredoc_escape() {
    # Escape HCL template interpolation markers inside heredocs
    STS_VAL="$1" python3 -c '
import os
s = os.environ["STS_VAL"].replace("${", "$${").replace("%{", "%%{")
print(s, end="")
'
}

hcl_string_list() {
    # Convert whitespace-separated tokens into a safely escaped HCL list without globbing
    local input="$1"
    local -a toks=()
    read -ra toks <<<"${input}"
    local first=true tok
    printf '['
    for tok in "${toks[@]}"; do
        if ${first}; then
            first=false
        else
            printf ', '
        fi
        hcl_quote "${tok}"
    done
    printf ']'
}

write_model_override_tf() {
    local dest="$1"
    local resource_name="$2"
    local extra_blocks="${3:-}"
    local proxy_q no_proxy_q proxy_hd

    {
        echo "// Auto-generated by sts-anbox-bundles deploy-terraform.sh"
        echo ""
        if [[ -n "${PROXY_URL}" ]]; then
            proxy_q="$(hcl_quote "${PROXY_URL}")"
            no_proxy_q="$(hcl_quote "${RESOLVED_NO_PROXY}")"
            proxy_hd="$(hcl_heredoc_escape "${PROXY_URL}")"
            cat <<EOF
resource "juju_model" "${resource_name}" {
  config = {
    logging-config              = var.debug ? "<root>=DEBUG" : "<root>=INFO"
    update-status-hook-interval = "5m"
    test-mode                   = "true"
    juju-http-proxy             = ${proxy_q}
    juju-https-proxy            = ${proxy_q}
    juju-no-proxy               = ${no_proxy_q}
    apt-http-proxy              = ${proxy_q}
    apt-https-proxy             = ${proxy_q}
    snap-http-proxy             = ${proxy_q}
    snap-https-proxy            = ${proxy_q}
    cloudinit-userdata          = <<-EOT
      preruncmd:
        - pro config set http_proxy=${proxy_hd}
        - pro config set https_proxy=${proxy_hd}
    EOT
  }
}
EOF
        else
            cat <<EOF
resource "juju_model" "${resource_name}" {
  config = {
    logging-config              = var.debug ? "<root>=DEBUG" : "<root>=INFO"
    update-status-hook-interval = "5m"
    test-mode                   = "true"
  }
}
EOF
        fi

        if [[ -n "${extra_blocks}" ]]; then
            echo ""
            printf '%s\n' "${extra_blocks}"
        fi
    } > "${dest}"
}

build_subcluster_extra_overrides() {
    local lxd_list lxd_storage_q proxy_hd no_proxy_hd
    lxd_list="$(hcl_string_list "${LXD_CONSTRAINTS}")"

    cat <<EOF
resource "juju_machine" "lxd_node" {
  // Merge by constraint key so LXD-specific constraints override general var.constraints
  // without producing duplicate Juju constraint keys.
  constraints = join(" ", values(merge(
    { for c in var.constraints : split("=", c)[0] => c },
    { for c in ${lxd_list} : split("=", c)[0] => c }
  )))
}
EOF

    if [[ -n "${LXD_STORAGE}" ]]; then
        lxd_storage_q="$(hcl_quote "${LXD_STORAGE}")"
        cat <<EOF

// Intentionally replaces upstream's local.is_aws storage_directives on OpenStack/PS6/PS7.
resource "juju_application" "lxd" {
  storage_directives = { "pool" = ${lxd_storage_q} }
}
EOF
    fi

    if [[ -n "${PROXY_URL}" ]]; then
        proxy_hd="$(hcl_heredoc_escape "${PROXY_URL}")"
        no_proxy_hd="$(hcl_heredoc_escape "${AMS_NO_PROXY}")"
        cat <<EOF

resource "juju_application" "ams" {
  config = {
    use_embedded_etcd = !var.external_etcd
    snap_risk_level   = local.risk
    ua_token          = var.ubuntu_pro_token
    log_level         = var.debug ? "debug" : "info"
    config            = <<-EOT
      core.proxy_http=${proxy_hd}
      core.proxy_https=${proxy_hd}
      core.proxy_ignore_hosts=${no_proxy_hd}
    EOT
  }
}
EOF
    fi
}

# Parse CLI arguments
while (($# > 0)); do
    case "$1" in
        --*=*)
            set -- "${1%%=*}" "${1#*=}" "${@:2}"
            ;;
    esac
    case "$1" in
        -n|--name)
            require_arg "$@"
            DEPLOY_NAME="$2"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --plan)
            DO_PLAN=true
            ;;
        --run|--apply)
            DO_PLAN=true
            DO_APPLY=true
            ;;
        --destroy)
            DO_DESTROY=true
            ;;
        --list)
            LIST_DEPLOYMENTS=true
            ;;
        -c|--channel)
            require_arg "$@"
            CHANNEL="$2"
            shift
            ;;
        --ref)
            require_arg "$@"
            TF_REF="$2"
            TF_REF_EXPLICIT=true
            shift
            ;;
        --tf-dir)
            require_arg "$@"
            TF_LOCAL_DIR="$2"
            shift
            ;;
        --reclone)
            RECLONE=true
            ;;
        --force)
            FORCE_CHANGE=true
            ;;
        -b|--base)
            require_arg "$@"
            BASE="$2"
            shift
            ;;
        --ua-token)
            require_arg "$@"
            UA_TOKEN_VAL="$2"
            shift
            ;;
        --ssh-key)
            require_arg "$@"
            SSH_KEY_PATH="$2"
            shift
            ;;
        --subcluster)
            require_arg "$@"
            RAW_SUBCLUSTERS+=("$2")
            shift
            ;;
        --lxd-units)
            require_arg "$@"
            LXD_UNITS="$2"
            shift
            ;;
        --lxd-constraints)
            require_arg "$@"
            LXD_CONSTRAINTS="$2"
            shift
            ;;
        --lxd-storage)
            require_arg "$@"
            LXD_STORAGE="$2"
            shift
            ;;
        --constraints)
            require_arg "$@"
            CONSTRAINTS="$2"
            shift
            ;;
        --ha)
            ENABLE_HA=true
            ;;
        --enable-lb)
            ENABLE_LB=true
            ;;
        --cos)
            ENABLE_COS=true
            ;;
        --registry)
            DEPLOY_REGISTRY=true
            ;;
        --registry-mode)
            require_arg "$@"
            DEFAULT_REGISTRY_MODE="$2"
            shift
            ;;
        --debug-mode)
            ENABLE_DEBUG_MODE=true
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
        --debug)
            DEBUG_TRACE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option '${1%%=*}'" >&2
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

if ${LIST_DEPLOYMENTS}; then
    if [[ -d "${BUNDLES_ROOT}" ]]; then
        echo "Existing Terraform workspaces under ${BUNDLES_ROOT}:"
        find "${BUNDLES_ROOT}" -mindepth 2 -maxdepth 2 \( -name "deploy.tfvars.json" -o -name "deploy.tfvars" \) -printf "  %h\n" | xargs -r -n1 basename | sort -u
    else
        echo "There are currently no Terraform workspaces."
    fi
    exit 0
fi

WORK_DIR="${BUNDLES_ROOT}/${DEPLOY_NAME}"
TF_WORK_DIR="${WORK_DIR}/terraform"
TFVARS_FILE="${WORK_DIR}/deploy.tfvars.json"

# Handle --destroy cleanly
if ${DO_DESTROY}; then
    DESTROY_VARS="${TFVARS_FILE}"
    if [[ ! -f "${DESTROY_VARS}" && -f "${WORK_DIR}/deploy.tfvars" ]]; then
        DESTROY_VARS="${WORK_DIR}/deploy.tfvars"
    fi
    if [[ ! -d "${TF_WORK_DIR}" || ! -f "${DESTROY_VARS}" ]]; then
        echo "ERROR: Terraform workspace not found at ${WORK_DIR}" >&2
        exit 1
    fi
    if ${DRY_RUN}; then
        echo "Dry-run destroy command:"
        echo "  terraform -chdir=${TF_WORK_DIR} destroy -var-file=${DESTROY_VARS} -parallelism=1"
        exit 0
    fi
    if ! command -v terraform &>/dev/null; then
        echo "ERROR: 'terraform' CLI not found. Install via: sudo snap install --classic --channel=latest/stable terraform" >&2
        exit 1
    fi
    echo "INFO: destroying Terraform deployment '${DEPLOY_NAME}'..."
    terraform -chdir="${TF_WORK_DIR}" destroy -var-file="${DESTROY_VARS}" -parallelism=1
    exit 0
fi

# Validate inputs (disable xtrace while checking UA_TOKEN_VAL)
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

if [[ "${DEFAULT_REGISTRY_MODE}" != "client" && "${DEFAULT_REGISTRY_MODE}" != "publisher" ]]; then
    echo "ERROR: --registry-mode must be 'client' or 'publisher' (got '${DEFAULT_REGISTRY_MODE}')" >&2
    exit 1
fi

if ((${#RAW_SUBCLUSTERS[@]} == 0)); then
    RAW_SUBCLUSTERS=("a")
fi

# Parse and validate subclusters (name[:client|publisher]), rejecting invalid or duplicate names
declare -A SEEN_SUBCLUSTERS=()
for spec in "${RAW_SUBCLUSTERS[@]}"; do
    sc_name="${spec%%:*}"
    sc_mode=""
    if [[ "${spec}" == *:* ]]; then
        sc_mode="${spec#*:}"
        if [[ "${sc_mode}" != "client" && "${sc_mode}" != "publisher" ]]; then
            echo "ERROR: invalid registry mode '${sc_mode}' for subcluster '${sc_name}' (must be 'client' or 'publisher')" >&2
            exit 1
        fi
        DEPLOY_REGISTRY=true
    fi
    if ! [[ "${sc_name}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "ERROR: invalid subcluster name '${sc_name}' (must match ^[a-z0-9][a-z0-9-]*$)" >&2
        exit 1
    fi
    if [[ -n "${SEEN_SUBCLUSTERS[${sc_name}]:-}" ]]; then
        echo "ERROR: duplicate subcluster name '${sc_name}'" >&2
        exit 1
    fi
    SEEN_SUBCLUSTERS["${sc_name}"]=1
    SUBCLUSTERS+=("${sc_name}")
    SUBCLUSTER_REG_MODES["${sc_name}"]="${sc_mode}"
done

if ${DEPLOY_REGISTRY}; then
    for sc in "${SUBCLUSTERS[@]}"; do
        if [[ -z "${SUBCLUSTER_REG_MODES[${sc}]}" ]]; then
            SUBCLUSTER_REG_MODES["${sc}"]="${DEFAULT_REGISTRY_MODE}"
        fi
    done
fi

# Derive default anbox-cloud-terraform ref from channel when --ref is not given
if ! ${TF_REF_EXPLICIT}; then
    if [[ "${CHANNEL}" == 1.30/* ]]; then
        TF_REF="${TF_REPO_REF_1_30}"
    else
        TF_REF="${TF_REPO_REF}"
    fi
fi

if [[ -n "${TF_LOCAL_DIR}" ]]; then
    DESIRED_TF_SOURCE="local:${TF_LOCAL_DIR}"
else
    DESIRED_TF_SOURCE="ref:${TF_REF}"
fi

detect_ssh_key
if [[ -n "${SSH_KEY_PATH}" && ! -f "${SSH_KEY_PATH}" ]]; then
    echo "ERROR: SSH public key file not found: ${SSH_KEY_PATH}" >&2
    exit 1
fi

detect_proxy

RESOLVED_NO_PROXY="${DEFAULT_NO_PROXY}"
if [[ -n "${no_proxy:-}" ]]; then
    RESOLVED_NO_PROXY="${RESOLVED_NO_PROXY},${no_proxy}"
fi
if [[ -n "${CUSTOM_NO_PROXY}" ]]; then
    RESOLVED_NO_PROXY="${RESOLVED_NO_PROXY},${CUSTOM_NO_PROXY}"
fi
RESOLVED_NO_PROXY="$(dedupe_csv "${RESOLVED_NO_PROXY}")"
AMS_NO_PROXY="$(filter_non_cidr_csv "${RESOLVED_NO_PROXY}")"

mkdir -p "${WORK_DIR}"
chmod 700 "${WORK_DIR}"

# Generate deploy.tfvars.json via Python json.dump (safe escaping, no token in argv)
# and redacted generate-command with xtrace disabled so --debug never prints UA_TOKEN_VAL.
{ set +x; } 2>/dev/null
STS_UA_TOKEN="${UA_TOKEN_VAL}" \
STS_CHANNEL="${CHANNEL}" \
STS_BASE="${BASE}" \
STS_CONSTRAINTS="${CONSTRAINTS}" \
STS_ENABLE_HA="${ENABLE_HA}" \
STS_ENABLE_LB="${ENABLE_LB}" \
STS_ENABLE_COS="${ENABLE_COS}" \
STS_DEPLOY_REGISTRY="${DEPLOY_REGISTRY}" \
STS_ENABLE_DEBUG_MODE="${ENABLE_DEBUG_MODE}" \
STS_SSH_KEY_PATH="${SSH_KEY_PATH}" \
STS_LXD_UNITS="${LXD_UNITS}" \
STS_SUBCLUSTERS="$(
    for sc in "${SUBCLUSTERS[@]}"; do
        printf '%s:%s\n' "${sc}" "${SUBCLUSTER_REG_MODES[${sc}]:-}"
    done
)" \
python3 -c '
import json, os, sys

def as_bool(v):
    return v.lower() == "true"

deploy_registry = as_bool(os.environ["STS_DEPLOY_REGISTRY"])
subclusters = []
for line in os.environ["STS_SUBCLUSTERS"].splitlines():
    if not line:
        continue
    name, _, mode = line.partition(":")
    entry = {"name": name, "lxd_node_count": int(os.environ["STS_LXD_UNITS"])}
    if deploy_registry and mode:
        entry["registry"] = {"mode": mode}
    subclusters.append(entry)

data = {
    "ubuntu_pro_token": os.environ["STS_UA_TOKEN"],
    "anbox_channel": os.environ["STS_CHANNEL"],
    "base": os.environ["STS_BASE"],
    "constraints": os.environ["STS_CONSTRAINTS"].split(),
    "enable_ha": as_bool(os.environ["STS_ENABLE_HA"]),
    "enable_lb": as_bool(os.environ["STS_ENABLE_LB"]),
    "enable_cos": as_bool(os.environ["STS_ENABLE_COS"]),
    "deploy_registry": deploy_registry,
    "enable_debug_mode": as_bool(os.environ["STS_ENABLE_DEBUG_MODE"]),
    "subclusters": subclusters,
}
if os.environ["STS_SSH_KEY_PATH"]:
    data["ssh_key_path"] = os.environ["STS_SSH_KEY_PATH"]

with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
' "${TFVARS_FILE}"
chmod 600 "${TFVARS_FILE}"

# Save redacted generate-command
{
    printf '%s' "${SCRIPT_DIR}/deploy-terraform.sh"
    redact_next=false
    for arg in "${CACHED_ARGS[@]}"; do
        if ${redact_next}; then
            printf ' %q' "<REDACTED>"
            redact_next=false
        elif [[ "${arg}" == "--ua-token" ]]; then
            printf ' %q' "${arg}"
            redact_next=true
        elif [[ "${arg}" == --ua-token=* ]]; then
            printf ' %q' "--ua-token=<REDACTED>"
        else
            printf ' %q' "${arg}"
        fi
    done
    printf '\n'
} > "${WORK_DIR}/generate-command"
if ${DEBUG_TRACE}; then
    set -x
fi

SUBCLUSTER_EXTRA="$(build_subcluster_extra_overrides)"

if ${DRY_RUN}; then
    PREVIEW_DIR="${WORK_DIR}/overrides-preview"
    mkdir -p "${PREVIEW_DIR}"
    write_model_override_tf "${PREVIEW_DIR}/controller_sts_override.tf" "controller"
    write_model_override_tf "${PREVIEW_DIR}/subcluster_sts_override.tf" "subcluster" "${SUBCLUSTER_EXTRA}"
    if ${DEPLOY_REGISTRY}; then
        write_model_override_tf "${PREVIEW_DIR}/registry_sts_override.tf" "registry"
    fi

    echo "Dry-run generated Terraform files in ${WORK_DIR} (channel: ${CHANNEL}, source: ${DESIRED_TF_SOURCE}):"
    echo "  + deploy.tfvars.json (chmod 600)"
    echo "  + overrides-preview/controller_sts_override.tf"
    echo "  + overrides-preview/subcluster_sts_override.tf"
    if ${DEPLOY_REGISTRY}; then
        echo "  + overrides-preview/registry_sts_override.tf"
    fi
    echo ""
    echo "Next steps (without --dry-run):"
    echo "  ./deploy-terraform.sh -n ${DEPLOY_NAME} -c ${CHANNEL} --plan"
    echo "  ./deploy-terraform.sh -n ${DEPLOY_NAME} -c ${CHANNEL} --run"
    exit 0
fi

check_proxy_anbox_access

# Prepare upstream anbox-cloud-terraform checkout (tracking source ref in tf-ref)
TF_REF_FILE="${WORK_DIR}/tf-ref"
if [[ -d "${TF_WORK_DIR}" ]]; then
    RECORDED_TF_SOURCE=""
    [[ -f "${TF_REF_FILE}" ]] && RECORDED_TF_SOURCE="$(cat "${TF_REF_FILE}")"

    if ${RECLONE}; then
        echo "INFO: --reclone requested; refreshing ${TF_WORK_DIR} while preserving terraform.tfstate*..."
        STATE_BACKUP="$(mktemp -d "${WORK_DIR}/state-backup.XXXXXX")"
        shopt -s nullglob
        for sf in "${TF_WORK_DIR}"/terraform.tfstate*; do
            cp -a "${sf}" "${STATE_BACKUP}/"
        done
        shopt -u nullglob
        rm -rf "${TF_WORK_DIR}"
        if [[ -n "${TF_LOCAL_DIR}" ]]; then
            copy_local_tf_dir "${TF_LOCAL_DIR}" "${TF_WORK_DIR}"
        else
            git clone --depth 1 --branch "${TF_REF}" "${TF_REPO_URL}" "${TF_WORK_DIR}"
        fi
        shopt -s nullglob
        for sf in "${STATE_BACKUP}"/terraform.tfstate*; do
            cp -a "${sf}" "${TF_WORK_DIR}/"
        done
        shopt -u nullglob
        rm -rf "${STATE_BACKUP}"
        printf '%s\n' "${DESIRED_TF_SOURCE}" > "${TF_REF_FILE}"
    else
        if [[ -n "${RECORDED_TF_SOURCE}" && "${RECORDED_TF_SOURCE}" != "${DESIRED_TF_SOURCE}" ]] && \
           { ${TF_REF_EXPLICIT} || [[ -n "${TF_LOCAL_DIR}" ]]; }; then
            echo "ERROR: existing workspace '${DEPLOY_NAME}' uses '${RECORDED_TF_SOURCE}', but '${DESIRED_TF_SOURCE}' was requested." >&2
            echo "       Re-run with --reclone to switch refs (preserves terraform.tfstate*), or use a new -n <name>." >&2
            exit 1
        fi
        echo "INFO: reusing existing Terraform workspace at ${TF_WORK_DIR} (${RECORDED_TF_SOURCE:-unknown ref})"
    fi
else
    if [[ -n "${TF_LOCAL_DIR}" ]]; then
        echo "INFO: copying local anbox-cloud-terraform from ${TF_LOCAL_DIR} (excluding state/cache/secrets)..."
        copy_local_tf_dir "${TF_LOCAL_DIR}" "${TF_WORK_DIR}"
    else
        echo "INFO: cloning ${TF_REPO_URL} (ref: ${TF_REF}) into ${TF_WORK_DIR}..."
        git clone --depth 1 --branch "${TF_REF}" "${TF_REPO_URL}" "${TF_WORK_DIR}"
    fi
    printf '%s\n' "${DESIRED_TF_SOURCE}" > "${TF_REF_FILE}"
fi

# Warn if using 'main' against a channel track different from upstream variables.tf default
if [[ "${TF_REF}" == "main" && -z "${TF_LOCAL_DIR}" && -f "${TF_WORK_DIR}/variables.tf" ]]; then
    UPSTREAM_DEFAULT_CH="$(awk '
        /variable "anbox_channel"/ { in_blk=1 }
        in_blk && /default[[:space:]]*=/ {
            if (match($0, /"[^"]+"/)) { print substr($0, RSTART+1, RLENGTH-2); exit }
        }
        in_blk && /^\}/ { in_blk=0 }
    ' "${TF_WORK_DIR}/variables.tf")"
    if [[ -n "${UPSTREAM_DEFAULT_CH}" && "${CHANNEL%%/*}" != "${UPSTREAM_DEFAULT_CH%%/*}" ]]; then
        echo "WARNING: using anbox-cloud-terraform ref 'main' (defaults to ${UPSTREAM_DEFAULT_CH}) with channel '${CHANNEL}'." >&2
        echo "         Consider pinning a matching --ref tag (e.g. --ref v${CHANNEL%%/*}.x) to avoid upstream drift." >&2
    fi
fi

# Guard against changing deploy-time-only --lxd-storage on an existing Terraform state (M6)
LXD_STORAGE_FILE="${WORK_DIR}/lxd-storage"
if [[ -f "${TF_WORK_DIR}/terraform.tfstate" && -s "${TF_WORK_DIR}/terraform.tfstate" && -f "${LXD_STORAGE_FILE}" ]]; then
    RECORDED_LXD_STORAGE="$(cat "${LXD_STORAGE_FILE}")"
    if [[ "${RECORDED_LXD_STORAGE}" != "${LXD_STORAGE}" ]] && ! ${FORCE_CHANGE}; then
        echo "ERROR: --lxd-storage changed from '${RECORDED_LXD_STORAGE:-<none>}' to '${LXD_STORAGE:-<none>}' on an existing deployment." >&2
        echo "       Changing storage_directives forces replacement of the 'lxd' application and all instances." >&2
        echo "       Pass --force if you intentionally want to replace 'lxd'." >&2
        exit 1
    fi
fi
printf '%s\n' "${LXD_STORAGE}" > "${LXD_STORAGE_FILE}"

# Inject Terraform override files into each module
check_upstream_override_drift
write_model_override_tf "${TF_WORK_DIR}/modules/controller/sts_override.tf" "controller"
write_model_override_tf "${TF_WORK_DIR}/modules/subcluster/sts_override.tf" "subcluster" "${SUBCLUSTER_EXTRA}"
if [[ -d "${TF_WORK_DIR}/modules/registry" ]]; then
    write_model_override_tf "${TF_WORK_DIR}/modules/registry/sts_override.tf" "registry"
fi

# Save helper commands
cat > "${WORK_DIR}/plan-command" <<EOF
terraform -chdir=${TF_WORK_DIR} init
terraform -chdir=${TF_WORK_DIR} plan -out=tfplan -var-file=${TFVARS_FILE}
EOF

cat > "${WORK_DIR}/apply-command" <<EOF
# Re-run plan-command first if state or tfvars changed since planning.
terraform -chdir=${TF_WORK_DIR} apply -parallelism=1 tfplan
EOF

cat > "${WORK_DIR}/destroy-command" <<EOF
terraform -chdir=${TF_WORK_DIR} destroy -var-file=${TFVARS_FILE} -parallelism=1
EOF

echo "Prepared Terraform workspace in ${WORK_DIR} (channel: ${CHANNEL}, ref: ${TF_REF}):"
echo "  + deploy.tfvars.json (chmod 600)"
echo "  + terraform/modules/controller/sts_override.tf"
echo "  + terraform/modules/subcluster/sts_override.tf"
if [[ -d "${TF_WORK_DIR}/modules/registry" ]]; then
    echo "  + terraform/modules/registry/sts_override.tf"
fi

if ${DO_PLAN}; then
    if ! command -v terraform &>/dev/null; then
        echo "ERROR: 'terraform' CLI not found. Install via: sudo snap install --classic --channel=latest/stable terraform" >&2
        exit 1
    fi

    echo ""
    echo "INFO: running terraform init..."
    terraform -chdir="${TF_WORK_DIR}" init

    echo ""
    echo "INFO: running terraform plan..."
    terraform -chdir="${TF_WORK_DIR}" plan -out=tfplan -var-file="${TFVARS_FILE}"
fi

if ${DO_APPLY}; then
    check_model_collisions
    echo ""
    echo "INFO: running terraform apply -parallelism=1..."
    terraform -chdir="${TF_WORK_DIR}" apply -parallelism=1 tfplan
fi

echo ""
echo "Post-Deployment Info/Actions:"
if [[ -z "${SSH_KEY_PATH}" ]]; then
    echo "  - WARNING: No SSH public key was configured; 'juju ssh' and './configure --reboot/--fix-modules'"
    echo "             will fail until you run 'juju add-ssh-key' or re-run with --ssh-key <path>."
fi
if ! ${DO_PLAN}; then
    echo "  - Plan:    bash ${WORK_DIR}/plan-command"
fi
if ! ${DO_APPLY}; then
    echo "  - Apply:   bash ${WORK_DIR}/apply-command  (re-plan first if state changed)"
fi
echo "  - Monitor controller: juju status -m anbox-controller --color"
for sc in "${SUBCLUSTERS[@]}"; do
    echo "  - Monitor subcluster: juju status -m anbox-subcluster-${sc} --color"
    echo "  - Configure subcluster: ./configure -m anbox-subcluster-${sc} --reboot --fix-modules"
done
echo "  - Configure controller: ./configure -m anbox-controller --register-email <ubuntu-one-email>"
echo "  - Destroy when done:    ./deploy-terraform.sh -n ${DEPLOY_NAME} --destroy"
