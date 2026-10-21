# Source this hook in the current Bash session through android-connect shell-init.
# The external CLI remains responsible for connecting and validating the device.
android-connect() {
  local android_connect_environment android_connect_result
  if command android-connect "$@"; then
    case "${1:-connect}" in
      connect|fix)
        if android_connect_environment="$(command android-connect env --shell bash)"; then
          eval "$android_connect_environment" || return "$?"
        else
          android_connect_result=$?
          printf 'android-connect: connection succeeded, but the session environment could not be applied.\n' >&2
          return "$android_connect_result"
        fi
        ;;
    esac
  else
    return "$?"
  fi
  return 0
}
