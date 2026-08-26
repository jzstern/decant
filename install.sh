#!/usr/bin/env zsh
#
# Installs the decant CLI. The right-click Finder integration is a Shortcut you
# add once via Shortcuts.app (see README "Finder Quick Action") — on macOS
# Sequoia/Tahoe a hand-built .workflow can only ever be a Service, not a true
# Quick Action, so this installer no longer ships one.

emulate -L zsh
set -e

here="${0:A:h}"
bin_dir="$HOME/.local/bin"

mkdir -p "$bin_dir"
install -m 0755 "$here/bin/decant" "$bin_dir/decant"
echo "installed: $bin_dir/decant"

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
# so `toaiff` doesn't linger on PATH shadowing nothing.
legacy_bin="$bin_dir/toaiff"
if [[ -e "$legacy_bin" ]]; then
  rm -f "$legacy_bin"
  echo "removed previous install: $legacy_bin (now: $bin_dir/decant)"
fi

echo
echo "CLI installed. Try it:  $bin_dir/decant /path/to/file-or-folder"
echo
echo "To add the Finder right-click Quick Action, follow the Shortcuts recipe"
echo "in README.md (section: \"Finder Quick Action\"). It takes about a minute."
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo
     echo "Tip: add $bin_dir to your PATH to call 'decant' directly." ;;
esac
