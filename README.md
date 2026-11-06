# caddy_compose

A small controller container that dynamically runs and configures [Caddy](https://caddyserver.com/) based on labels on other Docker containers. Declare a Caddyfile snippet on a container and its routes are picked up automatically as it starts, stops, or is destroyed.

## How it works

- The image is a minimal Alpine container bundling `docker-cli` and `caddy`.
- The controller runs with `network_mode: none` and the Docker socket mounted at `/var/run/docker.sock`.
- It listens for container `start`, `die`, and `destroy` events, then reconciles the desired state.
- Each container with a `caddyfile` label contributes a snippet stored at `/etc/caddy/snippets/<container-id>.caddy`.
- The base Caddyfile simply imports every snippet:

  ```caddyfile
  import /etc/caddy/snippets/*
  ```

- Every snippet is validated with `caddy validate` before use. Invalid snippets are logged and skipped.
- Caddy only runs while at least one valid snippet exists. When none remain, the Caddy container and all managed networks are removed.
- When a managed network is removed, any containers still attached (including stopped ones) are disconnected first, so their next start does not fail trying to join a missing network.
- For each valid container, a dedicated network `caddy_net_<container>` is created with `--internal` (unless opted out), so Caddy and the managed container have no external network access. Both the container (with its name as an alias) and Caddy are connected to it.
- If the configuration or volume mounts change while Caddy is already running, Caddy is reloaded or rebuilt as needed.

## Quick start

The compose file requires the `CADDY_DATA` environment variable and optionally accepts `CADDY_IMAGE` (defaults to `caddy:2-alpine`).

```sh
export CADDY_DATA=/var/lib/caddy
export CADDY_IMAGE=caddy:2-alpine # optional

docker compose up -d --build
```

Caddy is published on ports `80/tcp`, `443/tcp`, and `443/udp`.

## Container labels

### `caddyfile`

The Caddyfile snippet for the container. The snippet is imported into the base Caddyfile, so it must be a valid set of site blocks.

```yaml
services:
  app:
    image: myapp
    labels:
      caddyfile: |
        example.com {
          reverse_proxy app:3000
        }
```

Because Caddy is connected to the container's dedicated network with the container name as an alias, `reverse_proxy app:3000` resolves to the container. The snippet may contain multiple site blocks.

### `caddyfile.volumes`

A comma-separated list of `src:dst[:ro|rw]` bind mounts added to the Caddy container. Useful when a snippet serves files or needs certificates from the host.

```yaml
services:
  web:
    image: nginx
    labels:
      caddyfile: |
        example.com {
          root * /srv/www
          file_server
        }
      caddyfile.volumes: "/srv/www:/srv/www:ro, /etc/ssl/private:/etc/ssl/private:ro"
```

Whitespace around entries is ignored and duplicate mounts are de-duplicated. Changes to these mounts trigger a rebuild of the Caddy container when it is already running.

### `caddyfile.network`

Set to `false`, `0`, or `no` to skip creating a dedicated network and connecting the container to Caddy. Use this when the container is already reachable on an existing network.

```yaml
labels:
  caddyfile.network: "false"
```

## Configuration

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `CADDY_DATA` | Yes | — | Host path mounted to Caddy's `/data` directory. |
| `CADDY_IMAGE` | No | `caddy:2-alpine` | Caddy image used for the managed container. |

The compose file also creates a named volume `caddy_compose_data` mounted at `/etc/caddy`.

## Deployment

The GitHub Actions workflow in `.github/workflows/deploy.yml` deploys on every push to `master` (and can be triggered manually) using a self-hosted runner. It validates that all variables referenced in `docker-compose.yml` are defined, then runs:

```sh
docker compose up -d --build --remove-orphans
```

Required repository variables:

- `CADDY_DATA`
- `CADDY_IMAGE` (optional, defaults to `caddy:2-alpine`)

## Notes and limitations

- Snippets are imported into a shared Caddyfile; they are not full standalone Caddyfiles.
- Volume change detection for `caddyfile.volumes` only tracks bind mounts, not named volumes.
- Mounting the Docker socket gives the controller effective host-level Docker access. Run it only on trusted hosts.
