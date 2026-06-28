#!/usr/bin/env bash
# loader-redeploy-simulation.sh — assert the boot-time image loader can
# recover when the docker image store is empty but the data disk is not.
#
# Why this exists
# ---------------
# botspace's redeploy flow does this on every iteration:
#   1. Create a fresh boot disk from the published qcow2.
#   2. Re-attach the persistent data disk that hosts /var/lib/botwork.
#   3. Boot.
#
# Step (1) wipes the docker image store. Step (2) brings back anything
# that lives under /var/lib/botwork untouched. If anything on the
# loader's path treats "I see state on the data disk" as a proxy for
# "the images are already in docker", we silently end up with no
# botwork/<svc>:local tags and every dependent unit cascades into
# failure — first seen as #92.
#
# The image-build smoke test happens on a single fresh qcow2 where the
# loader runs once with both the docker store and /var/lib/botwork
# empty, so it cannot catch this class of bug. This script forces the
# divergent state and reasserts end-state correctness.
#
# What we do
# ----------
#   1. Drop every botwork/<svc>:local tag from docker so the image
#      store no longer holds them. We do NOT touch /var/lib/botwork
#      or /var/lib/botwork-db — whatever the loader / db-init have
#      written there is exactly what would survive a real redeploy
#      (the DB credential in /var/lib/botwork-db/secret.env in
#      particular has to be preserved by botwork-db-init for postgres
#      to come back up with the same password).
#   2. Restart the loader. It MUST re-load + retag from
#      /usr/share/botwork/images/<svc>.tar.
#   3. Verify each botwork/<svc>:local tag is back via
#      `docker image inspect`. This catches "loader exited 0 but
#      didn't actually do its job" — e.g. a guard that short-circuits
#      via persistent state.
#   4. Restart the broker stack and re-run goss to assert end-state.
#      Belt and braces: goss covers the unit-level "are we running"
#      assertions; step 3 is the targeted assertion this test exists
#      for.
set -euo pipefail

SERVICES=()
for tar in /usr/share/botwork/images/*.tar; do
  [ -f "${tar}" ] || continue
  svc="$(basename "${tar}" .tar)"
  SERVICES+=("${svc}")
done
if [ "${#SERVICES[@]}" -eq 0 ]; then
  echo "FAIL: no baked image tars under /usr/share/botwork/images/" >&2
  exit 1
fi

echo "[loader-redeploy-sim] removing botwork/<svc>:local tags from docker"
for svc in "${SERVICES[@]}"; do
  if sudo docker image inspect "botwork/${svc}:local" >/dev/null 2>&1; then
    sudo docker rmi -f "botwork/${svc}:local" >/dev/null
  fi
done

echo "[loader-redeploy-sim] asserting tags are gone (pre-state)"
for svc in "${SERVICES[@]}"; do
  if sudo docker image inspect "botwork/${svc}:local" >/dev/null 2>&1; then
    echo "FAIL: botwork/${svc}:local is still present after rmi -f" >&2
    exit 1
  fi
done

echo "[loader-redeploy-sim] restarting botwork-image-loader.service"
sudo systemctl restart botwork-image-loader.service

# `systemctl restart` returns when ExecStart exits, so on a Type=oneshot
# the loader has already finished by the time we get here. Surface its
# journal even on success — useful when CI is debugging a regression.
sudo systemctl status --no-pager --lines=0 botwork-image-loader.service || true

echo "[loader-redeploy-sim] asserting all tags are back"
missing=0
for svc in "${SERVICES[@]}"; do
  if ! sudo docker image inspect "botwork/${svc}:local" >/dev/null 2>&1; then
    echo "FAIL: botwork/${svc}:local was NOT re-loaded by the loader" >&2
    missing=$((missing + 1))
  fi
done
if [ "${missing}" -gt 0 ]; then
  echo "[loader-redeploy-sim] dumping loader journal for diagnosis" >&2
  sudo journalctl -u botwork-image-loader.service --no-pager -n 100 >&2 || true
  exit 1
fi

echo "[loader-redeploy-sim] restarting broker stack to pick up new image refs"
# Restart in dependency order: db-init first (regenerates secret if
# the file got wiped — not in this test path, but keeps the unit's
# RemainAfterExit cycle clean), then postgres, then the brokers that
# After= it. Without restarting postgres first, the brokers'
# Requires=botwork-db-migrate would force-start db-migrate against a
# postgres that may or may not have transitioned through the restart
# cleanly. Explicit ordering avoids that race.
sudo systemctl restart \
  botwork-db-init.service \
  botwork-postgres.service
# Wait briefly for postgres to come back; pg_isready is the right
# probe (same as botwork-db-migrate.service's ExecStartPre uses).
for _ in $(seq 1 30); do
  if sudo docker exec botwork-postgres pg_isready -U botwork -d botwork >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# `systemctl restart botwork-postgres.service` propagates a stop to
# botwork-db-migrate.service (it has Requires=botwork-postgres) and
# then systemd queues an implicit re-activation as the dependency
# graph settles. If we kick db-migrate AGAIN ourselves in the next
# `systemctl restart`, we race the implicit cycle: the first
# `docker run --rm --name botwork-db-migrate` is mid-flight when
# SIGTERM lands, `docker rm` is async, and the second `docker run`
# fails with `Conflict. The container name "/botwork-db-migrate" is
# already in use`. That cascades into Dependency failed for every
# After= consumer (api / import / ui / config-broker /
# control-plane / session-broker / envoy / egress-envoy). First seen
# in image-build run #115; #119 was the trigger SHA but the race is
# structural, not in the bump itself.
#
# Two changes make this deterministic:
#   * botwork-db-migrate.service now has
#     `ExecStartPre=-/usr/bin/docker rm -f botwork-db-migrate` so the
#     name conflict can't recur even if a back-to-back restart hits.
#   * We wait for db-migrate to settle into `active` (it's
#     Type=oneshot RemainAfterExit=yes, so `active` means it ran
#     ExecStart to completion) before kicking downstream brokers,
#     instead of explicitly restarting it. Their Requires= keeps
#     db-migrate gated, and dropping it from the explicit list
#     removes the redundant kick that created the race.
echo "[loader-redeploy-sim] waiting for botwork-db-migrate to settle"
for _ in $(seq 1 60); do
  state=$(sudo systemctl is-active botwork-db-migrate.service 2>/dev/null || true)
  case "${state}" in
    active)
      break
      ;;
    failed)
      echo "FAIL: botwork-db-migrate.service entered failed state during postgres restart" >&2
      sudo journalctl -u botwork-db-migrate.service --no-pager -n 100 >&2 || true
      exit 1
      ;;
  esac
  sleep 1
done
if [ "${state:-}" != "active" ]; then
  echo "FAIL: botwork-db-migrate.service did not reach active in 60s (last state: ${state:-unknown})" >&2
  sudo journalctl -u botwork-db-migrate.service --no-pager -n 100 >&2 || true
  exit 1
fi

# Restart every broker-stack unit that has either (a) a dependency on
# postgres / db-migrate, or (b) a dependency on control-plane. The
# egress-envoy is in group (b): it consumes ADS from control-plane
# over a long-lived gRPC stream, and a fresh `botwork-control-plane`
# binary (different PID, different listener generation after restart)
# leaves the existing envoy with a dead stream that doesn't get a new
# LDS push — which surfaces specifically as the goss probe
# `control_plane_logged_lds_push_to_egress_envoy` failing on the
# re-run (it greps the control-plane log for `push LDS to <peer>`,
# and no peer reconnects in time when egress-envoy is the only one
# we don't bounce). Bouncing egress-envoy here forces a fresh ADS
# handshake against the freshly-restarted control-plane, which
# re-emits the LDS push log. Same shape as bouncing ingress envoy
# (which we already do) — these two need symmetric treatment.
#
# `Wants=botwork-control-plane.service` on egress-envoy is soft, so
# systemd will not propagate the control-plane restart down to us
# automatically; we have to spell it out.
sudo systemctl restart \
  botwork-api.service \
  botwork-import.service \
  botwork-ui.service \
  botwork-config-broker.service \
  botwork-control-plane.service \
  botwork-session-broker.service \
  botwork-envoy.service \
  botwork-egress-envoy.service

# Give the brokers a few seconds to settle; goss has its own short
# in-spec waits for log-line readiness probes, but the docker-run
# Active=True transition is faster than we can race.
sleep 5

sudo systemctl --failed --no-pager | tee /tmp/loader-redeploy-failed-units.txt
if grep -qE 'botwork-(image-loader|network|launcher|db-init|postgres|db-migrate|import|api|ui|config-broker|control-plane|session-broker|envoy|egress-envoy|egress-iptables)\.' \
     /tmp/loader-redeploy-failed-units.txt; then
  echo "FAIL: at least one botwork unit failed after loader re-run" >&2
  exit 1
fi

echo "[loader-redeploy-sim] re-running goss against post-redeploy state"
sudo goss -g /tmp/goss.yaml validate

# RFE #105 round-3 follow-up: deliberately NOT re-running
# goss-seeded.yaml post-restart. The session_worker_table_seeded
# probe asserts `?live=true` returns >=1 row for plugin=echo, which
# was true at echo-mcp-smoke time but is NOT guaranteed to survive
# the broker restart: the 30s grace timer for the mcp_session
# container fires inside this simulation's runtime (it restarts
# the whole broker stack + waits for things to settle, which is
# >30s end-to-end), so session-broker's `record_reap` writes
# `reaped_at` on the row, and `?live=true` legitimately returns 0.
# The pre-restart `seeded-goss` step in test-packed.yaml is the
# proof that the writer path works; "rows survive as audit data
# across restart" needs different assertions (an unfiltered query
# plus a way to identify the rows we created) and is left for a
# future probe.

echo "[loader-redeploy-sim] OK"
