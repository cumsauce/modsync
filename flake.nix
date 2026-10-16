{
  description = "modsync — keep a Minecraft install's mods/ folder in sync with GitHub release jars";

  # nixos-unstable is REQUIRED: pkgs.zig_0_17 only exists there.
  # The current stable branch tops out at zig 0.16, and this project needs 0.17.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # GTK/WebKit are only needed on Linux; macOS uses the system WebKit/Cocoa
      # frameworks via the SDK. zig_0_17 is the exact compiler (pkgs.zig is 0.16).
      nativeDeps = pkgs: [ pkgs.zig_0_17 ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.pkg-config ];
      runtimeDeps = pkgs: lib.optionals pkgs.stdenv.hostPlatform.isLinux (
        with pkgs;
        [
          gtk3 # provides pkg-config module gtk+-3.0
          glib # provides glib-2.0 / gobject-2.0
          webkitgtk_4_1 # provides webkit2gtk-4.1
        ]
      );
    in
    {
      packages = forAllSystems (pkgs: rec {
        default = modsync;
        modsync = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "modsync";
          version = "0.2.0";

          src = ./.;

          nativeBuildInputs = nativeDeps pkgs;
          buildInputs = runtimeDeps pkgs;

          # Zig 0.17 renamed flags: the old `--global-cache-dir` is gone, and
          # zig build always wants a writable LOCAL cache — the store path is
          # read-only, so both caches go to $TMPDIR.
          dontSetZigDefaultFlags = true;
          zigBuildFlags = [
            "-Doptimize=ReleaseSafe"
            "-Dcpu=baseline"
          ];
          ZIG_LOCAL_CACHE_DIR = "$TMPDIR/zig-local-cache";
          ZIG_GLOBAL_CACHE_DIR = "$TMPDIR/zig-global-cache";

          preBuild = ''
            mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
          '';

          # zig build installs to ./zig-out by default.
          postInstall = ''
            mkdir -p $out
            cp -r zig-out/. $out/
          '';

          dontConfigure = true;

          meta = {
            description = "Keep a Minecraft install's mods folder in sync with GitHub release jars";
            homepage = "https://github.com/cumsauce/modsync";
            license = lib.licenses.mit;
            platforms = lib.platforms.unix;
            mainProgram = "modsync";
          };
        });
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = nativeDeps pkgs ++ runtimeDeps pkgs;

          # Keep Zig's caches inside the project so `nix develop` and a plain
          # `zig build` agree, and so nothing writes outside the working dir.
          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global"
            export ZIG_LOCAL_CACHE_DIR="$PWD/.zig-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            echo "modsync dev shell — zig $(zig version)"
          '';
        };
      });
    };
}
