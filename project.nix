# NOTE: Define the interface
{ name # Name of the current project
, compiler-nix-name ? "ghc8107" # What compiler we should be using
, src # Source of the current project
, overrides ? [ ] # Overrides to packages
, extraSrcFiles ? [ ] # ExtraSrcFiles to include in the project builds
, setupCross ? true # Setup cross-compiling
, hackageOverlays ? [ ] # Overlays for hackage, to pass to the cabal solver
, allowUnfree ? false # Allow Unfree
, android_sdk_accept_license ? false # Accept android sdk license terms
, nixpkgsArgs ? { } # Extra nixpkgs arguments
, dontSplice ? [ ] # Packages to not splice
, dontHarden ? [ ] # Packages to not harden
, hardeningOpts ? [ "-fPIC" "-pie" ]
}:
let
  # TODO:
  # - Remove this let box properly
  # - Allow for pkgs to be overriden

  # Logic to bootstrap packages that isn't our local checkout
  haskell-nix = import ./submodules/haskell.nix { };
  pkgs-pre = import haskell-nix.sources.nixpkgs-unstable (haskell-nix.nixpkgsArgs);

  # Patch the packages with some commits external to our specific checkout
  remotePatches = [
    {
      url = "https://github.com/obsidiansystems/nixpkgs/commit/d39ee6b7c45deb224d95f717bd1e6e2144e09dd9.diff";
      sha256 = "sha256-stn4C43O5M0Qk80gj7YK/87qCDflnm/AwYcOXv5fErI=";
    }
    {
      url = "https://github.com/obsidiansystems/nixpkgs/commit/4516c1a5bb5d11209324bd00239448528bd5fb6d.diff";
      sha256 = "sha256-6GyCvZbuquVS++xR68e+jb4IiFPlIbbJb/kmc9uTers=";
    }
  ];

  overlay = (self: super: super.lib.optionalAttrs (super.stdenv.targetPlatform.isAndroid) {
    log = super.runCommandNoCC "log-fake" { } ''
      mkdir -p $out
      touch $out/dummy-log
    '';

    mkDerivation = drv: super.mkDerivation (drv // {
      enableHardening = [ "pie" ];
    });
  });

  # Actually patch our nixpkgs
  patchedNixpkgs = pkgs-pre.applyPatches {
    name = "patched-nixpkgs";
    src = ./submodules/nixpkgs;
    patches = map pkgs-pre.fetchpatch remotePatches;
  };

  # Our final packages with the patched commits
  pkgs = import patchedNixpkgs (haskell-nix.nixpkgsArgs // { config.overlays = [ overlay ]; config.android_sdk.accept_license = true; config.allowUnfree = true; } // nixpkgsArgs);

  checkHackageOverlays = c: v: if (hackageOverlays pkgs) == [ ] then c else v;

  # Modify ${pkg-name} to lib${pkg-name}.so
  # ex (reflex-todomvc -> libreflex-todomvc.so)
  mklibcabal = pkgsrc: pkgs.runCommandNoCC "modify-src" { } ''
    set -eux
    mkdir -p $out
    cp -r ${pkgsrc}/* $out
    ls -la $out
    sed -i 's%^executable *\(.*\)$%executable lib\1.so%i' $out/*.cabal
  '';
in
(pkgs.haskell-nix.project' ({
  inherit name compiler-nix-name;
  # cleanGit not needed too much, since we strip the git in
  # mklibcabal
  src = pkgs.haskell-nix.haskellLib.cleanGit {
    inherit name;
    src = mklibcabal src;
  };
  modules = [
    { packages."${name}".components = extraSrcFiles; }
    # Setup the saving part of splices unconditionally
    ({ config, lib, ... }: {
      config.preBuild = ''
        echo "!!! Save Splices $out/lib/haskell.nix/$pname"
        export EXTERNAL_SPLICES_SAVE="$out/lib/haskell.nix/$pname"
      '';
    })
  ] ++ overrides;
})).extend (final: prev: rec {

  # Null out haskell.nix's default cross setup, since it doesn't work
  # properly
  projectCross = builtins.abort "Haskell.nix projectCross isn't supported!";

  # This constructs a "fake" hackage to pull different packages from
  # this is used in case that something on proper hackage doesn't have
  # the version bounds for packages that we need to properly solve
  # the current project

  # Outputs:
  #  buildCommands - commands to build the generatedHackage jsons
  #  generatedHackage - generated hackage setup
  #  package-overlays - overlays to setup src properly after the solver has succeeded
  #  extra-hackage-tarballs - generated tarballs to be passed to the cabal solver
  #  extra-hackages - alias to (import generatedHackage) - use this in the project'
  hackage-driver = import ./modules/hackage-driver.nix { pkgs = pkgs-pre; modules = hackageOverlays; };

  android = (import ./modules/android/default.nix {
    inherit (pkgs) pkgs buildPackages;
    acceptAndroidSdkLicenses = true;
    # Pass the crossPkgs android-prebuilt package set
    pkg-set = crossSystems.aarch64-android-prebuilt.pkg-set;
  });

  android-x86 = (import ./modules/android/default.nix {
    inherit (pkgs) pkgs buildPackages;
    acceptAndroidSdkLicenses = true;
    pkg-set = crossSystems.x86_64-linux-android-prebuilt.pkg-set;
  });

  shells = {
    ghc = prev.shell;
    ghcjs = crossSystems.ghcjs.shell;
  };

  # The android app builder currently assumes you just pass the base name of the package
  # to the builder, and we convert it to "lib${name}.so" in there
  app = android.buildApp {
    # Package is currently just filler
    package = p: p.${name}.components.${name};
    executableName = "reflex-todomvc";
    applicationId = "org.reflexfrp.todomvc";
    displayName = "Reflex TodoMVC";
  };

  x86-app = android-x86.buildApp {
    package = p: p.reflex-todomvc.components.reflex-todomvc;
    executableName = "reflex-todomvc";
    applicationId = "org.reflexfrp.todomvc";
    displayName = "Reflex TodoMVC";
  };

  # Easy way to get to the ghcjs app
  ghcjs-app = crossSystems.ghcjs.pkg-set.config.hsPkgs."${name}".components.exes."${name}";

  # Usage of cross-driver sets up all of the various splices cruft to
  # make an easy way to setup cross-compiling with splices
  crossSystems = builtins.mapAttrs
  (a: v: let
    isGhcjs = v.targetPlatform.isGhcjs;
    isMobile = v.targetPlatform.isAndroid || v.targetPlatform.isiOS;
  in import ./modules/cross-driver.nix {
      # Project name
      inherit name;

      # Haskell.nix derives is ghcjs off of the compiler-nix-name
      # so ghc8107Splices won't cut it here
      compiler-nix-name = if isGhcjs then "ghc8107" else compiler-nix-name;

      # We don't want to rename our packages on ghcjs since we currently don't use
      # the GHCJS splices patch
      # also user-defined project src
      src = if !isMobile then src else mklibcabal src;

      # Make sure to inherit the proper overrides from the hackage-driver
      # Reference ./modules/hackage-driver.nix for more details

      extra-hackage-tarballs = checkHackageOverlays { } hackage-driver.extra-hackage-tarballs;
      extra-hackages = checkHackageOverlays [ ] hackage-driver.extra-hackages;
      inherit (final) pkg-set;

      # CrossPkgs is the attrset of the current crossSystem in the mapAttrs
      crossPkgs = v;

      # Driver to automatically setup splices
      # Reference ./modules/splice-driver.nix for more details
      splice-driver = import ./modules/splice-driver.nix {
        dontSplice = [ "fgl" "Cabal" "android-activity" ] ++ dontSplice;
      };

      # Driver to auto-apply hardening options
      # Reference ./modules/hardening-driver.nix for more details
      hardening-driver = import ./modules/hardening-driver.nix {
        dontHarden = [ "happy" "binary" "${name}" ] ++ dontHarden;
        hardeningOpts = hardeningOpts;
      };
      overrides = [
        # Easier override for users to set extra files from the package src to be included in build
        { packages.${name}.components = extraSrcFiles; }

        # Move this later, not hacky but should be in android configs specifically, due to some linker args
        # and how we combine this with gradle
        ({ config, lib, pkgs, ... }: {
          packages.${name} = {
            components.exes = lib.optionalAttrs (pkgs.stdenv.targetPlatform.isAndroid) {
              "lib${name}.so" = {
                ghcOptions = [
                  "-shared"
                  "-fPIC"
                  "-threaded"
                  "-no-hs-main"
                  "-lHSrts_thr"
                  "-lffi"
                  "-lm"
                  "-llog"
                ];
                configureFlags = [
                  "--extra-lib-dirs=${pkgs.androidndkPkgs_23b.libraries}"
                  "--ld-options=-shared"
                  "--ld-options=-no-pie"
                  "--ld-options=-Wl,--gc-sections,--version-script=${./exts/android/haskellActivity.version},-u,Java_systems_obsidian_HaskellActivity_haskellStartMain,-u,hs_main"
                ];
              };
            };
          };
        })
      ] ++ overrides ++ final.hackage-driver.package-overlays;
    })
    pkgs.pkgsCross;
})
