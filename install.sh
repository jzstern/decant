#!/usr/bin/env zsh
#
# Installs the toaiff CLI and the "Convert to AIFF" Finder Quick Action.

emulate -L zsh
set -e

here="${0:A:h}"
bin_dir="$HOME/.local/bin"
services_dir="$HOME/Library/Services"
workflow="→ aiff.workflow"

mkdir -p "$bin_dir" "$services_dir"

install -m 0755 "$here/bin/toaiff" "$bin_dir/toaiff"
echo "installed: $bin_dir/toaiff"

rm -rf "$services_dir/$workflow"
cp -R "$here/$workflow" "$services_dir/$workflow"
echo "installed: $services_dir/$workflow"

# Refresh the Services menu so the Quick Action appears without a logout.
/System/Library/CoreServices/pbs -update 2>/dev/null || true

echo
echo "Done. Right-click files or folders in Finder → Quick Actions → \"→ aiff\"."
echo "Or run from Terminal: $bin_dir/toaiff /path/to/file-or-folder"
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Tip: add $bin_dir to your PATH to call 'toaiff' directly." ;;
esac
