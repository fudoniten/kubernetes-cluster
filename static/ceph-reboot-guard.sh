# ceph-reboot-guard: keep a Rook Ceph cluster from rebalancing around a node
# that is only rebooting.
#
# Before a reboot it sets the cluster-wide `noout` and `norebalance` flags and
# records this node in a marker under the `config-key` store. After boot it
# waits for the node's OSDs to rejoin and the PGs to settle, then lifts the
# flags -- but only if no other node still holds a marker, so overlapping
# reboots do not release each other's pins.
#
# Every ceph command runs inside the Rook toolbox (`kubectl exec
# deploy/rook-ceph-tools`), since the node has neither a ceph.conf nor a
# keyring of its own.
#
# The variables below the shebang (GUARD_*) are prepended by the NixOS module.

set -euo pipefail

marker="${GUARD_MARKER_PREFIX}${GUARD_NODE}"
tmpdir=""

log() { printf 'ceph-reboot-guard: %s\n' "$*" >&2; }
die() {
  log "$*"
  exit 1
}

cleanup() { if [[ -n $tmpdir ]]; then rm -rf "$tmpdir"; fi; }
trap cleanup EXIT

# Pick credentials for kubectl. A token file, where one is configured, wins:
# agents have no admin kubeconfig, and on a server the token is no worse.
setup_kube() {
  if [[ -n $GUARD_TOKEN_FILE ]]; then
    [[ -r $GUARD_TOKEN_FILE ]] ||
      die "token file $GUARD_TOKEN_FILE is not readable"
    tmpdir="$(mktemp -d)"
    # tokenFile rather than an inline token: the secret never gets copied.
    cat >"$tmpdir/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    server: "${GUARD_API_SERVER}"
    certificate-authority: "${GUARD_CA_FILE}"
users:
- name: reboot-guard
  user:
    tokenFile: "${GUARD_TOKEN_FILE}"
contexts:
- name: local
  context: {cluster: local, user: reboot-guard}
current-context: local
EOF
    export KUBECONFIG="$tmpdir/kubeconfig"
  elif [[ -r $GUARD_ADMIN_KUBECONFIG ]]; then
    export KUBECONFIG="$GUARD_ADMIN_KUBECONFIG"
  else
    die "no Kubernetes credentials: neither a token file nor a readable $GUARD_ADMIN_KUBECONFIG"
  fi
}

ceph() {
  timeout 90 kubectl --request-timeout=60s -n "$GUARD_NAMESPACE" \
    exec "deploy/$GUARD_TOOLS_DEPLOYMENT" -- ceph --connect-timeout=30 "$@"
}

ceph_reachable() { ceph health >/dev/null 2>&1; }

# OSD ids under this node's CRUSH host bucket. Rook names the bucket after the
# node's hostname label, which is the k3s node name. Empty if the node has no
# OSDs (or no bucket at all).
own_osds() { ceph osd ls-tree "$GUARD_NODE" 2>/dev/null || true; }

own_osds_up() {
  local ids
  ids="$(own_osds | jq -R 'select(length > 0) | tonumber' | jq -s -c .)"
  [[ $ids == "[]" ]] && return 0
  ceph osd dump -f json | jq -e --argjson ids "$ids" \
    '[.osds[] | select(.osd as $o | $ids | index($o)) | .up] | all(. == 1)' \
    >/dev/null
}

markers() {
  ceph config-key ls | jq -r --arg p "$GUARD_MARKER_PREFIX" \
    '.[] | select(startswith($p))'
}

has_own_marker() { markers | grep -qxF "$marker"; }

other_markers() { markers | grep -vxF "$marker" || true; }

flags_set() {
  ceph osd dump -f json |
    jq -e '(.flags // "") | split(",") | any(. == "noout" or . == "norebalance")' \
      >/dev/null
}

# Settled means every OSD that is `in` is up again, and every PG is active
# with nothing degraded or still peering. It deliberately does NOT demand
# active+clean: `norebalance` itself keeps merely-misplaced PGs from
# backfilling, so waiting for clean before lifting it could wait forever.
# Degraded PGs do still recover under `norebalance`.
settled() {
  ceph status -f json | jq -e '
    (.osdmap.osdmap // .osdmap) as $o
    | ($o.num_up_osds == $o.num_in_osds)
      and ((.pgmap.degraded_objects // 0) == 0)
      and ([.pgmap.pgs_by_state[]?.state_name
            | select((test("active") | not)
                     or test("degraded|undersized|down|peering|incomplete|stale|recover|unknown|inactive"))]
           | length == 0)' >/dev/null
}

set_flags() {
  ceph config-key set "$marker" "$(date -Is) $1" >/dev/null
  ceph osd set noout
  ceph osd set norebalance
}

unset_flags() {
  ceph osd unset norebalance
  ceph osd unset noout
}

# --- subcommands ----------------------------------------------------------

# prepare ACTION [--force]: refuse if stopping this node's OSDs would make PGs
# unavailable (unless forced), then pin the data.
cmd_prepare() {
  local action="$1" force="${2:-}"
  ceph_reachable ||
    die "cannot reach Ceph through deploy/$GUARD_TOOLS_DEPLOYMENT in namespace $GUARD_NAMESPACE"

  if [[ $force != "--force" ]]; then
    local ids
    mapfile -t ids < <(own_osds)
    if ((${#ids[@]} > 0)) && ! ceph osd ok-to-stop "${ids[@]}" >/dev/null 2>&1; then
      die "Ceph says stopping OSD(s) ${ids[*]} on $GUARD_NODE now would leave PGs unavailable (is another node still down?). Check 'ceph status', or pass --ceph-force to set the flags and $action anyway."
    fi
  fi

  set_flags "$action"
  log "set noout and norebalance for $action of $GUARD_NODE"
}

# Run from ExecStop on the way down. Catches `systemctl reboot`, deploy-rs,
# `shutdown -r` and anything else that skipped the wrapper. Best effort only:
# it never blocks or fails the shutdown.
cmd_shutdown_hook() {
  systemctl list-jobs --no-legend 2>/dev/null |
    grep -qE '(reboot|poweroff|halt|kexec)\.target' || exit 0

  if ! ceph_reachable; then
    log "shutting down, but Ceph is unreachable; flags not set"
    exit 0
  fi
  if has_own_marker; then
    exit 0
  fi
  set_flags shutdown || log "failed to set flags on shutdown"
  exit 0
}

# After boot: wait for this node's OSDs, then for the cluster, then lift the
# flags if nobody else is mid-reboot.
cmd_recover() {
  local deadline=$((SECONDS + GUARD_RECOVERY_TIMEOUT)) n=0

  until ceph_reachable; do
    ((SECONDS < deadline)) || {
      log "gave up waiting for Ceph to become reachable"
      exit 3
    }
    sleep "$GUARD_POLL_INTERVAL"
  done

  if ! has_own_marker; then
    log "no reboot marker for $GUARD_NODE; leaving flags alone"
    exit 0
  fi

  until own_osds_up; do
    ((SECONDS < deadline)) || {
      log "gave up waiting for $GUARD_NODE's OSDs to come up; flags left set"
      exit 3
    }
    ((n++ % 10 == 0)) && log "waiting for $GUARD_NODE's OSDs to come up"
    sleep "$GUARD_POLL_INTERVAL"
  done
  log "$GUARD_NODE's OSDs are up"

  n=0
  while true; do
    local others
    others="$(other_markers)"
    if [[ -n $others ]]; then
      # Another node is still mid-reboot; its own recovery lifts the flags.
      ceph config-key rm "$marker" >/dev/null
      log "other reboots still in progress (${others//$'\n'/, }); leaving flags for them"
      exit 0
    fi

    if ! flags_set; then
      ceph config-key rm "$marker" >/dev/null
      log "flags already clear"
      exit 0
    fi

    if settled; then
      unset_flags
      ceph config-key rm "$marker" >/dev/null
      log "cluster settled; unset norebalance and noout"
      exit 0
    fi

    ((SECONDS < deadline)) || {
      log "gave up waiting for the cluster to settle; flags left set. See 'ceph status' and 'ceph-reboot-guard release'."
      exit 3
    }
    ((n++ % 10 == 0)) && log "waiting for PGs to settle: $(ceph pg stat 2>/dev/null || echo unknown)"
    sleep "$GUARD_POLL_INTERVAL"
  done
}

cmd_status() {
  local flags
  flags="$(ceph osd dump -f json | jq -r '.flags // ""')"
  echo "osd flags: ${flags:-none}"
  echo "reboot markers:"
  local m found=0
  while read -r m; do
    [[ -z $m ]] && continue
    found=1
    echo "  ${m#"$GUARD_MARKER_PREFIX"}: $(ceph config-key get "$m")"
  done < <(markers)
  ((found)) || echo "  none"
  if settled; then echo "cluster: settled"; else echo "cluster: not settled"; fi
}

# Lift everything by hand: for a marker left by a node that is not coming back.
cmd_release() {
  local m
  while read -r m; do
    [[ -n $m ]] && ceph config-key rm "$m" >/dev/null
  done < <(markers)
  unset_flags
  log "cleared all reboot markers and unset norebalance and noout"
}

# exec ACTION ARGS...: the reboot/poweroff/halt wrapper.
cmd_exec() {
  local action="$1" skip=0 force=""
  shift
  local args=() a
  for a in "$@"; do
    case "$a" in
    --ceph-skip) skip=1 ;;
    --ceph-force) force="--force" ;;
    -h | --help)
      exec "$GUARD_SYSTEMD_BIN/$action" "$@"
      ;;
    *) args+=("$a") ;;
    esac
  done

  if ((skip)); then
    log "--ceph-skip: not touching Ceph flags"
  else
    ((EUID == 0)) || die "must run as root (try sudo), or pass --ceph-skip"
    setup_kube
    cmd_prepare "$action" "$force"
  fi
  cleanup
  exec "$GUARD_SYSTEMD_BIN/$action" "${args[@]}"
}

usage() {
  cat <<EOF
usage: ceph-reboot-guard <command>

  prepare [--force]   set noout+norebalance and mark this node as rebooting
  recover             wait for this node's OSDs and the cluster, then unset
  status              show flags, reboot markers and whether PGs are settled
  release             clear every marker and unset the flags now

reboot/poweroff/halt on this node run 'prepare' first. Pass --ceph-skip to
leave Ceph alone, or --ceph-force to skip the ok-to-stop check.
EOF
}

case "${1:-}" in
exec)
  shift
  cmd_exec "$@"
  ;;
prepare)
  setup_kube
  cmd_prepare manual "${2:-}"
  ;;
recover)
  setup_kube
  cmd_recover
  ;;
shutdown-hook)
  setup_kube
  cmd_shutdown_hook
  ;;
status)
  setup_kube
  cmd_status
  ;;
release)
  setup_kube
  cmd_release
  ;;
*)
  usage
  exit 2
  ;;
esac
