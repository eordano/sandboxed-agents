{
  gemini-cli,
  src,
  fetchNpmDeps,
}:

let
  version = "0.59.0";
  npmDepsHash = "sha256-bKIWXlWmz5y3sZuBFIZQh5i4AHTqNEOD9NPEtwB+3l8=";
in
gemini-cli.overrideAttrs (old: {
  inherit version src npmDepsHash;
  npmDeps = fetchNpmDeps {
    inherit src;
    name = "gemini-cli-${version}-npm-deps";
    hash = npmDepsHash;
  };

  postPatch = (old.postPatch or "") + ''
    # Upstream's workspace package.jsons pin versions that disagree with the
    # shipped lockfile (0.49.0: tar@7.5.8 -- since unpublished -- vitest,
    # clipboardy, typescript). npm would re-resolve those online and die in
    # the offline build, so align exact pins to the lockfile's resolution.
    cat > "$TMPDIR/align-pins.cjs" <<'JS'
    const fs = require("fs");
    const pkgs = JSON.parse(fs.readFileSync("package-lock.json", "utf8")).packages;
    const resolve = (ws, dep) => {
      let parts = ws ? ws.split("/") : [];
      for (;;) {
        const cand = parts.concat(["node_modules", dep]).join("/");
        if (pkgs[cand]) return pkgs[cand].version;
        if (!parts.length) return null;
        parts.pop();
      }
    };
    for (const ws of Object.keys(pkgs).filter((p) => !p.includes("node_modules"))) {
      const file = ws ? ws + "/package.json" : "package.json";
      const meta = JSON.parse(fs.readFileSync(file, "utf8"));
      let changed = false;
      for (const sect of ["dependencies", "devDependencies", "optionalDependencies"]) {
        for (const [dep, spec] of Object.entries(meta[sect] || {})) {
          const rv = resolve(ws, dep);
          if (rv && /^[0-9]/.test(spec) && spec !== rv) {
            meta[sect][dep] = rv;
            changed = true;
            console.log("align " + file + ": " + dep + " " + spec + " -> " + rv);
          }
        }
      }
      if (changed) fs.writeFileSync(file, JSON.stringify(meta, null, 2) + "\n");
    }
    JS
    node "$TMPDIR/align-pins.cjs"

    # Since 0.49.0 a bare GOOGLE_GEMINI_BASE_URL selects the (non-interactively
    # unusable) "gateway" auth type even when GEMINI_API_KEY is set, breaking
    # the sandbox's base-URL override. Let the API key keep precedence.
    _cg=packages/core/src/core/contentGenerator.ts
    grep -qF "if (process.env['GOOGLE_GEMINI_BASE_URL']) {" "$_cg" \
      || { echo "gemini override: gateway auth detection changed upstream; update this fixup" >&2; exit 1; }
    sed -i "s|if (process.env\['GOOGLE_GEMINI_BASE_URL'\]) {|if (process.env['GOOGLE_GEMINI_BASE_URL'] \&\& !process.env['GEMINI_API_KEY']) {|" "$_cg"
  '';

  preConfigure = old.preConfigure + ''
    echo "export const GIT_COMMIT_INFO = { commitHash: 'nix' };" \
      > packages/generated/git-commit.ts
  '';
})
