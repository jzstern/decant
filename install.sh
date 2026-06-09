#!/usr/bin/env zsh
#
# Installs the toaiff CLI. The right-click Finder integration is a Shortcut you
# add once via Shortcuts.app (see README "Finder Quick Action") — on macOS
# Sequoia/Tahoe a hand-built .workflow can only ever be a Service, not a true
# Quick Action, so this installer no longer ships one.

emulate -L zsh
set -e

here="${0:A:h}"
bin_dir="$HOME/.local/bin"

mkdir -p "$bin_dir"
install -m 0755 "$here/bin/toaiff" "$bin_dir/toaiff"
echo "installed: $bin_dir/toaiff"

# Remove the obsolete Service bundle from earlier versions, if present, so it
# doesn't linger in the right-click Services submenu.
legacy="$HOME/Library/Services/→ aiff.workflow"
if [[ -e "$legacy" ]]; then
  rm -rf "$legacy"
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  echo "removed obsolete Service: $legacy"
fi

echo
echo "CLI installed. Try it:  $bin_dir/toaiff /path/to/file-or-folder"
echo
echo "To add the Finder right-click Quick Action, follow the Shortcuts recipe"
echo "in README.md (section: \"Finder Quick Action\"). It takes about a minute."
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo
     echo "Tip: add $bin_dir to your PATH to call 'toaiff' directly." ;;
esac
