# Homebrew Cask for Tusk — installs BOTH the GUI app and the `tusk` CLI.
#
# This is a template. Before it works end-to-end you need:
#   1. A hosted release zip (see `make dist`) attached to a GitHub Release.
#   2. The real sha256 of that zip (replace `:no_check`).
#   3. Ideally Developer-ID signing + notarization so Gatekeeper doesn't warn.
#
# Distribute via your own tap so users can:
#   brew tap veshnu/tusk
#   brew install --cask tusk
cask "tusk" do
  version "0.1.0"
  sha256 :no_check # TODO: shasum -a 256 dist/Tusk-<version>.zip

  url "https://github.com/veshnu/tusk/releases/download/v#{version}/Tusk-#{version}.zip"
  name "Tusk"
  desc "AI-first, open-source Postgres client with a built-in MCP server"
  homepage "https://github.com/veshnu/tusk"

  depends_on formula: "libpq"

  app "Tusk.app"
  binary "tusk" # the CLI ships alongside Tusk.app in the release zip

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
