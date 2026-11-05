#!/bin/sh
set -eu

CADDY_CONTAINER="caddy"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"
BASE_DIR="/etc/caddy"
SNIPPET_DIR="${BASE_DIR}/snippets"
BASE_CADDYFILE="${BASE_DIR}/Caddyfile"
DOCKER_SOCK="/var/run/docker.sock"

if [ ! -S "$DOCKER_SOCK" ]; then
    echo "[caddy_compose] ERROR: Docker socket not found at $DOCKER_SOCK" >&2
    exit 1
fi

mkdir -p "$SNIPPET_DIR"

write_base_caddyfile() {
    cat <<'EOF' > "$BASE_CADDYFILE"
import /etc/caddy/snippets/*
EOF
}

reconcile() {
    echo "[caddy_compose] Running reconciliation..."

    # 1. Discover running containers with the 'caddyfile' label
    candidate_cids=$(docker ps -q --filter "label=caddyfile" --filter "status=running")

    valid_cids=""
    valid_snippets=""
    valid_count=0
    changed=0

    # 2. Validate snippets BEFORE starting or keeping Caddy alive
    for cid in $candidate_cids; do
        cname=$(docker inspect --format '{{.Name}}' "$cid" | sed 's/^\///')
        temp_file="/tmp/${cid}.test"
        snippet_file="${SNIPPET_DIR}/${cid}.caddy"

        snippet=$(docker inspect --format '{{ index .Config.Labels "caddyfile" }}' "$cid")
        if [ -z "$snippet" ]; then
            continue
        fi

        printf "%s\n" "$snippet" > "$temp_file"

        # Check syntax using local caddy binary
        if caddy validate --adapter caddyfile --config "$temp_file" >/dev/null 2>&1; then
            valid_count=$((valid_count + 1))
            valid_cids="$valid_cids $cid"
            valid_snippets="$valid_snippets ${cid}.caddy"

            if [ ! -f "$snippet_file" ] || ! cmp -s "$temp_file" "$snippet_file"; then
                mv "$temp_file" "$snippet_file"
                changed=1
                echo "[caddy_compose] Config accepted for: $cname ($cid)"
            else
                rm -f "$temp_file"
            fi
        else
            echo "[caddy_compose] Validation FAILED for container: $cname ($cid). Skipping." >&2
            rm -f "$temp_file"
        fi
    done

    # 3. Clean up stale snippet files
    for file in "$SNIPPET_DIR"/*.caddy; do
        [ -e "$file" ] || continue
        fname=$(basename "$file")
        case " $valid_snippets " in
            *" $fname "*) ;;
            *)
                echo "[caddy_compose] Removing obsolete snippet: $fname"
                rm -f "$file"
                changed=1
                ;;
        esac
    done

    # 4. If zero snippets passed validation, tear down Caddy and all dynamic networks
    if [ "$valid_count" -eq 0 ]; then
        echo "[caddy_compose] No valid 'caddyfile' configurations active."

        if docker ps -a --format '{{.Names}}' | grep -Eq "^${CADDY_CONTAINER}\$"; then
            echo "[caddy_compose] Removing ${CADDY_CONTAINER} container..."
            docker rm -f "$CADDY_CONTAINER" >/dev/null 2>&1 || true
        fi

        for net in $(docker network ls --filter "name=caddy_net_" --format '{{.Name}}'); do
            echo "[caddy_compose] Removing network: $net"
            docker network rm "$net" >/dev/null 2>&1 || true
        done

        return 0
    fi

    # 5. Ensure Caddy is running (starts only when at least 1 snippet is valid)
    caddy_just_started=0
    if ! docker ps --format '{{.Names}}' | grep -Eq "^${CADDY_CONTAINER}\$"; then
        echo "[caddy_compose] Starting ${CADDY_CONTAINER} container..."
        # Ensure the base Caddyfile is written to import the snippet directory
        write_base_caddyfile
        docker rm -f "$CADDY_CONTAINER" >/dev/null 2>&1 || true
        docker run -d \
            --name "$CADDY_CONTAINER" \
            --restart unless-stopped \
            -p 80:80 \
            -p 443:443 \
            -p 443:443/udp \
            -v caddy_compose_data:/etc/caddy:ro \
            -v ${CADDY_DATA}:/data \
            "$CADDY_IMAGE" \
            caddy run --config /etc/caddy/Caddyfile
        caddy_just_started=1
    fi

    # 6. Wire dedicated networks for valid containers
    active_nets=""
    for cid in $valid_cids; do
        cname=$(docker inspect --format '{{.Name}}' "$cid" | sed 's/^\///')
        net_name="caddy_net_${cname}"
        active_nets="$active_nets $net_name"

        if ! docker network inspect "$net_name" >/dev/null 2>&1; then
            docker network create "$net_name" >/dev/null
            echo "[caddy_compose] Created network: $net_name"
        fi

        # Attach target container
        if ! docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$cid" | grep -qw "$net_name"; then
            docker network connect --alias "$cname" "$net_name" "$cid"
            echo "[caddy_compose] Connected $cname to $net_name"
        fi

        # Attach Caddy
        if ! docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CADDY_CONTAINER" | grep -qw "$net_name"; then
            docker network connect "$net_name" "$CADDY_CONTAINER"
            echo "[caddy_compose] Connected $CADDY_CONTAINER to $net_name"
        fi
    done

    # 7. Clean up stale networks (from dead or now-invalid containers)
    for existing_net in $(docker network ls --filter "name=caddy_net_" --format '{{.Name}}'); do
        case " $active_nets " in
            *" $existing_net "*) ;;
            *)
                echo "[caddy_compose] Cleaning up stale network: $existing_net"
                docker network disconnect -f "$existing_net" "$CADDY_CONTAINER" >/dev/null 2>&1 || true
                docker network rm "$existing_net" >/dev/null 2>&1 || true
                changed=1
                ;;
        esac
    done

    # 8. Reload Caddy if configuration changed and container was already alive
    if [ "$changed" -eq 1 ] && [ "$caddy_just_started" -eq 0 ]; then
        echo "[caddy_compose] Reloading Caddy configuration..."
        docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
    fi
}

# Initial synchronization on controller start
reconcile

# Listen to Docker events
echo "[caddy_compose] Listening for Docker container events..."
docker events --filter 'type=container' \
              --filter 'event=start' \
              --filter 'event=die' \
              --filter 'event=destroy' \
              --format '{{.Actor.Attributes.name}} {{.Action}}' | while read -r name action; do
    if [ "$name" = "$CADDY_CONTAINER" ] || [ "$name" = "caddy_compose" ]; then
        continue
    fi
    echo "[caddy_compose] Event detected: $name ($action)"
    reconcile || true
done
