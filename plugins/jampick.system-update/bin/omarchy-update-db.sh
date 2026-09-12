# Resolve the temporary pacman database this plugin syncs into. Sourced, not run.
#
# checkupdates defaults to ${TMPDIR:-/tmp}/checkup-db-$UID: a predictable name
# in a directory every account on the machine can write to. Nothing read from
# it can change what an update installs, because omarchy-update goes through
# the real pacman database and never this one. But it decides which versions
# and sizes a person is shown before they agree to an update, and a decision
# input should not be a name another process can reach first.
#
# Preferred home is the per-user runtime directory, which the login session
# creates 0700 and owns, and which is not a shared namespace. It is verified
# rather than assumed. Every component is checked with lstat for being a real
# directory, owned by this user, with no group or other bits: %F rejects a
# symlink outright, because stat(1) does not follow one unless asked. A
# component that fails is never repaired, only refused, because repairing a
# path somebody else prepared is how you end up owning their symlink.
#
# Fallback is a fresh private directory inside the caller's own workdir, which
# is already 0700 from mktemp and already covered by the caller's cleanup. That
# is the "freshly created private directory" answer, and it is correct, but it
# has no database to reuse so it forces a sync every run. Hence the order:
# verified and persistent first, fresh and ephemeral only when the runtime
# directory is unavailable or fails its check.
#
# Sets UPDATE_DB, and UPDATE_DB_EPHEMERAL=1 when the fallback was taken, which
# tells the caller it cannot honour --nosync: nothing has synced this one yet.

# A real directory, owned by us, and private. Not a symlink to one.
update_db_private() {
  local info
  info=$(stat -c '%F|%u|%a' -- "$1" 2>/dev/null) || return 1
  [[ $info == "directory|$(id -u)|700" ]]
}

resolve_update_db() {
  local workdir=$1 base=${XDG_RUNTIME_DIR:-} dir

  UPDATE_DB=""
  UPDATE_DB_EPHEMERAL=0

  if [[ -n $base ]] && update_db_private "$base"; then
    dir=$base/omarchy-update-review
    mkdir -m 0700 -p -- "$dir" 2>/dev/null
    # mkdir -p leaves an existing directory's mode alone, so this check is what
    # decides whether an already-present one is usable.
    if update_db_private "$dir"; then
      mkdir -m 0700 -p -- "$dir/checkup-db" 2>/dev/null
      if update_db_private "$dir/checkup-db"; then
        UPDATE_DB=$dir/checkup-db
        return 0
      fi
    fi
  fi

  UPDATE_DB=$workdir/checkup-db
  mkdir -m 0700 -p -- "$UPDATE_DB" 2>/dev/null || return 1
  update_db_private "$UPDATE_DB" || return 1
  UPDATE_DB_EPHEMERAL=1
  return 0
}
