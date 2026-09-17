{
  commonToolHomeAllow = [
    ".cargo"
    ".config/nix"
    ".go"
    ".java"
    ".nix-channels"
    ".nix-defexpr"
    ".nix-profile"
    ".npm"
    ".yarn"
  ];

  cacheDirs = [
    "black"
    "bun"
    "cached-nix-shell"
    "deno"
    "fish"
    "fontconfig"
    "go"
    "gopls"
    "gradle"
    "huggingface"
    "jedi"
    "lua-language-server"
    "nix"
    "nix-hug"
    "npm"
    "opencode"
    "pip"
    "pnpm"
    "prisma"
    "prisma-nodejs"
    "puppeteer"
    "pylint"
    "staticcheck"
    "tokenizer"
    "typescript"
    "uv"
    "whisper"
    "yarn"
    "zig"
  ];

  boolFlags =
    let
      mk = var: on: env: { inherit var on env; };
    in
    {
      fuse = mk "ENABLE_FUSE" "allow-fuse" "SANDBOX_ALLOW_FUSE";
      ssh = mk "ENABLE_SSH" "allow-ssh" "SANDBOX_ALLOW_SSH";
      sshWrite = mk "ENABLE_SSH_WRITE" "allow-ssh-write" "SANDBOX_ALLOW_SSH_WRITE";
      gpg = mk "ENABLE_GPG" "allow-gpg" "SANDBOX_ALLOW_GPG";
      git = mk "ENABLE_GIT" "allow-git" "SANDBOX_ALLOW_GIT";
      libvirt = mk "ENABLE_LIBVIRT" "allow-libvirt" "SANDBOX_ALLOW_LIBVIRT";
      gui = mk "ENABLE_GUI" "allow-gui" "SANDBOX_ALLOW_GUI";
      nvidia = mk "ENABLE_NVIDIA" "allow-nvidia" "SANDBOX_ALLOW_NVIDIA";
      kvm = mk "ENABLE_KVM" "allow-kvm" "SANDBOX_ALLOW_KVM";
      audio = mk "ENABLE_AUDIO" "allow-audio" "SANDBOX_ALLOW_AUDIO";
      docker = mk "ENABLE_DOCKER" "allow-docker" "SANDBOX_ALLOW_DOCKER";
      allowHome = mk "ALLOW_HOME" "allow-home-access" "SANDBOX_ALLOW_HOME";
      internetAccess = mk "INTERNET_ACCESS" "allow-internet-access" "SANDBOX_INTERNET_ACCESS" // {
        default = 1;
        off = [ "no-internet-access" ];
      };
      disableNetworking = mk "DISABLE_NETWORKING" "disable-networking" "SANDBOX_DISABLE_NETWORKING";
      runsc = mk "ENABLE_RUNSC" "runsc" "SANDBOX_RUNSC";
      privacyFilter = mk "ENABLE_PRIVACY_FILTER" "privacy-filter" "SANDBOX_PRIVACY_FILTER";
      mountHomeCache = mk "MOUNT_HOME_CACHE" "mount-home-cache" "SANDBOX_MOUNT_HOME_CACHE";
      mountTmp = mk "MOUNT_TMP" "mount-tmp" "SANDBOX_MOUNT_TMP";
      mountCommonHomeFolders =
        mk "MOUNT_COMMON_HOME" "mount-common-home-folders"
          "SANDBOX_MOUNT_COMMON_HOME";
    };

  boolFlagSets = {
    linux = [
      "fuse"
      "ssh"
      "sshWrite"
      "gpg"
      "git"
      "libvirt"
      "gui"
      "nvidia"
      "kvm"
      "audio"
      "docker"
      "allowHome"
      "internetAccess"
      "disableNetworking"
      "privacyFilter"
      "mountHomeCache"
      "mountTmp"
      "mountCommonHomeFolders"
    ];
    microvm = [
      "ssh"
      "sshWrite"
      "gpg"
      "git"
      "docker"
      "libvirt"
      "nvidia"
      "fuse"
      "internetAccess"
      "disableNetworking"
      "runsc"
      "privacyFilter"
      "mountHomeCache"
      "mountTmp"
      "mountCommonHomeFolders"
    ];
    darwin = [
      "ssh"
      "sshWrite"
      "gpg"
      "git"
      "docker"
      "libvirt"
      "fuse"
      "privacyFilter"
      "mountHomeCache"
      "mountCommonHomeFolders"
    ];
  };
}
