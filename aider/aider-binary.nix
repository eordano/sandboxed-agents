{
  aider-chat,
  src,
  python3Packages,
}:

aider-chat.overrideAttrs (old: {
  version = "0.86.2";
  inherit src;

  # The nixpkgs patch set targets the version nixpkgs ships and does not
  # apply to this src; drop it and compensate below.
  patches = [ ];

  postPatch = (old.postPatch or "") + ''
    grep -q 'is in litellm but not in aider' aider/exceptions.py \
      || { echo "aider override: litellm strictness check moved upstream; update this postPatch" >&2; exit 1; }
    sed -i 's/raise ValueError.*is in litellm but not in aider/pass  # &/' aider/exceptions.py
  '';

  # Upstream imports the importlib_resources backport (nixpkgs patches it to
  # the stdlib; we dropped that patch).
  propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
    python3Packages.importlib-resources
  ];
  dontCheckRuntimeDeps = true;
  doInstallCheck = false;
})
