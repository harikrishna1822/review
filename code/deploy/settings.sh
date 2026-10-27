# Sourced by run.sh and cleanup.sh: load $1 (deploy.env) as KEY=VALUE lines.
# Plain data, never executed as shell. Variables already set in the environment win.
# One setting per line; "#" starts a comment line; quotes around the value are removed.
load_settings() {
  [ -f "$1" ] || return 0
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    value=${value%"${value##*[![:space:]]}"}          # trailing spaces
    if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
    [ -n "${!key+set}" ] || export "$key=$value"
  done < "$1"
}
