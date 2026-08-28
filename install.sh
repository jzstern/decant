#!/usr/bin/env zsh
#
# Installs the decant CLI and its Finder Quick Action.
#
# The Quick Action is an Automator .workflow rather than a Shortcut. A Shortcut
# that hands the Finder selection to a shell script makes macOS ask "Allow
# "Decant" to use 1 folder in a shell script?" on every run, and the grant is
# per folder, so Always Allow never ends it. Automator services do not go
# through that gate. Registering NSIconName is what puts it under Quick Actions
# with an icon instead of in the Services submenu.

emulate -L zsh
set -e

here="${0:A:h}"
bin_dir="$HOME/.local/bin"

mkdir -p "$bin_dir"
install -m 0755 "$here/bin/decant" "$bin_dir/decant"
echo "installed: $bin_dir/decant"

# The Quick Action goes in by copy — unlike a Shortcut, which macOS only lets
# the user add themselves through Shortcuts.app.
services_dir="$HOME/Library/Services"
quick_action="$services_dir/Decant.workflow"
mkdir -p "$services_dir"
rm -rf "$quick_action"
cp -R "$here/quickaction/Decant.workflow" "$quick_action"
# Without this the entry doesn't appear until the next login.
/System/Library/CoreServices/pbs -update 2>/dev/null || true
echo "installed: $quick_action"

# Remove the obsolete Service bundle from earlier versions, if present, so it
# doesn't linger in the right-click Services submenu. (Named for the Service as
# it shipped back then, not for the current tool.)
legacy="$HOME/Library/Services/→ aiff.workflow"
if [[ -e "$legacy" ]]; then
  rm -rf "$legacy"
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  echo "removed obsolete Service: $legacy"
fi

# The tool was called toaiff before it also produced MP3. Retire the old binary
# so `toaiff` doesn't linger on PATH shadowing nothing. An already-imported
# Quick Action still runs `toaiff`, so it breaks until the user re-imports —
# say so loudly rather than letting right-click fail silently.
legacy_bin="$bin_dir/toaiff"
if [[ -e "$legacy_bin" ]]; then
  rm -f "$legacy_bin"
  echo "removed previous install: $legacy_bin (now: $bin_dir/decant)"
  echo
  echo "The current Quick Action is installed above, so right-click already works."
  echo "Delete the old \"→ aiff\" shortcut in Shortcuts.app — it still runs 'toaiff'"
  echo "and will fail. See README ▸ \"Upgrading from toaiff\"."
fi

echo
echo "Installed. Try it:  $bin_dir/decant /path/to/file-or-folder"
echo "Or right-click audio in Finder ▸ Quick Actions ▸ Decant."
echo
echo "If you used the older Shortcuts-based Quick Action, delete the 'Decant'"
echo "shortcut in Shortcuts.app — otherwise two identically named entries appear"
echo "in the menu and the Shortcut one still asks permission for every folder."
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo
     echo "Tip: add $bin_dir to your PATH to call 'decant' directly." ;;
esac
