# sts-anbox-bundles

Minimal `stsstack-bundles`-style generator for deploying **charmed Anbox Cloud** on **PS7**, **PS6**, and other Juju 3.x clouds.

Instead of duplicating upstream Anbox Cloud bundles, `generate-bundle.sh` deploys the official Charmhub bundle (`anbox-cloud` or `anbox-cloud-core`) with dynamically rendered Juju overlays (Ubuntu Pro token, machine constraints, LXD scaling/storage, PS7/PS6 proxy settings, HA, and Ceph/MicroCeph).

## Prerequisites

- **Juju 3.x** (3.6 LTS recommended): `sudo snap install --channel=3/stable juju`
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

Export your Ubuntu Pro token (never committed; `b/` is gitignored and `ua.yaml` is created `chmod 600`):

```bash
export UA_TOKEN="<your-ubuntu-pro-token>"
```

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

Run `./generate-bundle.sh --help` for the full list of CLI flags, or inspect `module_defaults` for default channel, series, constraints, and `no_proxy` values.
