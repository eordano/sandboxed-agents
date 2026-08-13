# shellcheck shell=bash
REAL_HOME=$(cat /run/env/.home 2>/dev/null || echo "/home/agent")

mkdir -p "$REAL_HOME"
chown agent:agent "$REAL_HOME"
chmod 755 "$REAL_HOME"

_fs_type="${SANDBOX_FS_TYPE:-virtiofs}"

if [ -f /run/env/.mounts ]; then
  while IFS=: read -r tag mode mpath; do
    [ -z "$tag" ] && continue
    if [ -z "$mpath" ]; then
      mpath="$mode"
      mode="rw"
    fi
    mkdir -p "$mpath"
    if [ "$_fs_type" = "9p" ]; then
      _opts="trans=virtio,version=9p2000.L,cache=mmap,msize=524288"
      [ "$mode" = "ro" ] && _opts="$_opts,ro"
      mount -t 9p -o "$_opts" "$tag" "$mpath" ||
        echo "Warning: failed to mount 9p $tag at $mpath" >&2
    else
      mount -t virtiofs "$tag" "$mpath" ||
        echo "Warning: failed to mount virtiofs $tag at $mpath" >&2
    fi
    chown agent:agent "$mpath" 2>/dev/null || true
  done </run/env/.mounts
fi

if ! mountpoint -q "$REAL_HOME"; then
  chown agent:agent "$REAL_HOME"
  chmod 755 "$REAL_HOME"
fi

if [ -f /run/env/.staged-manifest ]; then
  while IFS=$'\t' read -r _id _dst _mode; do
    [ -z "$_id" ] && continue
    _src="/run/env/staged/$_id"
    [ -f "$_src" ] || continue
    case "$_dst" in
      HOMEREL:*) _dst="$REAL_HOME/${_dst#HOMEREL:}" ;;
    esac
    mkdir -p "$(dirname "$_dst")"
    cp "$_src" "$_dst"
    chown agent:agent "$_dst" 2>/dev/null || true
    [ -n "$_mode" ] && chmod "$_mode" "$_dst" 2>/dev/null || true
  done </run/env/.staged-manifest
fi

if [ -f /run/env/.xdg-home-mounts ]; then
  while IFS='|' read -r _tag _from _hostpath; do
    [ -z "$_tag" ] && continue
    _dst="$REAL_HOME/$_from"
    _src="$_hostpath"
    mkdir -p "$_dst"
    mount --bind "$_src" "$_dst" 2>/dev/null ||
      echo "Warning: xdgRemap bind failed: $_src -> $_dst" >&2
    chown agent:agent "$_dst" 2>/dev/null || true
  done </run/env/.xdg-home-mounts
fi

if [ -f /run/env/.nix-profile-target ]; then
  _np_target=$(cat /run/env/.nix-profile-target)
  if [ -n "$_np_target" ] && [ -d "$_np_target" ]; then
    ln -sfn "$_np_target" "$REAL_HOME/.nix-profile"
    chown -h agent:agent "$REAL_HOME/.nix-profile" 2>/dev/null || true
  fi
fi
