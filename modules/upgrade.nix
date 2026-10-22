{
  config,
  lib,
  pkgs,
  ...
}:

# Upstream's in-place upgrade (docs/configuration/upgrade-api.md), with NixOS generations in place of
# the binary it replaces: check the datastore before the switch, back it up before the new version
# starts, hold the switch until it is healthy, and restore the datastore when switching back.

let
  cfg = config.services.kubesolo;

  # The version as KubeSolo reports it, and as the kubelet reports it after "+kubesolo-".
  version = "v${cfg.package.version}";

  tool = pkgs.writeShellApplication {
    name = "kubesolo-upgrade";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnused
      gnugrep
      sqlite
      cfg.kubectl.package
    ];
    text = ''
      new=${lib.escapeShellArg version}
      binary=${lib.escapeShellArg (lib.getExe cfg.package)}
      dir=${lib.escapeShellArg "${cfg.settings.path}/nixos-upgrade"}
      db=${lib.escapeShellArg "${cfg.settings.path}/kine/db/state.db"}
      socket=${lib.escapeShellArg "${cfg.settings.path}/containerd/containerd.sock"}
      health_timeout=${toString cfg.upgrade.healthTimeout}
      export KUBECONFIG=${lib.escapeShellArg "${cfg.settings.path}/pki/admin/admin.kubeconfig"}

      # State in $dir:
      #   current   the version last started on this datastore
      #   pending   a version started but not yet healthy
      #   backup/   the datastore before the last version change, and its manifest
      #   checked   a version whose datastore check passed before the switch
      #   failed    a version whose datastore check failed at start

      log() { echo "kubesolo-upgrade: $*" >&2; }
      get() { cat "$1" 2>/dev/null || true; }
      put() { printf '%s\n' "$2" >"$1.tmp" && mv -f "$1.tmp" "$1"; }
      field() { sed -n "s/^$1=//p" "$dir/backup/manifest" 2>/dev/null || true; }

      need_space() {
        local size=0 f avail need
        for f in "$db" "$db-wal"; do
          if [ -f "$f" ]; then size=$((size + $(stat -c %s "$f"))); fi
        done
        # The backup, a copy for the dry-run, and some room.
        need=$((2 * size + 64 * 1024 * 1024))
        avail=$(df --output=avail -B1 "$dir" | tail -n 1)
        if [ "$avail" -lt "$need" ]; then
          log "not enough space in $dir: $need bytes needed, $avail available"
          return 1
        fi
      }

      # VACUUM INTO reads in one transaction and folds the WAL in, so it is safe while KubeSolo runs.
      snapshot() {
        (cd "$1" && sqlite3 -cmd '.timeout 30000' "$db" "VACUUM INTO 'state.db'")
        local result
        result=$(sqlite3 -readonly "$1/state.db" 'PRAGMA quick_check')
        if [ "$result" != ok ]; then
          log "the datastore snapshot failed its integrity check: $result"
          return 1
        fi
      }

      # The new binary opens a copy of $1 through kine, which applies kine's migrations.
      dry_run() {
        local work out
        work=$(mktemp -d "$dir/check.XXXXXX") || return 1
        cp --reflink=auto "$1" "$work/state.db" || { rm -rf "$work"; return 1; }
        if ! out=$(timeout 600 "$binary" --upgrade-check-datastore="$work/state.db" 2>&1); then
          rm -rf "$work"
          log "KubeSolo $new cannot open the datastore: ''${out##*$'\n'}"
          return 1
        fi
        rm -rf "$work"
        log "KubeSolo $new opened a copy of the datastore: ''${out##*$'\n'}"
      }

      # KillMode=process left the abandoned version's pods and shims running; like upstream's
      # rollback, stop them so the restored datastore does not get a second copy of every pod.
      stop_workloads() {
        local p
        find /sys/fs/cgroup -path '*kubepods*' -name cgroup.procs -print0 2>/dev/null |
          xargs -0r cat 2>/dev/null | xargs -r kill -9 2>/dev/null || true
        for p in /proc/[0-9]*; do
          case "$({ tr '\0' ' ' <"$p/cmdline"; } 2>/dev/null || true)" in
            *containerd-shim*"-address $socket"*) kill -9 "''${p#/proc/}" 2>/dev/null || true ;;
          esac
        done
        sleep 1
      }

      # Pre-switch check: aborts the switch while the running version is untouched.
      check() {
        case "''${2-}" in boot | dry-activate) return 0 ;; esac
        [ -f "$db" ] || return 0
        [ "$(get "$dir/current")" != "$new" ] || return 0

        mkdir -p "$dir"
        need_space
        log "checking the datastore with KubeSolo $new before switching"
        # Global, for the trap.
        work=$(mktemp -d "$dir/check.XXXXXX")
        trap 'rm -rf "$work"' EXIT
        snapshot "$work"
        dry_run "$work/state.db"
        rm -f "$dir/failed"
        put "$dir/checked" "$new"
      }

      # ExecStartPre: back up the datastore before a new version first starts, or restore it when
      # switching back from a version that never became healthy.
      prepare() {
        mkdir -p "$dir"
        rm -rf "$dir"/check.* "$dir/backup.new" "$dir/backup.old"
        local current pending
        current=$(get "$dir/current")
        pending=$(get "$dir/pending")

        if [ ! -f "$db" ]; then
          rm -f "$dir/pending"
          put "$dir/current" "$new"
          return 0
        fi
        [ "$current" != "$new" ] || return 0

        if [ -n "$pending" ] && [ "$pending" = "$current" ] &&
          [ "$(field from)" = "$new" ] && [ "$(field to)" = "$current" ]; then
          log "switching back to $new from $current, which never became healthy; restoring the datastore from before $current"
          stop_workloads
          rm -f "$db-wal" "$db-shm"
          cp --reflink=auto "$dir/backup/state.db" "$db.restore"
          mv -f "$db.restore" "$db"
          rm -rf "$dir/backup"
          log "restored the datastore of $new; changes made to the cluster under $current are lost"
        else
          if [ "$(get "$dir/failed")" = "$new" ]; then
            log "KubeSolo $new could not open this datastore; switch back to $current"
            return 1
          fi
          if [ -n "$current" ] && [ "$(field to)" = "$current" ] && [ "$(field from)" = "$new" ]; then
            log "warning: switching back to $new from $current, which became healthy; the datastore is kept, so changes made under $current stay, but $new may not understand all of them"
          fi

          log "KubeSolo changes from ''${current:-an unknown version} to $new; backing up the datastore"
          need_space
          mkdir -m 700 "$dir/backup.new"
          snapshot "$dir/backup.new"
          printf 'from=%s\nto=%s\ncreated=%s\n' "''${current:-unknown}" "$new" "$(date -u +%FT%TZ)" \
            >"$dir/backup.new/manifest"

          if [ "$(get "$dir/checked")" != "$new" ] && ! dry_run "$dir/backup.new/state.db"; then
            rm -rf "$dir/backup.new"
            put "$dir/failed" "$new"
            return 1
          fi

          # Replaced only now, so a failed check keeps the previous backup.
          if [ -d "$dir/backup" ]; then mv "$dir/backup" "$dir/backup.old"; fi
          mv "$dir/backup.new" "$dir/backup"
          rm -rf "$dir/backup.old"
        fi

        rm -f "$dir/checked" "$dir/failed"
        put "$dir/pending" "$new"
        put "$dir/current" "$new"
      }

      # The same checks as upstream's upgrade; prints the first that fails.
      health() {
        local out
        if ! out=$(kubectl --request-timeout=10s get --raw /readyz 2>&1) || [ "$out" != ok ]; then
          echo "the API server is not ready: ''${out##*$'\n'}"
          return 1
        fi
        out=$(kubectl --request-timeout=10s get nodes -o \
          jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>&1) || true
        if ! grep -qF -- "+kubesolo-$new True" <<<"$out"; then
          echo "the node is not Ready on $new: ''${out//$'\n'/; }"
          return 1
        fi
        out=$(kubectl --request-timeout=10s -n kube-system get pods -l k8s-app=coredns -o \
          jsonpath='{range .items[*]}{.metadata.deletionTimestamp}/{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>&1) || true
        if ! grep -qx '/True' <<<"$out"; then
          echo "no CoreDNS pod is ready"
          return 1
        fi
      }

      # ExecStartPost: holds the start, and so the switch, until a new version is healthy.
      verify() {
        [ "$(get "$dir/pending")" = "$new" ] || return 0
        log "waiting up to ''${health_timeout}s for KubeSolo $new to become healthy"
        local deadline=$((SECONDS + health_timeout)) since="" reason=""
        while :; do
          if reason=$(health); then
            since=''${since:-$SECONDS}
            if [ $((SECONDS - since)) -ge 30 ]; then
              rm -f "$dir/pending"
              log "KubeSolo $new is healthy"
              return 0
            fi
          else
            since=""
          fi
          if [ "$SECONDS" -ge "$deadline" ]; then
            log "KubeSolo $new did not become healthy within ''${health_timeout}s: $reason"
            if [ "$(field to)" = "$new" ] && [ "$(field from)" != unknown ]; then
              log "switching back to KubeSolo $(field from) restores its datastore from before this upgrade"
            fi
            return 1
          fi
          sleep 5
        done
      }

      case "''${1-}" in
        check) shift && check "$@" ;;
        prepare) prepare ;;
        verify) verify ;;
        *)
          echo "usage: kubesolo-upgrade check <toplevel> <action> | prepare | verify" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  options.services.kubesolo.upgrade.healthTimeout = lib.mkOption {
    type = lib.types.ints.between 60 86400;
    default = 600;
    description = ''
      Seconds a new KubeSolo version has to become healthy after a switch: the API
      server ready, the node Ready on the new version, and a CoreDNS pod ready, for
      30 seconds in a row. The switch waits for it and fails if it does not happen.
    '';
  };

  config = lib.mkIf cfg.enable {
    system.preSwitchChecks.kubesolo = ''${lib.getExe tool} check "$@"'';

    systemd.services.kubesolo.serviceConfig = {
      ExecStartPre = [ "${lib.getExe tool} prepare" ];
      ExecStartPost = [ "${lib.getExe tool} verify" ];
      # Room for the backup and datastore check before the health gate.
      TimeoutStartSec = cfg.upgrade.healthTimeout + 900;
    };
  };
}
