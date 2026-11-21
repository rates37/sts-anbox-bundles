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
3. **PS6**: `http://squid.internal:3128` (tested via `nc -vz squid.internal 3128`)

When a proxy is active, `generate-bundle.sh`:
- Applies Juju `model-config` (`juju-http-proxy`, `juju-https-proxy`, `juju-no-proxy`, `apt-http-proxy`, `apt-https-proxy`, `snap-http-proxy`, `snap-https-proxy`).
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

Automatically reboot any LXD units reporting `Reboot Required` and register your Ubuntu One account on the dashboard:

```bash
./configure -m anbox-ps7 --reboot --register-email you@canonical.com
```

## Options Reference

Run `./generate-bundle.sh --help` for the full list of CLI flags, or inspect `module_defaults` for default channel, series, constraints, and `no_proxy` values.
