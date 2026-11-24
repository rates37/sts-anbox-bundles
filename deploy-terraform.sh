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

TF_REF="${TF_REPO_REF}"
TF_LOCAL_DIR=""
CHANNEL="${TF_ANBOX_CHANNEL}"
BASE="${TF_BASE}"
CONSTRAINTS="${TF_CONSTRAINTS}"
LXD_STORAGE=""
SSH_KEY_PATH=""
UA_TOKEN_VAL="${UA_TOKEN:-}"

ENABLE_HA=false
ENABLE_LB=false
ENABLE_COS=false
DEPLOY_REGISTRY=false
ENABLE_DEBUG_MODE=false

PROXY_URL=""
CUSTOM_NO_PROXY=""
DISABLE_PROXY=false

declare -a SUBCLUSTERS=()
declare -a CACHED_ARGS=("$@")

usage() {
    cat <<EOF
USAGE: $(basename "$0") [OPTIONS]

Deploy Anbox Cloud >= 1.30 on PS7, PS6, or any Juju 3.x cloud using the
official upstream anbox-cloud-terraform plan with ProdStack proxy and
constraint overrides.

OPTIONS:
  -n, --name <name>              Workspace name under b/<name> (default: ${DEPLOY_NAME}).
      --dry-run                  Generate deploy.tfvars and override files only;
                                 skip git clone and terraform execution.
      --plan                     Run 'terraform init' and 'terraform plan'.
      --run, --apply             Run 'terraform init', 'plan', and 'apply -parallelism=1'.
      --destroy                  Run 'terraform destroy -parallelism=1' for -n <name>.
      --list                     List existing Terraform workspaces under b/.

  -c, --channel <channel>        Anbox Cloud charm channel (default: ${TF_ANBOX_CHANNEL}).
      --ref <git-ref>            anbox-cloud-terraform branch or tag (default: ${TF_REPO_REF}).
                                 For 1.30.x, use e.g. --ref v1.30.1 -c 1.30/stable.
      --tf-dir <path>            Copy an existing local anbox-cloud-terraform checkout
                                 instead of cloning from GitHub.
  -b, --base <base>              Ubuntu base (default: ${TF_BASE}).
      --ua-token <token>         Ubuntu Pro token (prefer exporting UA_TOKEN env var;
                                 CLI arguments are visible in 'ps').
      --ssh-key <path>           SSH public key to inject into Juju models
                                 (auto-detects ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub).

      --subcluster <name>        Subcluster suffix (repeatable; default: "a" -> anbox-subcluster-a).
      --lxd-units <N>            LXD worker count per subcluster (default: ${LXD_UNITS}).
      --lxd-constraints <str>    LXD machine constraints (default: "${LXD_CONSTRAINTS}").
      --lxd-storage <pool,sz,n>  Juju storage directive for LXD pool (e.g. cinder,100G,1).
      --constraints <str>        General application constraints (default: "${TF_CONSTRAINTS}").

      --ha                       Enable HA mode (enable_ha = true).
      --enable-lb                Deploy HAProxy load balancer in anbox-controller.
      --cos                      Enable COS / grafana-agent integration.
      --registry                 Deploy Anbox Application Registry (anbox-registry model).
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

hcl_string_list() {
    # Convert whitespace-separated tokens into an HCL list of quoted strings
    local input="$1"
    local first=true
    printf '['
    for tok in ${input}; do
        if ${first}; then
            first=false
        else
            printf ', '
        fi
        printf '"%s"' "${tok}"
    done
    printf ']'
}

write_model_override_tf() {
    local dest="$1"
    local resource_name="$2"
    local extra_blocks="${3:-}"

    {
        echo "// Auto-generated by sts-anbox-bundles deploy-terraform.sh"
        echo ""
        if [[ -n "${PROXY_URL}" ]]; then
            cat <<EOF
resource "juju_model" "${resource_name}" {
  config = {
    logging-config              = var.debug ? "<root>=DEBUG" : "<root>=INFO"
    update-status-hook-interval = "5m"
    test-mode                   = "true"
    juju-http-proxy             = "${PROXY_URL}"
    juju-https-proxy            = "${PROXY_URL}"
    juju-no-proxy               = "${RESOLVED_NO_PROXY}"
    apt-http-proxy              = "${PROXY_URL}"
    apt-https-proxy             = "${PROXY_URL}"
    snap-http-proxy             = "${PROXY_URL}"
    snap-https-proxy            = "${PROXY_URL}"
    cloudinit-userdata          = <<-EOT
      preruncmd:
        - pro config set http_proxy=${PROXY_URL}
        - pro config set https_proxy=${PROXY_URL}
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
    local lxd_list
    lxd_list="$(hcl_string_list "${LXD_CONSTRAINTS}")"

    cat <<EOF
resource "juju_machine" "lxd_node" {
  constraints = join(" ", concat(var.constraints, ${lxd_list}))
}
EOF

    if [[ -n "${LXD_STORAGE}" ]]; then
        cat <<EOF

resource "juju_application" "lxd" {
  storage_directives = { "pool" = "${LXD_STORAGE}" }
}
EOF
    fi

    if [[ -n "${PROXY_URL}" ]]; then
        cat <<EOF

resource "juju_application" "ams" {
  config = {
    use_embedded_etcd = !var.external_etcd
    snap_risk_level   = local.risk
    ua_token          = var.ubuntu_pro_token
    log_level         = var.debug ? "debug" : "info"
    config            = <<-EOT
      core.proxy_http=${PROXY_URL}
      core.proxy_https=${PROXY_URL}
      core.proxy_ignore_hosts=${RESOLVED_NO_PROXY}
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
            shift
            ;;
        --tf-dir)
            require_arg "$@"
            TF_LOCAL_DIR="$2"
            shift
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
            SUBCLUSTERS+=("$2")
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
        find "${BUNDLES_ROOT}" -mindepth 2 -maxdepth 2 -name "deploy.tfvars" -printf "  %h\n" | xargs -r -n1 basename | sort
    else
        echo "There are currently no Terraform workspaces."
    fi
    exit 0
fi

WORK_DIR="${BUNDLES_ROOT}/${DEPLOY_NAME}"
TF_WORK_DIR="${WORK_DIR}/terraform"

# Handle --destroy cleanly
if ${DO_DESTROY}; then
    if [[ ! -d "${TF_WORK_DIR}" || ! -f "${WORK_DIR}/deploy.tfvars" ]]; then
        echo "ERROR: Terraform workspace not found at ${WORK_DIR}" >&2
        exit 1
    fi
    if ${DRY_RUN}; then
        echo "Dry-run destroy command:"
        echo "  terraform -chdir=${TF_WORK_DIR} destroy -var-file=${WORK_DIR}/deploy.tfvars -parallelism=1"
        exit 0
    fi
    if ! command -v terraform &>/dev/null; then
        echo "ERROR: 'terraform' CLI not found. Install via: sudo snap install --classic --channel=latest/stable terraform" >&2
        exit 1
    fi
    echo "INFO: destroying Terraform deployment '${DEPLOY_NAME}'..."
    terraform -chdir="${TF_WORK_DIR}" destroy -var-file="${WORK_DIR}/deploy.tfvars" -parallelism=1
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

if ((${#SUBCLUSTERS[@]} == 0)); then
    SUBCLUSTERS=("a")
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

mkdir -p "${WORK_DIR}"
chmod 700 "${WORK_DIR}"

# Generate deploy.tfvars and redacted generate-command with xtrace disabled
# so --debug never prints UA_TOKEN_VAL.
{ set +x; } 2>/dev/null
CONSTRAINTS_HCL="$(hcl_string_list "${CONSTRAINTS}")"
{
    echo "// Auto-generated by sts-anbox-bundles deploy-terraform.sh"
    echo "ubuntu_pro_token  = \"${UA_TOKEN_VAL}\""
    echo "anbox_channel     = \"${CHANNEL}\""
    echo "base              = \"${BASE}\""
    echo "constraints       = ${CONSTRAINTS_HCL}"
    echo "enable_ha         = ${ENABLE_HA}"
    echo "enable_lb         = ${ENABLE_LB}"
    echo "enable_cos        = ${ENABLE_COS}"
    echo "deploy_registry   = ${DEPLOY_REGISTRY}"
    echo "enable_debug_mode = ${ENABLE_DEBUG_MODE}"
    if [[ -n "${SSH_KEY_PATH}" ]]; then
        echo "ssh_key_path      = \"${SSH_KEY_PATH}\""
    fi
    echo "subclusters = ["
    for sc in "${SUBCLUSTERS[@]}"; do
        echo "  {"
        echo "    name           = \"${sc}\""
        echo "    lxd_node_count = ${LXD_UNITS}"
        echo "  },"
    done
    echo "]"
} > "${WORK_DIR}/deploy.tfvars"
chmod 600 "${WORK_DIR}/deploy.tfvars"

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

    echo "Dry-run generated Terraform files in ${WORK_DIR}:"
    echo "  + deploy.tfvars (chmod 600)"
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

# Prepare upstream anbox-cloud-terraform checkout
if [[ ! -d "${TF_WORK_DIR}" ]]; then
    if [[ -n "${TF_LOCAL_DIR}" ]]; then
        echo "INFO: copying local anbox-cloud-terraform from ${TF_LOCAL_DIR}..."
        cp -r "${TF_LOCAL_DIR}" "${TF_WORK_DIR}"
    else
        echo "INFO: cloning ${TF_REPO_URL} (ref: ${TF_REF}) into ${TF_WORK_DIR}..."
        git clone --depth 1 --branch "${TF_REF}" "${TF_REPO_URL}" "${TF_WORK_DIR}"
    fi
else
    echo "INFO: reusing existing Terraform workspace at ${TF_WORK_DIR}"
fi

# Inject Terraform override files into each module
write_model_override_tf "${TF_WORK_DIR}/modules/controller/sts_override.tf" "controller"
write_model_override_tf "${TF_WORK_DIR}/modules/subcluster/sts_override.tf" "subcluster" "${SUBCLUSTER_EXTRA}"
if [[ -d "${TF_WORK_DIR}/modules/registry" ]]; then
    write_model_override_tf "${TF_WORK_DIR}/modules/registry/sts_override.tf" "registry"
fi

# Save helper commands
cat > "${WORK_DIR}/plan-command" <<EOF
terraform -chdir=${TF_WORK_DIR} init -upgrade=false
terraform -chdir=${TF_WORK_DIR} plan -out=tfplan -var-file=${WORK_DIR}/deploy.tfvars
EOF

cat > "${WORK_DIR}/apply-command" <<EOF
terraform -chdir=${TF_WORK_DIR} apply -parallelism=1 tfplan
EOF

cat > "${WORK_DIR}/destroy-command" <<EOF
terraform -chdir=${TF_WORK_DIR} destroy -var-file=${WORK_DIR}/deploy.tfvars -parallelism=1
EOF

echo "Prepared Terraform workspace in ${WORK_DIR} (channel: ${CHANNEL}, ref: ${TF_REF}):"
echo "  + deploy.tfvars (chmod 600)"
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
    terraform -chdir="${TF_WORK_DIR}" plan -out=tfplan -var-file="${WORK_DIR}/deploy.tfvars"
fi

if ${DO_APPLY}; then
    echo ""
    echo "INFO: running terraform apply -parallelism=1..."
    terraform -chdir="${TF_WORK_DIR}" apply -parallelism=1 tfplan
fi

echo ""
echo "Post-Deployment Info/Actions:"
if ! ${DO_PLAN}; then
    echo "  - Plan:    bash ${WORK_DIR}/plan-command"
fi
if ! ${DO_APPLY}; then
    echo "  - Apply:   bash ${WORK_DIR}/apply-command"
fi
echo "  - Monitor controller: juju status -m anbox-controller --color"
for sc in "${SUBCLUSTERS[@]}"; do
    echo "  - Monitor subcluster: juju status -m anbox-subcluster-${sc} --color"
    echo "  - Configure subcluster: ./configure -m anbox-subcluster-${sc} --reboot --fix-modules"
done
echo "  - Configure controller: ./configure -m anbox-controller --register-email <ubuntu-one-email>"
echo "  - Destroy when done:    ./deploy-terraform.sh -n ${DEPLOY_NAME} --destroy"
