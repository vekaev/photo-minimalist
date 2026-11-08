# Sourced by build-app.sh and install-mac.sh: prints the xcodebuild settings that sign the Mac app with a real
# certificate when this Mac has one, so the app keeps the same identity on every build. macOS then keeps
# its permissions (Photos, removable volumes, the background item) across updates instead of asking again.
# An ad-hoc signature (the fallback, for anyone without a certificate) is a hash of the build itself, so
# every update looks like a new app to macOS.
#
# Picks a Developer ID Application certificate first (notarizable), else Apple Development, and among those the
# ones of SIGN_TEAM first (the owner's own team, so a work account signed into the same Mac never signs this app).
# Override: SIGN_TEAM=<team ID>, SIGN_IDENTITY=<SHA-1 from `security find-identity -v -p codesigning`>,
# or SIGN_IDENTITY=-   (ad-hoc)
SIGN_TEAM="${SIGN_TEAM:-Y938TMNGKK}"  # the owner's own team (vekaev4@icloud.com)

# The team a certificate belongs to (its subject's OU), by SHA-1.
cert_team() {
  security find-certificate -a -Z -p 2>/dev/null | awk -v h="$1" '/SHA-1 hash:/{p=($3==h)} p' \
    | sed -n '/BEGIN/,/END/p' | openssl x509 -noout -subject 2>/dev/null | sed -nE 's/.*OU *= *([A-Z0-9]{10}).*/\1/p'
}

sign_settings() {
  local line hash team kind l
  if [ "${SIGN_IDENTITY:-}" = "-" ]; then echo "CODE_SIGN_IDENTITY=-"; return; fi
  if [ -n "${SIGN_IDENTITY:-}" ]; then
    line=$(security find-identity -v -p codesigning 2>/dev/null | grep "$SIGN_IDENTITY" | head -1)
  else
    for kind in "Developer ID Application" "Apple Development"; do
      while IFS= read -r l; do
        [ "$(cert_team "$(echo "$l" | awk '{print $2}')")" = "$SIGN_TEAM" ] && { line="$l"; break 2; }
      done < <(security find-identity -v -p codesigning 2>/dev/null | grep "\"$kind:")
    done
    [ -n "$line" ] || line=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application:' | head -1)
    [ -n "$line" ] || line=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Apple Development:' | head -1)
  fi
  if [ -z "$line" ]; then echo "CODE_SIGN_IDENTITY=-"; return; fi
  hash=$(echo "$line" | awk '{print $2}')
  team=$(cert_team "$hash")
  # A SHA-1 keeps it one word for xcodebuild; the team lets Xcode match it without a provisioning profile.
  echo "CODE_SIGN_IDENTITY=$hash CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$team PROVISIONING_PROFILE_SPECIFIER="
}
