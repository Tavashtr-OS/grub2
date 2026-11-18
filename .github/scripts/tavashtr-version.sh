# Select the greatest binary rebuild of this exact Debian source version.
latest_debian_binary_version() (
  debian_version=$1
  binary_base=$debian_version
  tab=$(printf '\t')
  while IFS="$tab" read -r _binary _arch version _suite; do
    case "$version" in
      "$debian_version"+b*)
        rebuild=${version#"$debian_version"+b}
        case "$rebuild" in
          ''|*[!0-9]*) continue ;;
        esac

        if dpkg --compare-versions "$version" gt "$binary_base"; then
          binary_base=$version
        fi
        ;;
    esac
  done < "$2"
  printf '%s\n' "$binary_base"
)

normalize_debian_security_version() {
  printf '%s\n' "$1" | sed -E 's/(-[0-9]+)(deb13u[0-9]+)$/\1+\2/'
}
