{ pkgs, packageset, withSimulator ? false }:

{ #TODO
  bundleName

, #TODO
  bundleIdentifier

, #TODO
  bundleVersionString ? "1"

, #TODO
  bundleVersion ? "1"

, #TODO
  executableName

, #TODO
  package

, #TODO
  staticSrc ? ./static

, # Path to the application icons
  iconPath ? staticSrc + "/assets"

, # Information for push notifications. Is either `"production"` or
  # `"development"`, if not null.
  #
  # Requires the push notification application service to be enabled for this
  # App ID in your Apple developer account.
  apsEnv ? null

, # URL patterns for which to handle links. E.g. `[ "*.mywebsite.com" ]`.
  #
  # Requires the associated domains application service to be enabled for this
  # App ID in your Apple developer account.
  hosts ? []

# Function taking set of plist keys-value pairs and returns a new set with changes applied.
#
# For example: (super: super // { AnotherKey: "value"; })
, overrideInfoPlist ? (super: super)

, isRelease ? false

# REMOVED
, extraInfoPlistContent ? null
}:
let
  defaultInfoPlist = {
    CFBundleDevelopmentRegion = "en";
    CFBundleExecutable = executableName;
    CFBundleIdentifier = bundleIdentifier;
    CFBundleInfoDictionaryVersion = "6.0";
    CFBundleName = bundleName;
    CFBundlePackageType = "APPL";
    CFBundleShortVersionString = bundleVersionString;
    CFBundleVersion = bundleVersion;
    CFBundleSupportedPlatforms = [ "iPhoneOS" ];
    LSRequiresIPhoneOS = true;
    UILaunchStoryboardName = "LaunchScreen";
    UIRequiredDeviceCapabilities = [ "arm64" ];
    UIDeviceFamily = [ 1 2 ];
    UISupportedInterfaceOrientations = [
      "UIInterfaceOrientationPortrait"
      "UIInterfaceOrientationLandscapeLeft"
      "UIInterfaceOrientationLandscapeRight"
    ];
    ${"UISupportedInterfaceOrientations~ipad"} = [
      "UIInterfaceOrientationPortrait"
      "UIInterfaceOrientationPortraitUpsideDown"
      "UIInterfaceOrientationLandscapeLeft"
      "UIInterfaceOrientationLandscapeRight"
    ];
    ${"CFBundleIcons~ipad"} = {
      CFBundlePrimaryIcon = {
        CFBundleIconName = "Icon";
        CFBundleIconFiles = [
          "Icon-60"
          "Icon-76"
          "Icon-83.5"
        ];
      };
    };
    CFBundleIcons = {
      CFBundlePrimaryIcon = {
        CFBundleIconName = "Icon";
        CFBundleIconFiles = [
          "Icon-60"
        ];
      };
    };

    DTSDKName = "iphoneos15.0";
    DTXcode = "130"; # XCode 13.0
    DTXcodeBuild = "13A233";
    DTSDKBuild = "19A339"; # iOS 15.0
    BuildMachineOSBuild = "19G73"; # Catalina
    DTPlatformName = "iphoneos";
    DTCompiler = "com.apple.compilers.llvm.clang.1_0";
    MinimumOSVersion = "15.0";
    DTPlatformVersion = "15.0";
    DTPlatformBuild = "19A339"; # iOS 15.0
    NSPhotoLibraryUsageDescription = "Allow access to photo library.";
    NSCameraUsageDescription = "Allow access to camera.";
  };

  infoPlistData = if extraInfoPlistContent == null
    then overrideInfoPlist defaultInfoPlist
    else abort ''
      `extraInfoPlistContent` has been removed. Instead use `overrideInfoPlist` to provide an override function that modifies the default info.plist data as a nix attrset. For example: `(x: x // {NSCameraUsageDescription = "We need your camera.";})`
    '';

  # Entitlements used for development like in deploy/run-in-sim scripts.
  devEntitlementsPlist = {
    application-identifier = "<team-id/>.${bundleIdentifier}";
    "com.apple.developer.team-identifier" = "<team-id/>";
    get-task-allow = true;
    keychain-access-groups = [ "<team-id/>.${bundleIdentifier}" ];
    aps-environment = apsEnv;
    "com.apple.developer.associated-domains" =
      if hosts == [] then null else map (host: "applinks:${host}") hosts;
  };

  # Entitlements that account for release scripts like package.
  packageEntitlementsPlist = devEntitlementsPlist // {
    get-task-allow = !isRelease;
  };

  exePath = package packageset.hsPkgs;
in
pkgs.runCommand "${executableName}-app" (rec {
  infoPlist = builtins.toFile "Info.plist" (pkgs.lib.generators.toPlist {} infoPlistData);
  indexHtml = builtins.toFile "index.html" ''
    <html>
      <head>
      </head>
      <body>
      </body>
    </html>
  '';
  xcent = builtins.toFile "xcent" (pkgs.lib.generators.toPlist {} devEntitlementsPlist);
  packageXcent = builtins.toFile "xcent" (pkgs.lib.generators.toPlist {} packageEntitlementsPlist);

  deployScript = pkgs.writeText "deploy" ''
    #!/usr/bin/env bash
    set -eo pipefail

    if [ "$#" -lt 1 ]; then
      echo "Usage: $0 [TEAM_ID]" >&2
      exit 1
    fi

    TEAM_ID=$1
    shift

    set -euo pipefail

    function cleanup {
      if [ -n "$tmpdir" -a -d "$tmpdir" ]; then
        echo "Cleaning up tmpdir" >&2
        chmod -R +w $tmpdir
        rm -fR $tmpdir
      fi
    }

    trap cleanup EXIT

    tmpdir=$(mktemp -d)
    # Find the signer given the OU
    signer=$({ security find-certificate -c 'iPhone Developer' -a; security find-certificate -c 'Apple Development' -a; } \
      | grep '^    "alis"<blob>="' \
      | sed 's|    "alis"<blob>="\(.*\)"$|\1|' \
      | while read c; do \
          security find-certificate -c "$c" -p \
            | ${pkgs.libressl}/bin/openssl x509 -subject -noout; \
        done \
      | grep "OU[[:space:]]\?=[[:space:]]\?$TEAM_ID" \
      | sed 's|subject= /UID=[^/]*/CN=\([^/]*\).*|\1|' \
      | head -n 1 || true)

    if [ -z "$signer" ]; then
      echo "Error: No iPhone Developer certificate found for team id $TEAM_ID" >&2
      exit 1
    fi

    mkdir -p $tmpdir
    cp -LR "$(dirname $0)/../${executableName}.app" $tmpdir
    chmod -R +w "$tmpdir/${executableName}.app"
    mkdir -p "$tmpdir/${executableName}.app/config"

    # Fix CoreFoundation path
    install_name_tool -change /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation "$tmpdir/${executableName}.app/${executableName}"

    sed "s|<team-id/>|$TEAM_ID|" < "${xcent}" > $tmpdir/xcent
    /usr/bin/codesign --force --sign "$signer" --entitlements $tmpdir/xcent --timestamp=none "$tmpdir/${executableName}.app"

    deploy="''${IOS_DEPLOY:-${pkgs.darwin.ios-deploy}/bin/ios-deploy}"
    $deploy -W -b "$tmpdir/${executableName}.app" "$@"
  '';
  packageScript = pkgs.writeText "package" ''
    #!/usr/bin/env bash
    set -eo pipefail

    if [ "$#" -lt 3 ]; then
      echo "Usage: $0 [TEAM_ID] [IPA_DESTINATION] [EMBEDDED_PROVISIONING_PROFILE]" >&2
      exit 1
    fi

    TEAM_ID=$1
    shift
    IPA_DESTINATION=$1
    shift
    EMBEDDED_PROVISIONING_PROFILE=$1
    shift

    set -euo pipefail

    function cleanup {
      if [ -n "$tmpdir" -a -d "$tmpdir" ]; then
        echo "Cleaning up tmpdir" >&2
        chmod -R +w $tmpdir
        rm -fR $tmpdir
      fi
    }

    trap cleanup EXIT

    tmpdir=$(mktemp -d)
    # Find the signer given the OU
    signer=$({ security find-certificate -c 'iPhone Distribution' -a; security find-certificate -c 'Apple Distribution' -a; } \
      | grep '^    "alis"<blob>="' \
      | sed 's|    "alis"<blob>="\(.*\)"$|\1|' \
      | while read c; do \
          security find-certificate -c "$c" -p \
            | ${pkgs.libressl}/bin/openssl x509 -subject -noout; \
        done \
      | grep "OU[[:space:]]\?=[[:space:]]\?$TEAM_ID" \
      | sed 's|subject= /UID=[^/]*/CN=\([^/]*\).*|\1|' \
      | head -n 1)

    if [ -z "$signer" ]; then
      echo "Error: No iPhone Distribution certificate found for team id $TEAM_ID" >&2
      exit 1
    fi

    mkdir -p $tmpdir
    cp -LR "$(dirname $0)/../${executableName}.app" $tmpdir
    chmod -R +w "$tmpdir/${executableName}.app"
    strip "$tmpdir/${executableName}.app/${executableName}"
    mkdir -p "$tmpdir/${executableName}.app/config"

    # Fix CoreFoundation path
    install_name_tool -change /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation "$tmpdir/${executableName}.app/${executableName}"

    sed "s|<team-id/>|$TEAM_ID|" < "${packageXcent}" > $tmpdir/xcent
    /usr/bin/codesign --force --sign "$signer" --entitlements $tmpdir/xcent --timestamp=none "$tmpdir/${executableName}.app"

    /usr/bin/xcrun -sdk iphoneos ${./PackageApplication} -v "$tmpdir/${executableName}.app" -o "$IPA_DESTINATION" --sign "$signer" --embed "$EMBEDDED_PROVISIONING_PROFILE"

    altool=/Applications/Xcode.app/Contents/Applications/Application\ Loader.app/Contents/Frameworks/ITunesSoftwareService.framework/Versions/A/Support/altool

    if ! [ -x "$altool" ]; then
      altool=/Applications/Xcode.app/Contents/Developer/usr/bin/altool
    fi

    "$altool" --validate-app -f "$IPA_DESTINATION" -t ios "$@"
  '';
  runInSim = builtins.toFile "run-in-sim" ''
    #!/usr/bin/env bash

    if [ "$#" -ne 0 ]; then
      echo "Usage: $0" >&2
      exit 1
    fi

    set -euo pipefail

    function cleanup {
      if [ -n "$tmpdir" -a -d "$tmpdir" ]; then
        echo "Cleaning up tmpdir" >&2
        chmod -R +w $tmpdir
        rm -fR $tmpdir
      fi
    }

    trap cleanup EXIT

    tmpdir=$(mktemp -d)

    mkdir -p $tmpdir
    cp -LR "$(dirname $0)/../${executableName}.app" $tmpdir
    chmod -R +w "$tmpdir/${executableName}.app"
    mkdir -p "$tmpdir/${executableName}.app/config"
    ${../scripts/run-in-ios-sim} "$tmpdir/${executableName}.app" "${bundleIdentifier}"
  '';
  portableDeployScript = pkgs.writeText "make-portable-deploy" ''
    #!/usr/bin/env bash
    set -eo pipefail

    if [ "$#" -ne 1 ]; then
      echo "Usage: $0 [TEAM_ID]" >&2
      exit 1
    fi

    TEAM_ID=$1
    shift

    set -euo pipefail

    function cleanup {
      if [ -n "$tmpdir" -a -d "$tmpdir" ]; then
        echo "Cleaning up tmpdir" >&2
        chmod -R +w $tmpdir
        rm -fR $tmpdir
      fi
    }

    trap cleanup EXIT

    tmpdir=$(mktemp -d)
    # Find the signer given the OU
    signer=$({ security find-certificate -c 'iPhone Developer' -a; security find-certificate -c 'Apple Development' -a; } \
      | grep '^    "alis"<blob>="' \
      | sed 's|    "alis"<blob>="\(.*\)"$|\1|' \
      | while read c; do \
          security find-certificate -c "$c" -p \
            | ${pkgs.libressl}/bin/openssl x509 -subject -noout; \
        done \
      | grep "OU[[:space:]]\?=[[:space:]]\?$TEAM_ID" \
      | sed 's|subject= /UID=[^/]*/CN=\([^/]*\).*|\1|' \
      | head -n 1 || true)

    if [ -z "$signer" ]; then
      echo "Error: No iPhone Developer certificate found for team id $TEAM_ID" >&2
      exit 1
    fi

    dir="$tmpdir/${executableName}-${bundleVersion}"
    mkdir $dir

    cp -LR "$(dirname $0)/../${executableName}.app" $dir
    chmod -R +w "$dir/${executableName}.app"
    mkdir -p "$dir/${executableName}.app/config"
    sed "s|<team-id/>|$TEAM_ID|" < "${xcent}" > $dir/xcent
    /usr/bin/codesign --force --sign "$signer" --entitlements $dir/xcent --timestamp=none "$dir/${executableName}.app"

    # unsure if we can sign with same key as for iOS app, may need special permissions
    cp ${pkgs.darwin.ios-deploy}/bin/ios-deploy $dir/ios-deploy
    /usr/bin/codesign --force --sign "$signer" --timestamp=none "$dir/ios-deploy"

    cat >$dir/deploy <<'EOF'
#!/usr/bin/env bash
DIR="$( cd "$( dirname "''${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
"$DIR/ios-deploy" -W -b "$DIR/${executableName}.app" "$@"
EOF
    chmod +x $dir/deploy

    dest=$PWD/${executableName}-${bundleVersion}.tar.gz
    (cd $tmpdir && tar cfz $dest ${executableName}-${bundleVersion}/)

    echo Created $dest.
  '';}) (''
  set -x
  mkdir -p "$out/${executableName}.app"
  ln -s "$infoPlist" "$out/${executableName}.app/Info.plist"
  ln -s "$indexHtml" "$out/${executableName}.app/index.html"
  mkdir -p "$out/bin"
  cp --no-preserve=mode "$deployScript" "$out/bin/deploy"
  chmod +x "$out/bin/deploy"
  cp --no-preserve=mode "$packageScript" "$out/bin/package"
  chmod +x "$out/bin/package"
'' + pkgs.lib.optionalString withSimulator ''
  cp --no-preserve=mode "$runInSim" "$out/bin/run-in-sim"
  chmod +x "$out/bin/run-in-sim"
'' + ''
  cp --no-preserve=mode "$portableDeployScript" "$out/bin/make-portable-deploy"
  chmod +x "$out/bin/make-portable-deploy"
  cp "${exePath}/bin/${executableName}" "$out/${executableName}.app/"
  cp -RL '${staticSrc}'/* "$out/${executableName}.app/"
  for icon in '${iconPath}'/Icon*.png '${iconPath}'/AppIcon*.png; do
    cp -RL "$icon" "$out/${executableName}.app/"
  done
  for splash in '${iconPath}'/Default*.png; do
    cp -RL "$splash" "$out/${executableName}.app/"
  done
  for assets in '${iconPath}'/Assets*.car; do
    cp -RL "$assets" "$out/${executableName}.app/"
  done
  set +x
'')
