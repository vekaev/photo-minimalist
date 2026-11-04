# Sourced by build-app.sh and install-mac.sh: prints the xcodebuild settings that sign the Mac app with a real
# certificate when this Mac has one, so the app keeps the same identity on every build. macOS then keeps
# its permissions (Photos, removable volumes, the background item) across updates instead of asking again.
# An ad-hoc signature (the fallback, for anyone without a certificate) is a hash of the build itself, so
# every update looks like a new app to macOS.
#
# Picks a Developer ID Application certificate first (notarizable), else Apple Development. Override:
#   SIGN_IDENTITY=<SHA-1 from `security find-identity -v -p codesigning`>   or   SIGN_IDENTITY=-   (ad-hoc)
sign_settings() {
  local line hash name team
  if [ "${SIGN_IDENTITY:-}" = "-" ]; then echo "CODE_SIGN_IDENTITY=-"; return; fi
  if [ -n "${SIGN_IDENTITY:-}" ]; then
    line=$(security find-identity -v -p codesigning 2>/dev/null | grep "$SIGN_IDENTITY" | head -1)
  else
    line=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application:' | head -1)
    [ -n "$line" ] || line=$(security find-identity -v -p codesigning 2>/dev/null | grep '"Apple Development:' | head -1)
  fi
  if [ -z "$line" ]; then echo "CODE_SIGN_IDENTITY=-"; return; fi
  hash=$(echo "$line" | awk '{print $2}')
  name=$(echo "$line" | sed -E 's/.*"(.*)".*/\1/')
  team=$(echo "$name" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')
  # A SHA-1 keeps it one word for xcodebuild; the team lets Xcode match it without a provisioning profile.
  echo "CODE_SIGN_IDENTITY=$hash CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$team PROVISIONING_PROFILE_SPECIFIER="
}
