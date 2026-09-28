echo "Move Elsewhen, the world clock, into Omarchy as omarchy.elsewhen"

# The widget keeps its entry, and with it the cities and settings stored there.
config_file="$HOME/.config/omarchy/shell.json"
if [[ -s $config_file ]]; then
  tmp=$(mktemp)
  jq '
    # Every branch here carries an explicit `else .`, and that is not
    # decoration. jq 1.6 -- what Ubuntu 22.04 ships -- will not compile an
    # if/elif chain without one, so this migration failed on every deb install.
    # A jq that does tolerate the omission yields null for a branch that does
    # not match, and these are all `|=` assignments, so that would write nulls
    # over whatever the branch was guarding.
    def rename:
      if . == "omacom.elsewhen" then "omarchy.elsewhen"
      elif type == "object" and .id == "omacom.elsewhen" then .id = "omarchy.elsewhen"
      else .
      end;

    if (.bar.layout | type) == "object" then .bar.layout |= map_values(if type == "array" then map(rename) else . end) else . end |
    if (.bar.centerAnchor | type) == "string" then .bar.centerAnchor |= rename else . end |
    if (.plugins | type) == "array" then .plugins |= map(rename) else . end |
    if (.disabledPlugins | type) == "array" then .disabledPlugins |= map(rename) else . end
  ' "$config_file" >"$tmp"
  mv "$tmp" "$config_file"
fi

# Dev checkouts found the packaged plugin through this link; one the user made
# elsewhere is left alone.
user_plugin="$HOME/.config/omarchy/plugins/omacom.elsewhen"
if [[ -L $user_plugin && $(readlink "$user_plugin") == /usr/share/omarchy/* ]]; then
  rm "$user_plugin"
fi

rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/omacom-elsewhen"

omarchy-pkg-drop elsewhen
