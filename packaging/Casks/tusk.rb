# Homebrew Cask for Tusk — installs BOTH the GUI app and the `tusk` CLI.
#
# Before this works end-to-end you need:
#   1. The notarized DMG (`make release`) attached to a GitHub Release.
#   2. Its real sha256 (printed at the end of `make release`; replace `:no_check`).
#
# Distribute via your own tap so users can:
#   brew tap veshnu/tusk
#   brew install --cask tusk
cask "tusk" do
  version "0.1.0"
  sha256 :no_check # TODO: shasum -a 256 dist/Tusk-<version>.dmg

  url "https://github.com/veshnu/tusk/releases/download/v#{version}/Tusk-#{version}.dmg"
  name "Tusk"
  desc "AI-first, open-source Postgres client with a built-in MCP server"
  homepage "https://github.com/veshnu/tusk"

  # No libpq dependency: Tusk.app vendors libpq (plus openssl@3 and krb5) into
  # Contents/Frameworks, so it runs on a Mac that has never seen Homebrew.

  app "Tusk.app"
  # The CLI lives inside the bundle, named `tuskcli` so it can't collide with the
  # GUI binary `Tusk` on a case-insensitive filesystem. Homebrew links it as `tusk`.
  binary "#{appdir}/Tusk.app/Contents/MacOS/tuskcli", target: "tusk"

  # Register the MCP server with Claude Code at user scope so it's ready in every
  # project. Best-effort: does nothing if the `claude` CLI isn't installed.
  postflight do
    system_command "/bin/sh", args: ["-c",
      "command -v claude >/dev/null 2>&1 && " \
      "{ claude mcp remove tusk -s user >/dev/null 2>&1; " \
      "claude mcp add tusk -s user -- '#{HOMEBREW_PREFIX}/bin/tusk' mcp; } || true"]
  end

  uninstall_postflight do
    system_command "/bin/sh", args: ["-c",
      "command -v claude >/dev/null 2>&1 && claude mcp remove tusk -s user >/dev/null 2>&1 || true"]
  end

  zap trash: [
    "~/Library/Application Support/Tusk",
    "~/Library/Preferences/com.veshnu.Tusk.plist",
  ]
end
