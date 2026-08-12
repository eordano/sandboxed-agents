{
  lib,
  nixosTests,
  buildGoModule,
  fetchFromGitHub,
  iproute2,
  iptables,
  makeWrapper,
  procps,
  glibc,
}:

buildGoModule {
  pname = "gvisor";
  version = "20260622.0";

  src = fetchFromGitHub {
    owner = "google";
    repo = "gvisor";
    rev = "69c2d17aea96695efb4d900b261b9d4b18bb55d9";
    hash = "sha256-7t1MOxWZKJ33Wh8kasg0wA2ylYzom/mUiZqkftR2JLw=";
  };

  postPatch = ''
    substituteInPlace runsc/container/container.go \
      --replace-fail '"/sbin/ldconfig"' '"${glibc}/bin/ldconfig"'
  '';

  # Upstream's go.mod is not `go mod tidy`-clean (they build with bazel);
  # proxyVendor skips the vendor consistency check that would reject it.
  proxyVendor = true;
  vendorHash = "sha256-C8jWHf8yULItemzke7hCSfWeWVY2MwrrMNKQ0YdBfRo=";

  nativeBuildInputs = [ makeWrapper ];

  env.CGO_ENABLED = 0;

  ldflags = [
    "-s"
    "-w"
  ];

  subPackages = [
    "runsc"
    "shim"
  ];

  postInstall = ''
    wrapProgram $out/bin/runsc \
      --prefix PATH : ${
        lib.makeBinPath [
          iproute2
          iptables
          procps
        ]
      }
    mv $out/bin/shim $out/bin/containerd-shim-runsc-v1
  '';

  passthru.tests = { inherit (nixosTests) gvisor; };

  meta = {
    description = "Application Kernel for Containers";
    homepage = "https://github.com/google/gvisor";
    license = lib.licenses.asl20;
    maintainers = with lib.maintainers; [ gpl ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
