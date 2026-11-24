# sts-anbox-bundles

Minimal `stsstack-bundles`-style generator for deploying **charmed Anbox Cloud** on **PS7**, **PS6**, and other Juju 3.x clouds:

- **Anbox Cloud `<= 1.29`** ([generate-bundle.sh](./generate-bundle.sh)): deploys the official Charmhub bundle (`anbox-cloud` or `anbox-cloud-core`) with dynamically rendered Juju overlays (Ubuntu Pro token, machine constraints, LXD scaling/storage, PS7 proxy settings, HA, and Ceph/MicroCeph).
- **Anbox Cloud `>= 1.30`** ([deploy-terraform.sh](./deploy-terraform.sh)): wraps the official upstream [`anbox-cloud-terraform`](https://github.com/canonical/anbox-cloud-terraform) plan (the only supported charm-based deployment method from 1.30.0 onward) with generated `deploy.tfvars.json` and Terraform module overrides for PS7 proxy/cloud-init, AMS proxy, LXD constraints, and LXD storage.

## Prerequisites

- **Juju 3.x** (3.6 LTS recommended): `sudo snap install --channel=3/stable juju`
- **Terraform** (only required for `deploy-terraform.sh` / Anbox Cloud `>= 1.30`): `sudo snap install --classic --channel=latest/stable terraform`
- A bootstrapped Juju controller on PS7, PS6, or another supported cloud
- An **Ubuntu Pro** subscription token (full Ubuntu Pro, **not** Infra-only)
- `jq` (used by `./configure`)

## PS7 & PS6 Proxy Behavior

`generate-bundle.sh` automatically detects the environment proxy unless `--disable-proxy` or `--proxy <url>` is passed:

1. `$http_proxy` (if already set in your environment)
2. **PS7**: `http://egress.ps7.internal:3128` (tested via `nc -vz egress.ps7.internal 3128`)
3. **PS6**: PS6 reproducer instances have direct internet egress, so `squid.internal:3128` is intentionally **not** auto-enabled (it blocks `archive.anbox-cloud.io` by default). Use `--proxy http://squid.internal:3128` only if you explicitly want to force it.

When a proxy is active, `generate-bundle.sh`:
- Applies Juju `model-config` (`juju-http-proxy`, `juju-https-proxy`, `juju-no-proxy`, `apt-http-proxy`, `apt-https-proxy`, `snap-http-proxy`, `snap-https-proxy`, plus `cloudinit-userdata` `preruncmd` to run `pro config set http_proxy`/`https_proxy` because `pro` ignores environment proxy variables).
- Warns if the proxy returns HTTP `403` for `archive.anbox-cloud.io` or `images.anbox-cloud.io` (both domains must be allowlisted on the egress proxy for `pro enable anbox-cloud` and AMS image sync).
- Generates `ams-proxy.yaml` setting `core.proxy_http`, `core.proxy_https`, and `core.proxy_ignore_hosts` on the `ams` charm so AMS can pull Android images through the proxy.

## Quickstart

Export your Ubuntu Pro token via the `UA_TOKEN` environment variable (preferred over `--ua-token`, which is visible in `ps` on shared hosts):

```bash
export UA_TOKEN="<your-ubuntu-pro-token>"
```

> **Secret handling:** Both `generate-bundle.sh` and `deploy-terraform.sh` run with `umask 077` and `chmod 700` on `b/<name>/`, so `ua.yaml`, `deploy.tfvars.json`, `tfplan`, and `terraform.tfstate` are owner-only (`0600`) from creation and excluded by `.gitignore`. Note that Terraform's `tfplan` and `terraform.tfstate` store `ubuntu_pro_token` in plaintext — treat `b/<name>/` as sensitive and delete it once torn down.

### Generate only (inspect before deploying)

```bash
./generate-bundle.sh -n anbox-ps7
```

### Generate and deploy full Anbox Cloud stack (with streaming + dashboard)

```bash
./generate-bundle.sh -n anbox-ps7 --run
```

### Core-only (`anbox-cloud-core`, without streaming stack)

```bash
./generate-bundle.sh -n anbox-core --core --run
```

### Multi-node LXD with dedicated Cinder block storage

```bash
./generate-bundle.sh -n anbox-scale \
  --lxd-units 2 \
  --lxd-storage cinder,100G,1 \
  --run
```

### High Availability + MicroCeph

```bash
./generate-bundle.sh -n anbox-ha \
  --ha \
  --microceph \
  --run
```

### Dry-run (offline / without a Juju controller)

```bash
./generate-bundle.sh -n anbox-dry --dry-run --proxy http://egress.ps7.internal:3128
```

### Replay an existing generated bundle

```bash
./generate-bundle.sh -n anbox-ps7 --replay --run
```

## Quickstart: Terraform Mode (`>= 1.30`)

`deploy-terraform.sh` clones `canonical/anbox-cloud-terraform` into `b/<name>/terraform/`, generates `b/<name>/deploy.tfvars.json` (`chmod 600`), and injects `sts_override.tf` into each module for PS7 proxy + `cloudinit-userdata` (`pro config set`), AMS proxy config, LXD machine constraints (default `cores=8 mem=16G root-disk=100G`, merged by key with `--constraints`), and optional LXD storage.

> **Note:**
> - Upstream `anbox-cloud-terraform` uses fixed Juju model names (`anbox-controller`, `anbox-subcluster-<suffix>`, `anbox-registry`), so **only one Terraform deployment is supported per Juju controller**. `deploy-terraform.sh` aborts before `apply` if any of those models already exist outside the current workspace's state.
> - Changing `--constraints`, `--lxd-constraints`, or `--lxd-storage` on an existing Terraform deployment forces replacement of the affected machines/LXD application.

### Dry-run (inspect generated `deploy.tfvars.json` and overrides)

```bash
./deploy-terraform.sh -n tf-anbox -c 1.30/stable --dry-run
```

### Plan and deploy

```bash
# Plan only
./deploy-terraform.sh -n tf-anbox -c 1.30/stable --enable-lb --plan

# Full deploy (init + plan + apply -parallelism=1)
./deploy-terraform.sh -n tf-anbox -c 1.30/stable --lxd-units 1 --enable-lb --run
```

### Deploy a pinned tag or pre-release channel

For `1.30/*` channels, `--ref` automatically defaults to `v1.30.1`; other channels default to `main`. To switch `--ref` on an existing workspace, pass `--reclone` (preserves `terraform.tfstate*`):

```bash
# Pinned 1.30.1 Terraform tag (automatic for 1.30/stable)
./deploy-terraform.sh -n tf-anbox-130 -c 1.30/stable --enable-lb --run

# Pre-release / edge channel (e.g. 1.31/beta or 1.32/edge on main)
./deploy-terraform.sh -n tf-anbox-beta -c 1.31/beta --enable-lb --run
```

### Tear down a Terraform deployment

```bash
./deploy-terraform.sh -n tf-anbox --destroy
```

## Post-Deployment

Monitor the deployment:

```bash
watch -c juju status --color --relations=true
```

Run `./configure` to check for required LXD reboots and print AMS / Dashboard access details:

```bash
./configure -m anbox-ps7
```

Automatically reboot any LXD units reporting `Reboot Required`, install missing `binder_linux` kernel modules if needed, and register your Ubuntu One account on the dashboard:

```bash
./configure -m anbox-ps7 --reboot --fix-modules --register-email you@canonical.com
```

### Accessing the Dashboard from Your Laptop

The dashboard and registration URL (`https://<gateway-lb-ip>/register?token=...`) use a private ProdStack IP that isn't directly routable from your computer. Start `sshuttle` to tunnel into the ProdStack reproducer subnet:

```bash
# PS7
sshuttle -r <ps7-bastion> 10.159.0.0/16

# PS6
sshuttle -r <ps6-bastion> 10.149.0.0/16
```

Keep `sshuttle` running, then open the exact registration URL in your browser and accept the self-signed TLS certificate warning. Prefer `sshuttle` over `ssh -L` port forwarding so the Ubuntu One OpenID callback redirects cleanly back to `<gateway-lb-ip>`. Registration tokens expire after 1 hour: re-run `./configure --register-email ...` to generate a new link if needed.

> **Note:** After `ams/0` reaches `active`, initial image synchronization from `images.anbox-cloud.io` can take a few minutes before `amc image ls` is populated (a brief `401 Unauthorized` in early `snap logs ams` before the charm finishes writing `images.auth` is normal). Also note that AMS on port `8444` is an mTLS REST API for `amc` — the web dashboard (`https://<gateway-lb-ip>/`) is only included in the full bundle (without `--core`).

## Options Reference

Run `./generate-bundle.sh --help`, `./deploy-terraform.sh --help`, or `./configure --help` for the full list of CLI flags, or inspect `module_defaults` for default channels, series/base, constraints, and `no_proxy` values.
