#!/bin/bash
# Sill Desktop Host: builds SillDesktopHost.app, an unofficial build of Sill's Mac host, from this
# folder (mac-host/ in github.com/NateHag/Sill-Viewer). Adapted from Sill's Scripts/make-app.sh.
#
#   Scripts/make-app.sh --install --open    build, put it in /Applications, start it
#
# It quits Sill.app first (both would answer on the network as this Mac), and signs with your first
# "Apple Development" identity, so Screen Recording and Accessibility survive rebuilds.
#
# What follows is Sill's script, with the app's file names changed.
# Builds Sill.app, the menu bar Mac host, from this SwiftPM package.
#
#   Scripts/make-app.sh                    .build/Sill.app, signed with your Apple Development identity
#   Scripts/make-app.sh --install          …then replace /Applications/Sill.app (a running copy quits first)
#   Scripts/make-app.sh --install --open   …and launch it: Noah's one command after any change
#   SILL_SIGN_IDENTITY='Developer ID Application: … (9B2KKVM937)' Scripts/make-app.sh --release
#                                          (M6; refused unless HEAD carries the tag v‹version› and
#                                          the signature is Developer ID; Scripts/release.sh --dry-run
#                                          sets SILL_RELEASE_DRY_RUN=1, which only warns about the tag)
#   SILL_INSTALL_DIR=~/Applications Scripts/make-app.sh --install   (another install folder)
#
# Why a script: SwiftPM builds executables, not app bundles, and everything the host needs from
# macOS belongs to an app bundle. Screen Recording, Accessibility, Local Network and Login Items
# are granted to the CFBundleIdentifier plus the code's designated requirement. So: swift build,
# wrap the SillMenuBar executable with Packaging/Info.plist and an icon compiled from
# design/AppIcon.svg, sign the whole bundle last, verify.
#
# Grants survive rebuilds only with a real identity: its designated requirement names the bundle ID
# and the certificate, not this binary. Ad hoc ("-") is a hash of this exact build, so every
# rebuild would silently lose Screen Recording and Accessibility.
set -euo pipefail
cd "$(dirname "$0")/.."

install=0; open_app=0; release=0
for arg in "$@"; do
    case "$arg" in
        --install) install=1 ;;
        --open) open_app=1 ;;
        --release) release=1 ;;
        *) echo "usage: $0 [--install] [--open] [--release]" >&2; exit 2 ;;
    esac
done
# --release is for notarization, which accepts only a Developer ID Application signature and says
# so only after the upload. The default identity is Apple Development, so without
# SILL_SIGN_IDENTITY stop now, before building; the signature itself is checked after signing.
if [ "$release" = 1 ] && [ -z "${SILL_SIGN_IDENTITY:-}" ]; then
    echo "error: --release needs SILL_SIGN_IDENTITY='Developer ID Application: … (9B2KKVM937)'" >&2
    exit 2
fi
# A release is built only from the commit its tag names: the tag is "v" + Packaging/Info.plist's
# CFBundleShortVersionString (v0.4.0 for 0.4.0), and every Sill.app's update check compares the
# latest release's tag on GitHub with the version it runs (Sources/SillMenuBar/UpdatePolicy.swift).
# A rehearsal (release.sh --dry-run, which sets SILL_RELEASE_DRY_RUN=1) builds any commit and only
# warns: its zip is never notarized, so it is never published.
if [ "$release" = 1 ]; then
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
    tags="$(git tag --points-at HEAD 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true)"
    if ! git tag --points-at HEAD 2>/dev/null | grep -Fx "v$version" >/dev/null; then   # -F: dots are dots
        if [ "${SILL_RELEASE_DRY_RUN:-}" = 1 ]; then
            echo "warning: HEAD is not tagged v$version (it is tagged '${tags:-nothing}'); a dry run builds it anyway, a release only a commit tagged v$version." >&2
        else
            echo "error: --release builds only a commit tagged v$version (HEAD is tagged '${tags:-nothing}'): the update check compares the release's tag with this version." >&2
            exit 2
        fi
    fi
fi

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Packaging/Info.plist)"

swift build -c release --product SillMenuBar
bin="$(swift build -c release --product SillMenuBar --show-bin-path)"
app=.build/SillDesktopHost.app
stage=.build/SillDesktopHost.app.partial      # assembled aside, so a failed run never leaves half a bundle
rm -rf "$stage"
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources"
# The executable, with the SDK it was compiled against recorded in it. SwiftPM links without
# SDKROOT, so the linker records the deployment target (14.0) as the SDK, and macOS 26 and later
# then draw the whole app in the look of a pre-26 app (Settings' sections, buttons, pop-ups and
# segmented controls). vtool writes the copy with the build version an Xcode build would have:
# minos from the binary, sdk from the SDK in use. The signature this breaks is replaced below.
minos="$(xcrun vtool -show-build "$bin/SillMenuBar" | awk '$1 == "minos" && !found { print $2; found = 1 }')"
xcrun vtool -set-build-version macos "${minos:?vtool reported no deployment target for $bin/SillMenuBar}" \
    "$(xcrun --sdk macosx --show-sdk-version)" -output "$stage/Contents/MacOS/SillDesktopHost" "$bin/SillMenuBar"
cp Packaging/Info.plist "$stage/Contents/Info.plist"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$stage/Contents/Info.plist"
printf 'APPL????' > "$stage/Contents/PkgInfo"

# The icon. design/AppIcon.svg is the iOS art, a full-bleed square. macOS 26+ masks and lights a
# full-bleed icon itself when it comes from an asset catalog, but shows a legacy .icns shrunk
# inside a grey tile (seen on macOS 27). So Quick Look renders the SVG (design/README.md's own
# tool), the render becomes the one layer of an Icon Composer document, and actool, the compiler
# Xcode uses, turns that into Assets.car (macOS 26+) plus an AppIcon.icns masked for macOS 14–15.
# A layered Packaging/AppIcon.icon made in Icon Composer (the SVG's four groups) wins when it
# exists. Cached in .build/icon until the SVG, that document or this script changes.
icon_out="$PWD/.build/icon"   # absolute: actool resolves relative paths in its helper's directory, not ours
if [ ! -f "$icon_out/compiled/Assets.car" ] || [ design/AppIcon.svg -nt "$icon_out/compiled/Assets.car" ] \
   || [ "$0" -nt "$icon_out/compiled/Assets.car" ] \
   || { [ -d Packaging/AppIcon.icon ] && [ -n "$(find Packaging/AppIcon.icon -newer "$icon_out/compiled/Assets.car" 2>/dev/null)" ]; }; then
    rm -rf "$icon_out"; mkdir -p "$icon_out/compiled"
    if [ -d Packaging/AppIcon.icon ]; then
        doc="$PWD/Packaging/AppIcon.icon"
    else
        doc="$icon_out/AppIcon.icon"
        mkdir -p "$doc/Assets"
        qlmanage -t -s 1024 -o "$icon_out" "$PWD/design/AppIcon.svg" >/dev/null 2>&1 || true
        mv "$icon_out/AppIcon.svg.png" "$doc/Assets/Sill.png" 2>/dev/null || true
        cat > "$doc/icon.json" <<'JSON'
{
  "fill" : { "solid" : "srgb:0.00000,0.00000,0.00000,1.00000" },
  "groups" : [ { "layers" : [ { "image-name" : "Sill.png", "name" : "Sill" } ] } ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
JSON
    fi
    if [ -f "$doc/icon.json" ] && { [ "$doc" = "$PWD/Packaging/AppIcon.icon" ] || [ -f "$doc/Assets/Sill.png" ]; }; then
        xcrun actool --compile "$icon_out/compiled" --platform macosx --minimum-deployment-target 14.0 \
            --app-icon AppIcon --output-partial-info-plist "$icon_out/partial.plist" "$doc" >/dev/null \
            || echo "warning: actool could not compile the icon; Sill.app gets the generic icon" >&2
    else
        echo "warning: Quick Look did not render design/AppIcon.svg; Sill.app gets the generic icon" >&2
    fi
fi
cp "$icon_out"/compiled/* "$stage/Contents/Resources/" 2>/dev/null || true

# SILL_SIGN_IDENTITY (a name, part of one, or a SHA-1 hash), else the first Apple Development
# identity in the keychain, by its SHA-1 hash: codesign refuses a name that two valid
# certificates share, as they do after an early renewal until the old one expires. Either of them
# keeps the grants, because the designated requirement names the leaf certificate's common name,
# which a renewal keeps. (`|| true`: no keychain or no match must fall through to the ad hoc
# warning below, not end the script under `set -e`.)
identity="${SILL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2; exit }' || true)}"
if [ -z "$identity" ]; then
    identity="-"
    echo "warning: no Apple Development identity in the keychain; signing ad hoc. Screen Recording and" >&2
    echo "         Accessibility will have to be granted again after every rebuild." >&2
fi
if [ "$release" = 1 ]; then
    # Developer ID: hardened runtime and a secure timestamp (notarization needs both), no get-task-allow.
    #
    # The identity items' keychain (docs/keychain-plan.md): with a Developer ID provisioning profile
    # that authorises the access group, embed it and sign with Packaging/SillRelease.entitlements, so
    # Sill.app keeps its key and trust list in the data-protection keychain, which no other process
    # can pre-create or read. Without the profile, sign without those entitlements: they are
    # profile-restricted, so a build that carried them without a matching profile would pass codesign
    # yet be killed by AMFI at launch. The profile-free build is a valid, notarizable Developer ID
    # app that keeps its identity in the login keychain (the same store as before this change) — safe,
    # and said in the log so the softer keychain is never a silent surprise.
    #
    # SillRelease.entitlements holds exactly three profile-restricted entitlements —
    # com.apple.application-identifier 9B2KKVM937.me.saffer.sill.mac,
    # com.apple.developer.team-identifier 9B2KKVM937 and keychain-access-groups
    # [9B2KKVM937.me.saffer.sill.mac] — and NO XML comments: codesign feeds it to AMFI's entitlement
    # parser (AMFIUnserializeXML), which rejects a comment with "syntax error", so a commented file
    # fails the sign. The application identifier goes under the macOS key: a Mac profile grants
    # com.apple.application-identifier, never iOS's application-identifier, and an app signed with
    # the iOS key is refused at every launch ("Unsatisfied entitlements: application-identifier",
    # then AMFI's kill; measured with the real profile, 2026-09-27). A development build must never
    # carry these either: it is signed with the Apple Development certificate, which the Developer
    # ID profile does not list, so it would be killed at launch too (measured the same day); the
    # default path below keeps SillDebug.entitlements.
    ents=Packaging/SillRelease.entitlements
    profile="${SILL_PROVISION_PROFILE:-Packaging/embedded.provisionprofile}"
    group="$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$ents")"
    if [ -f "$profile" ]; then
        # What macOS checks at every launch of an app with a profile (taskgated, then AMFI), checked
        # here instead, so a build it would kill is never written: every entitlement the app is
        # signed with is one the profile grants (the same value, or for each element of a list such
        # as the keychain groups the same name or a pattern that covers it: a Developer ID profile
        # grants "9B2KKVM937.*"), the certificate that signs it is one the profile lists, and the
        # profile has not expired. Each refusal takes the stage with it.
        prof_dir="$(mktemp -d)"; trap 'rm -rf "$prof_dir"' EXIT
        refuse_profile() {
            rm -rf "$stage"
            echo "error: the provisioning profile '$profile' $1 (docs/release-checklist.md, Part 1 §5)." >&2
            exit 1
        }
        # Whether the profile's list element $2 (a keychain group) covers the one asked for, $1: the
        # same name, or a pattern ending in * whose prefix $1 starts with.
        group_covered() {
            case "$2" in
                *\*) [ -z "${2%\*}" ] || [ "${1#"${2%\*}"}" != "$1" ] ;;
                *) [ "$1" = "$2" ] ;;
            esac
        }
        if ! security cms -D -i "$profile" -o "$prof_dir/prof.plist" 2>/dev/null; then
            refuse_profile "could not be decoded"
        fi
        # Every entitlement the file asks for, by the file's own list of them, so one added later is
        # checked too: an app signed with one the profile does not grant is killed at launch like
        # the rest (taskgated "Unsatisfied entitlements: com.apple.developer.icloud-services",
        # measured 2026-09-27, when this check named only the keys it knew and wrote that app). One
        # value (the application identifier, the team) must be the profile's own; each element of a
        # list (the keychain groups) one the profile grants. Stricter than taskgated, which passes
        # an entitlement no profile restricts: this file holds only what the profile grants. plutil
        # lists the keys, one a line, of a dictionary under a key (it has no key path for a plist's
        # own top level, hence the wrapper); PlistBuddy reads the values, since its ":" key paths
        # keep the dots in the names, and prints a missing key's error on stdout, so its output
        # counts only when it succeeds.
        if ! plutil -create xml1 "$prof_dir/ents.plist" >/dev/null 2>&1 \
            || ! plutil -insert e -xml "$(plutil -convert xml1 -o - "$ents")" "$prof_dir/ents.plist" >/dev/null 2>&1 \
            || ! wanted_keys="$(plutil -extract e raw -o - "$prof_dir/ents.plist" 2>/dev/null)"; then
            rm -rf "$stage"; echo "error: $ents is not a property list of entitlements." >&2; exit 1
        fi
        for key in $wanted_keys; do
            if /usr/libexec/PlistBuddy -c "Print :$key:0" "$ents" >/dev/null 2>&1; then
                i=0
                while wanted="$(/usr/libexec/PlistBuddy -c "Print :$key:$i" "$ents" 2>/dev/null)"; do
                    covered=0; j=0; patterns=""
                    while pattern="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key:$j" "$prof_dir/prof.plist" 2>/dev/null)"; do
                        if group_covered "$wanted" "$pattern"; then covered=1; fi
                        patterns="$patterns ${pattern}"; j=$((j + 1))
                    done
                    if [ "$covered" != 1 ]; then
                        refuse_profile "grants $key [${patterns# }], none of them '$wanted'; an app signed with it would be killed at launch"
                    fi
                    i=$((i + 1))
                done
            else
                wanted="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ents" 2>/dev/null)" || wanted=""
                case "$wanted" in
                    ""|"Array {"*|"Dict {"*)
                        rm -rf "$stage"
                        echo "error: $ents asks for $key as an empty value, an empty list or a dictionary, which make-app.sh can't compare with a profile; leave it out or teach this check." >&2
                        exit 1 ;;
                esac
                granted="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$prof_dir/prof.plist" 2>/dev/null)" || granted=""
                if [ "$granted" != "$wanted" ]; then
                    refuse_profile "grants $key '${granted:-nothing}', not the '$wanted' $ents asks for; an app signed with it would be killed at launch"
                fi
            fi
        done
        # The profile must not be expired. Gatekeeper evaluates a Developer ID profile's validity at
        # every launch (developer.apple.com/support/developer-id), so an app that embeds an expired
        # one will not launch — and there is no login-keychain fallback once it is embedded, unlike
        # the no-profile path above. Refuse it here (renewing: download it again from the developer
        # site, docs/release-checklist.md), and warn when it is within 30 days.
        prof_exp_iso="$(plutil -extract ExpirationDate raw -o - "$prof_dir/prof.plist" 2>/dev/null || true)"
        prof_exp="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "${prof_exp_iso:-}" +%s 2>/dev/null || true)"
        now="$(date +%s)"
        if [ -z "$prof_exp" ]; then
            rm -rf "$stage"; echo "error: the provisioning profile '$profile' has no readable ExpirationDate; refusing rather than embed a profile that might already have expired." >&2; exit 1
        elif [ "$prof_exp" -le "$now" ]; then
            rm -rf "$stage"
            echo "error: the provisioning profile '$profile' expired on ${prof_exp_iso} (UTC); an app that embeds it will not launch. Renew it (docs/release-checklist.md)." >&2
            exit 1
        elif [ "$prof_exp" -lt "$(( now + 2592000 ))" ]; then
            echo "warning: the provisioning profile '$profile' expires on ${prof_exp_iso} (UTC), within 30 days; renew it soon (docs/release-checklist.md)." >&2
        fi
        # The profile's bytes alone, none of the download's extended attributes, which would
        # otherwise ship in the app: the developer site's address (kMDItemWhereFroms), com.apple.macl
        # and the quarantine flag. cp -X drops the first two, but its copy of a quarantined file gets
        # the flag back, and ditto then keeps it in the zip and the disk image (an AppleDouble
        # ._embedded.provisionprofile with the download's quarantine record); a file cat writes gets
        # none of them (measured 2026-09-27).
        cat "$profile" > "$stage/Contents/embedded.provisionprofile"
        codesign --force --options runtime --timestamp --entitlements "$ents" --sign "$identity" "$stage"
        # After signing: the certificate that signed it must be one the profile lists. A profile
        # names the certificates it covers, so a renewed Developer ID certificate needs the profile
        # made again with it (an app signed by any other is killed at launch, measured 2026-09-27).
        codesign -d --extract-certificates="$prof_dir/signer" "$stage" 2>/dev/null || true
        signer=none
        if [ -f "$prof_dir/signer0" ]; then signer="$(shasum -a 1 "$prof_dir/signer0" | awk '{ print toupper($1) }')"; fi
        listed=""; j=0
        while cert="$(plutil -extract "DeveloperCertificates.$j" raw -o - "$prof_dir/prof.plist" 2>/dev/null)"; do
            # (|| true: an entry that isn't a certificate hashes to something no signer matches.)
            listed="$listed $( { printf '%s' "$cert" | base64 --decode | shasum -a 1 | awk '{ print toupper($1) }'; } 2>/dev/null || true)"
            j=$((j + 1))
        done
        case " $listed " in
            *" $signer "*) ;;
            *) refuse_profile "lists the certificates [${listed# }], not the one that signed this build ($signer); make the profile again with that certificate" ;;
        esac
        # And the app must carry the application identifier and the access group, or it would be
        # killed at launch too.
        codesign -d --entitlements "$prof_dir/signed.plist" --xml "$stage" >/dev/null 2>&1 || true
        if [ "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$prof_dir/signed.plist" 2>/dev/null)" != "$group" ] \
            || ! /usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$prof_dir/signed.plist" >/dev/null 2>&1; then
            rm -rf "$stage"; echo "error: the signed app does not carry the keychain access group '$group' and its application identifier." >&2; exit 1
        fi
        keychain_note="data-protection keychain (access group $group)"
    else
        codesign --force --options runtime --timestamp --sign "$identity" "$stage"
        keychain_note="login keychain (no provisioning profile at '$profile'; to harden the identity keychain, mint one — docs/release-checklist.md)"
    fi
else
    # get-task-allow lets lldb and Xcode's Attach to Process attach to the hardened app.
    codesign --force --options runtime --timestamp=none --entitlements Packaging/SillDebug.entitlements --sign "$identity" "$stage"
    keychain_note="login keychain (a development build has no keychain-access-groups entitlement)"
fi
codesign --verify --strict "$stage"
# Who signed it, read from the signature: the leaf certificate's name, empty for ad hoc.
signer="$(codesign -dv --verbose=2 "$stage" 2>&1 | sed -n 's/^Authority=//p' || true)"
signer="${signer%%$'\n'*}"
if [ "$release" = 1 ] && [[ "$signer" != "Developer ID Application: "* ]]; then
    rm -rf "$stage"
    echo "error: --release is for notarization, which accepts only a Developer ID Application signature;" >&2
    echo "       this one is '${signer:-ad hoc}'. Nothing was replaced." >&2
    exit 1
fi
rm -rf "$app"
mv "$stage" "$app"
echo "Built $app, version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist") ($build_number), signed by: ${signer:-ad hoc}"
echo "  identity keychain: ${keychain_note:-login keychain}"
codesign -d -r- "$app" 2>&1 | sed -n 's/^# *designated => /  designated requirement: /p; s/^designated => /  designated requirement: /p'

# Sill Desktop Host: a ready-made copy for Macs without Xcode, in the repo's downloads/. Commit and
# push it; other Macs install it with downloads/install-mac-host.sh (no build there).
if [ -d ../downloads ] && [ -z "${SILL_NO_ZIP:-}" ]; then
    rm -f ../downloads/SillDesktopHost-mac.zip
    ditto -c -k --keepParent "$app" ../downloads/SillDesktopHost-mac.zip
    echo "Zipped ../downloads/SillDesktopHost-mac.zip (commit and push it for your other Macs)"
fi

dest="${SILL_INSTALL_DIR:-/Applications}/SillDesktopHost.app"
if [ "$install" = 1 ]; then
    # An iPad build of the iOS client installed on this Mac would also be a Sill.app: never replace
    # anything that is not this app.
    if [ -e "$dest" ]; then
        existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null || true)"
        if [ "$existing" != "$bundle_id" ]; then
            echo "error: $dest is not the Mac host (bundle ID '${existing:-unknown}', expected '$bundle_id'); leaving it alone." >&2
            exit 1
        fi
    fi
    # Quit a running Sill.app first. SIGTERM goes through HostShutdown, which puts a staged window
    # back. The pattern matches Mac bundles only: the iOS Simulator's Sill.app is flat, and
    # `pkill -x Sill` would kill it too.
    # This app if it runs, and Sill.app too: two hosts would both answer as this Mac.
    for pat in 'SillDesktopHost\.app/Contents/MacOS/SillDesktopHost' 'Sill\.app/Contents/MacOS/Sill$'; do
        if pgrep -f "$pat" >/dev/null; then
            pkill -TERM -f "$pat" || true
            for _ in $(seq 1 50); do pgrep -f "$pat" >/dev/null || break; sleep 0.1; done
        fi
    done
    if [ -d /Applications/Sill.app ]; then
        echo "note: Sill.app is quit. Turn off its \"Open at login\" (Sill › Settings › General) so only one host runs."
    fi
    rm -rf "$dest"
    ditto "$app" "$dest"
    # One registered Sill: LaunchServices (the login item, `open -b`, Spotlight) must not pick the
    # copy in .build.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$app" 2>/dev/null || true
    echo "Installed $dest"
fi
if [ "$open_app" = 1 ]; then
    if [ -d "$dest" ]; then open "$dest"; else echo "error: $dest is not installed; run with --install" >&2; exit 1; fi
fi
