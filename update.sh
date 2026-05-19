#!/bin/bash
# =============================================================================
#  bpkgs installer  —  basedlinux package manager
#  Usage: sudo bash bpkgs-install.sh
# =============================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This requires root permission."
    exit 1
fi

mkdir -p /var/lib/bpkgs/installed
chmod 755 /var/lib/bpkgs
chmod 755 /var/lib/bpkgs/installed

if [ ! -f /etc/bpkgs/repos.conf ]; then
    mkdir -p /etc/bpkgs
    cat > /etc/bpkgs/repos.conf << 'CONF'
# bpkgs repository configuration
# Format:
#   repo <name> <raw_base_url> <api_url>
#
# raw_base_url  - direct URL base for downloading .bpkg / .binbpkg files
# api_url       - GitHub API URL for package listing
#
# Example:
#   repo myrepo https://raw.githubusercontent.com/user/myrepo/main https://api.github.com/repos/user/myrepo/contents

repo official https://raw.githubusercontent.com/apiwo/bpkgs/main https://api.github.com/repos/apiwo/bpkgs/contents
CONF
    echo "Created default repo config at /etc/bpkgs/repos.conf"
fi

MSG="Installed bpkgs."
[ -f /usr/local/bin/bpkgs ] && MSG="Updated bpkgs."

cat > /usr/local/bin/bpkgs << 'BPKGS_EOF'
#!/bin/bash
# =============================================================================
#  bpkgs  —  basedlinux Package Manager
#  Repo layout:  <category>/<name>.bpkg     (source build)
#                <category>/<name>.binbpkg  (prebuilt binary)
#
#  Usage:
#    bpkgs -i <category/name>       install (binary preferred, fallback source)
#    bpkgs -i <category/name> -src  force source build
#    bpkgs -i <category/name> -bin  force binary only
#    bpkgs -r <name>                remove
#    bpkgs -s <term>                search
#    bpkgs -u                       list all packages
#    bpkgs -l                       list installed
#    bpkgs -info <category/name>    show package info
#    bpkgs -repos                   list repos
#    bpkgs -update                  update bpkgs itself
#    bpkgs makebpkg                 generate template .bpkg
# =============================================================================

REPOS_CONF="/etc/bpkgs/repos.conf"
INSTALLED_DB="/var/lib/bpkgs/installed"
SELF="/usr/local/bin/bpkgs"
PROBE_TIMEOUT=3
BPKGS_CACHE="/var/cache/bpkgs"

# ── Colour codes ──────────────────────────────────────────────────────────────
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'
C='\033[0;36m'  B='\033[1m'     Z='\033[0m'
DIM='\033[2m'

info()  { echo -e "${C}${B}[bpkgs]${Z} $*"; }
ok()    { echo -e "${G}${B}[  OK ]${Z} $*"; }
warn()  { echo -e "${Y}${B}[ WRN ]${Z} $*"; }
die()   { echo -e "${R}${B}[ ERR ]${Z} $*" >&2; exit 1; }
step()  { echo -e "\n${B}───── $* ${Z}"; }

mkdir -p "$BPKGS_CACHE"

# ── Load repo config ──────────────────────────────────────────────────────────
declare -a REPO_NAMES=()
declare -a REPO_RAW=()
declare -a REPO_API=()

load_repos() {
    if [ ! -f "$REPOS_CONF" ]; then
        REPO_NAMES=("official")
        REPO_RAW=("https://raw.githubusercontent.com/apiwo/bpkgs/main")
        REPO_API=("https://api.github.com/repos/apiwo/bpkgs/contents")
        return
    fi
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "${line// }" ]] && continue
        if [[ "$line" =~ ^repo[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
            REPO_NAMES+=("${BASH_REMATCH[1]}")
            REPO_RAW+=("${BASH_REMATCH[2]}")
            REPO_API+=("${BASH_REMATCH[3]}")
        fi
    done < "$REPOS_CONF"
    if [ ${#REPO_NAMES[@]} -eq 0 ]; then
        REPO_NAMES=("official")
        REPO_RAW=("https://raw.githubusercontent.com/apiwo/bpkgs/main")
        REPO_API=("https://api.github.com/repos/apiwo/bpkgs/contents")
    fi
}

load_repos

# ── Help ──────────────────────────────────────────────────────────────────────
show_help() {
    echo -e "${B}bpkgs${Z} — basedlinux Package Manager"
    echo
    echo -e "  ${B}Install / Remove:${Z}"
    echo -e "  ${C}bpkgs -i <category/name>${Z}        Install package (binary preferred)"
    echo -e "  ${C}bpkgs -i <category/name> -src${Z}   Force source build"
    echo -e "  ${C}bpkgs -i <category/name> -bin${Z}   Binary only (fail if not found)"
    echo -e "  ${C}bpkgs -r <name>${Z}                 Remove installed package"
    echo -e "  ${C}bpkgs -rr <name>${Z}                Force remove (no prompt)"
    echo -e "  ${C}bpkgs -n <category/name>${Z}        Install without confirmation"
    echo -e "  ${C}bpkgs -nodeps <category/name>${Z}   Skip dependency resolution"
    echo -e "  ${C}bpkgs -k <category/name>${Z}        Keep build files after install"
    echo
    echo -e "  ${B}Info / Search:${Z}"
    echo -e "  ${C}bpkgs -u${Z}                        List all available packages"
    echo -e "  ${C}bpkgs -u <reponame>${Z}             List packages from specific repo"
    echo -e "  ${C}bpkgs -s <term>${Z}                 Search across all repos"
    echo -e "  ${C}bpkgs -info <category/name>${Z}     Show package details"
    echo -e "  ${C}bpkgs -l${Z}                        List installed packages"
    echo
    echo -e "  ${B}Repos / Misc:${Z}"
    echo -e "  ${C}bpkgs -repos${Z}                    Show configured repositories"
    echo -e "  ${C}bpkgs -update${Z}                   Update bpkgs itself"
    echo -e "  ${C}bpkgs -upgrade${Z}                  Upgrade all installed packages"
    echo -e "  ${C}bpkgs makebpkg${Z}                  Generate .bpkg template"
}

# ── Generate template ─────────────────────────────────────────────────────────
makebpkg_cmd() {
    cat > template.bpkg << 'TEMPLATE'
#bpkg
name="mypkg"
desc="A short description."
info="https://example.com"
version="1.0.0"
license="GPLv2"
maintainer="you"
arch="x86_64"
priority="optional"
depends="gcc, make"
build-type="tarball"
download="https://example.com/mypkg-1.0.0.tar.gz"

build() {
    ./configure --prefix=/usr
    make -j"$(nproc)"
}

instructions() {
    make DESTDIR="$BPKG_DEST" install
}
TEMPLATE
    ok "Created template.bpkg"
    exit 0
}

# ── Fetch a .bpkg or .binbpkg file from repos ─────────────────────────────────
# $1 = category/name (e.g. app-terminal/kitty)
# $2 = "src" | "bin" | "" (preference)
# Sets globals: FETCHED_REPO_NAME, FETCHED_REPO_INDEX, FETCHED_TYPE (src|bin)
FETCHED_REPO_NAME=""
FETCHED_REPO_INDEX=0
FETCHED_TYPE=""

fetch_bpkg() {
    local pkg="$1"          # e.g. "app-terminal/kitty" or bare "kitty"
    local prefer="${2:-}"   # src | bin | ""

    # Normalise: if no slash, search all categories
    local cat_given=false
    echo "$pkg" | grep -q "/" && cat_given=true

    local target_src="/tmp/bpkgs_${pkg//\//_}.bpkg"
    local target_bin="/tmp/bpkgs_${pkg//\//_}.binbpkg"

    # Helper: try a URL
    _try_url() {
        local url="$1" dest="$2"
        wget -q --user-agent="bpkgs/1.0" "$url" -O "$dest" 2>/dev/null
        [ $? -eq 0 ] && [ -s "$dest" ] && return 0
        rm -f "$dest"; return 1
    }

    for i in "${!REPO_NAMES[@]}"; do
        local base="${REPO_RAW[$i]}"

        if [ "$cat_given" = true ]; then
            # Exact path given
            if [ "$prefer" != "src" ] && _try_url "$base/${pkg}.binbpkg" "$target_bin"; then
                FETCHED_REPO_NAME="${REPO_NAMES[$i]}"
                FETCHED_REPO_INDEX=$i; FETCHED_TYPE="bin"
                echo "$target_bin"; return 0
            fi
            if [ "$prefer" != "bin" ] && _try_url "$base/${pkg}.bpkg" "$target_src"; then
                FETCHED_REPO_NAME="${REPO_NAMES[$i]}"
                FETCHED_REPO_INDEX=$i; FETCHED_TYPE="src"
                echo "$target_src"; return 0
            fi
            if [ "$prefer" = "bin" ]; then
                # Explicitly requested binary only — report not found
                continue
            fi
        else
            # Bare name — probe known category prefixes via API
            local cats
            cats=$(curl -sL -H "User-Agent: bpkgs/1.0" "${REPO_API[$i]}" 2>/dev/null \
                   | grep -oP '"name":\s*"\K[^"]+' | grep -v '\.' || true)
            local cat
            while IFS= read -r cat; do
                [ -z "$cat" ] && continue
                if [ "$prefer" != "src" ] && _try_url "$base/$cat/${pkg}.binbpkg" "$target_bin"; then
                    FETCHED_REPO_NAME="${REPO_NAMES[$i]}"
                    FETCHED_REPO_INDEX=$i; FETCHED_TYPE="bin"
                    echo "$target_bin"; return 0
                fi
                if [ "$prefer" != "bin" ] && _try_url "$base/$cat/${pkg}.bpkg" "$target_src"; then
                    FETCHED_REPO_NAME="${REPO_NAMES[$i]}"
                    FETCHED_REPO_INDEX=$i; FETCHED_TYPE="src"
                    echo "$target_src"; return 0
                fi
            done <<< "$cats"
        fi
    done

    if [ "$prefer" = "bin" ]; then
        echo ""
        return 1
    fi
    echo ""
    return 1
}

# ── Dependency checker ────────────────────────────────────────────────────────
check_dep_installed() {
    local dep="$1"
    # Strip category prefix if present
    local bare="${dep##*/}"
    [ -f "$INSTALLED_DB/$bare.list" ]   && return 0
    [ -f "$INSTALLED_DB/$dep.list" ]    && return 0
    command -v "$bare" >/dev/null 2>&1  && return 0

    local base="${bare%-dev}"; local libname="${base#lib}"

    for d in /usr/include /usr/local/include /usr/include/x86_64-linux-gnu; do
        [ -f "$d/${bare}.h" ]     && return 0
        [ -f "$d/${base}.h" ]     && return 0
        [ -f "$d/${libname}.h" ]  && return 0
    done

    for d in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu /usr/local/lib /lib /lib64; do
        [ -f "$d/lib${libname}.so" ]  && return 0
        [ -f "$d/lib${libname}.a" ]   && return 0
        ls "$d/lib${libname}.so."* >/dev/null 2>&1 && return 0
    done

    if command -v pkg-config >/dev/null 2>&1; then
        pkg-config --exists "$libname" >/dev/null 2>&1 && return 0
        pkg-config --exists "$base"    >/dev/null 2>&1 && return 0
    fi

    return 1
}

resolve_deps() {
    local deps="$1"
    [ -z "$deps" ] && return 0
    IFS=',' read -ra DEPS <<< "$deps"
    local failed=()
    for d in "${DEPS[@]}"; do
        d=$(echo "$d" | xargs)
        [ -z "$d" ] && continue
        if check_dep_installed "$d"; then
            ok "dep $d"
        else
            warn "Missing dep: $d — auto-installing..."
            if ! bash "$SELF" -n "$d"; then
                failed+=("$d")
            fi
        fi
    done
    if [ ${#failed[@]} -gt 0 ]; then
        warn "Could not satisfy: ${failed[*]}"
    fi
}

# ── Version probe (climb) ─────────────────────────────────────────────────────
FINAL_VER="" FINAL_URL=""
climb_logic() {
    local cur_v="$1" cur_u="$2"
    local best_v="$cur_v" best_u="$cur_u"
    local dots; dots=$(echo "$cur_v" | tr -cd '.' | wc -c)
    echo -n "Version probing."
    while true; do
        local found=false
        local major minor patch next_v next_u major_v major_u
        major=$(echo "$cur_v" | cut -d. -f1)
        minor=$(echo "$cur_v" | cut -d. -f2)
        patch=$(echo "$cur_v" | cut -d. -f3)
        if [ "$dots" -ge 2 ]; then
            next_v="${major}.${minor}.$((patch+1))"
            major_v="${major}.$((minor+1)).0"
        else
            next_v="${major}.$((minor+1))"
            major_v="$((major+1)).0"
        fi
        for try_v in "$next_v" "$major_v"; do
            try_u="${cur_u//$cur_v/$try_v}"
            if wget -q --spider -T "$PROBE_TIMEOUT" -t 1 --user-agent="bpkgs/1.0" "$try_u" 2>/dev/null; then
                echo -n "→ $try_v "
                cur_v="$try_v"; cur_u="$try_u"; best_v="$try_v"; best_u="$try_u"
                found=true; break
            fi
        done
        [ "$found" = false ] && { echo "(latest)"; break; }
    done
    FINAL_VER="$best_v"; FINAL_URL="$best_u"
}

# ── Binary install helper ─────────────────────────────────────────────────────
install_binary_bpkg() {
    local file="$1"
    source "$file"
    step "Binary install: $name $version"

    local bin_url="${binary_url:-${download:-}}"
    [ -z "$bin_url" ] && die "No binary_url in $file"

    local tmp_archive="/tmp/bpkgs-bin-${name}.tar"
    info "Downloading binary: $bin_url"
    wget -q --show-progress --user-agent="bpkgs/1.0" "$bin_url" -O "$tmp_archive" \
        || die "Binary download failed"

    export BPKG_DEST="/tmp/bpkgs-dest-${name}"
    rm -rf "$BPKG_DEST"; mkdir -p "$BPKG_DEST"

    # Run instructions() from bpkg if defined, else auto-extract
    if declare -f instructions >/dev/null 2>&1; then
        cd "$(dirname "$tmp_archive")"
        instructions
    else
        tar -xf "$tmp_archive" -C "$BPKG_DEST" 2>/dev/null \
            || unzip -q "$tmp_archive" -d "$BPKG_DEST" 2>/dev/null \
            || { warn "Cannot extract binary archive; trying raw copy"; cp "$tmp_archive" "$BPKG_DEST/"; }
    fi

    _deploy_to_system
}

# ── Source build helper ───────────────────────────────────────────────────────
install_source_bpkg() {
    local file="$1"
    source "$file"
    step "Source build: $name $version"

    # Version climb
    if [[ "${build_type:-tarball}" =~ ^(tarball|cmake|meson)$ ]]; then
        climb_logic "$version" "${download:-}"
        version="$FINAL_VER"; download="$FINAL_URL"
    fi

    local WORK_DIR="/tmp/bpkgs-src-${name}"
    export BPKG_DEST="/tmp/bpkgs-dest-${name}"
    rm -rf "$WORK_DIR" "$BPKG_DEST"; mkdir -p "$WORK_DIR" "$BPKG_DEST"
    cd "$WORK_DIR"

    case "${build_type:-tarball}" in
        git)
            info "Cloning $download..."
            git clone --depth=1 --quiet "$download" . || die "Git clone failed"
            ;;
        tarball|cmake|meson|*)
            info "Downloading $name $version..."
            wget -q --show-progress --user-agent="bpkgs/1.0" "$download" -O src.tar \
                || die "Download failed: $download"
            tar -xf src.tar --strip-components=1 2>/dev/null \
                || tar -xf src.tar 2>/dev/null \
                || die "Extraction failed"
            rm -f src.tar
            ;;
    esac

    # Auto build functions for common types if not in .bpkg
    if ! declare -f build >/dev/null 2>&1; then
        case "${build_type:-tarball}" in
            cmake)
                build() {
                    mkdir -p _build && cd _build
                    cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
                    make -j"$(nproc)"
                }
                instructions() { cd _build && make DESTDIR="$BPKG_DEST" install; }
                ;;
            meson)
                build() { meson setup _build --prefix=/usr && ninja -C _build; }
                instructions() { DESTDIR="$BPKG_DEST" ninja -C _build install; }
                ;;
            go)
                build() { go build -o "$name" .; }
                instructions() { mkdir -p "$BPKG_DEST/usr/bin" && cp "$name" "$BPKG_DEST/usr/bin/"; }
                ;;
            rust)
                build() { cargo build --release; }
                instructions() {
                    mkdir -p "$BPKG_DEST/usr/bin"
                    cp "target/release/$name" "$BPKG_DEST/usr/bin/"
                }
                ;;
            *)
                build() { ./configure --prefix=/usr && make -j"$(nproc)"; }
                instructions() { make DESTDIR="$BPKG_DEST" install; }
                ;;
        esac
    fi

    # Normalise SCRAP_PKG_DEST alias for old-style recipes
    export SCRAP_PKG_DEST="$BPKG_DEST"

    info "Building $name..."
    build || die "Build failed for $name"
    info "Staging $name..."
    instructions || die "Install step failed for $name"
    _deploy_to_system
}

# ── Deploy staged files to / ──────────────────────────────────────────────────
_deploy_to_system() {
    info "Deploying $name to system..."
    cp -a "$BPKG_DEST"/. / 2>/dev/null || true

    # Record file list
    local FILELIST
    FILELIST=$(find "$BPKG_DEST" -type f | sed "s|^$BPKG_DEST||")
    local DB_KEY; DB_KEY=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    echo "$FILELIST" > "$INSTALLED_DB/${DB_KEY}.list"
    # Also record version
    echo "$version" > "$INSTALLED_DB/${DB_KEY}.version"

    ok "$name $version installed."

    [ "${KEEP_BUILD:-false}" = false ] && \
        rm -rf "/tmp/bpkgs-src-${name}" "/tmp/bpkgs-dest-${name}" \
               "/tmp/bpkgs-bin-${name}.tar" "/tmp/bpkgs_"*.bpkg \
               "/tmp/bpkgs_"*.binbpkg 2>/dev/null || true
}

# ── Main install entrypoint ───────────────────────────────────────────────────
do_install() {
    local pkg="$1"
    local force_type="${2:-}"   # src | bin | ""

    # Root check
    [ "$(id -u)" -ne 0 ] && die "Root required for install."

    local file
    file=$(fetch_bpkg "$pkg" "$force_type") || true

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        if [ "$force_type" = "bin" ]; then
            die "Binary package not found for '$pkg'. Try without -bin for source build."
        else
            die "Package '$pkg' not found in any repository."
        fi
    fi

    info "Found in [${FETCHED_REPO_NAME}] (${FETCHED_TYPE})"

    # Source the file to get metadata before confirming
    # shellcheck disable=SC1090
    (
        sed 's/build-type/build_type/g' "$file" > /tmp/bpkgs_norm.bpkg
        source /tmp/bpkgs_norm.bpkg
        echo -e "\n  ${B}Package:${Z} $name"
        echo -e "  ${B}Version:${Z} $version"
        echo -e "  ${B}Desc:${Z}    $desc"
        echo -e "  ${B}Type:${Z}    ${FETCHED_TYPE}"
        echo -e "  ${B}License:${Z} ${license:-unknown}"
        [ -n "${depends:-}" ] && echo -e "  ${B}Deps:${Z}    $depends"
        echo
    )

    if [ "${CONFIRM:-true}" = true ]; then
        read -rp "  Install? [y/N]: " ans
        [[ "$ans" != "y" && "$ans" != "Y" ]] && { info "Aborted."; exit 0; }
    fi

    # Normalise build-type field name
    sed -i 's/build-type/build_type/g' "$file"

    # Resolve deps unless skipped
    if [ "${RESOLVE_DEPS:-true}" = true ]; then
        step "Resolving dependencies..."
        (source "$file"; resolve_deps "${depends:-}")
    fi

    if [ "$FETCHED_TYPE" = "bin" ]; then
        install_binary_bpkg "$file"
    else
        install_source_bpkg "$file"
    fi
}

# ── Remove ────────────────────────────────────────────────────────────────────
do_remove() {
    local pkg="$1" force="${2:-false}"
    local DB_KEY; DB_KEY=$(echo "$pkg" | tr '[:upper:]' '[:lower:]')
    local list_file="$INSTALLED_DB/${DB_KEY}.list"
    [ -f "$list_file" ] || die "Package '$pkg' is not installed."

    if [ "$force" = false ]; then
        read -rp "  Remove $pkg? [y/N]: " ans
        [[ "$ans" != "y" && "$ans" != "Y" ]] && { info "Aborted."; exit 0; }
    fi

    info "Removing $pkg..."
    while IFS= read -r f; do
        [ -f "$f" ] && rm -f "$f" && dirname "$f" | xargs rmdir -p 2>/dev/null || true
    done < "$list_file"
    rm -f "$list_file" "$INSTALLED_DB/${DB_KEY}.version"
    ok "Removed $pkg."
}

# ── List installed ────────────────────────────────────────────────────────────
list_installed() {
    echo -e "${B}Installed packages:${Z}"
    echo "───────────────────────────────────────────"
    local pkgs; pkgs=$(ls "$INSTALLED_DB" 2>/dev/null | grep '\.list$' | sed 's/\.list$//' | sort)
    if [ -z "$pkgs" ]; then
        echo "  (none)"
    else
        while IFS= read -r p; do
            local ver=""
            [ -f "$INSTALLED_DB/${p}.version" ] && ver="  $(cat "$INSTALLED_DB/${p}.version")"
            echo -e "  ${C}$p${Z}${DIM}${ver}${Z}"
        done <<< "$pkgs"
        echo "───────────────────────────────────────────"
        echo "  Total: $(echo "$pkgs" | wc -l) package(s)"
    fi
}

# ── List available ────────────────────────────────────────────────────────────
list_available() {
    local filter_repo="${1:-}"
    echo -e "${B}Available packages:${Z}"
    echo "───────────────────────────────────────────"
    for i in "${!REPO_NAMES[@]}"; do
        [ -n "$filter_repo" ] && [ "${REPO_NAMES[$i]}" != "$filter_repo" ] && continue
        echo -e "  ${B}[${REPO_NAMES[$i]}]${Z}"
        # List top-level dirs (categories)
        local cats
        cats=$(curl -sL -H "User-Agent: bpkgs/1.0" "${REPO_API[$i]}" 2>/dev/null \
               | grep -oP '"name":\s*"\K[^"]+' | grep -v '\.' | sort || true)
        while IFS= read -r cat; do
            [ -z "$cat" ] && continue
            echo -e "    ${DIM}[${cat}]${Z}"
            curl -sL -H "User-Agent: bpkgs/1.0" "${REPO_API[$i]}/$cat" 2>/dev/null \
               | grep -oP '"name":\s*"\K[^"]+' \
               | grep -E '\.(bpkg|binbpkg)$' \
               | sed -E 's/\.(bpkg|binbpkg)//' \
               | sort -u \
               | while IFS= read -r pkg; do
                    local installed=""
                    [ -f "$INSTALLED_DB/${pkg}.list" ] && installed="${G} [installed]${Z}"
                    echo -e "      ${C}${cat}/${pkg}${Z}${installed}"
               done
        done <<< "$cats"
    done
    echo "───────────────────────────────────────────"
}

# ── Search ────────────────────────────────────────────────────────────────────
do_search() {
    local term="$1"
    echo -e "${B}Search results for '${term}':${Z}"
    echo "───────────────────────────────────────────"
    for i in "${!REPO_NAMES[@]}"; do
        echo -e "  ${B}[${REPO_NAMES[$i]}]${Z}"
        # Get all categories then search within each
        local cats
        cats=$(curl -sL -H "User-Agent: bpkgs/1.0" "${REPO_API[$i]}" 2>/dev/null \
               | grep -oP '"name":\s*"\K[^"]+' | grep -v '\.' || true)
        while IFS= read -r cat; do
            [ -z "$cat" ] && continue
            curl -sL -H "User-Agent: bpkgs/1.0" "${REPO_API[$i]}/$cat" 2>/dev/null \
               | grep -oP '"name":\s*"\K[^"]+' \
               | grep -E '\.(bpkg|binbpkg)$' \
               | grep -i "$term" \
               | sed -E "s/\.(bpkg|binbpkg)//" \
               | sort -u \
               | while IFS= read -r p; do echo -e "    ${C}${cat}/${p}${Z}"; done
        done <<< "$cats"
    done
    echo "───────────────────────────────────────────"
}

# ── Package info ──────────────────────────────────────────────────────────────
do_info() {
    local pkg="$1"
    local found=false
    for i in "${!REPO_NAMES[@]}"; do
        local target="/tmp/bpkgs_info_$(echo "$pkg" | tr '/' '_').bpkg"
        wget -q --user-agent="bpkgs/1.0" "${REPO_RAW[$i]}/${pkg}.bpkg" -O "$target" 2>/dev/null
        if [ $? -eq 0 ] && [ -s "$target" ]; then
            echo -e "${B}─── [${REPO_NAMES[$i]}] ${pkg} (source) ───${Z}"
            grep -E '^(name|version|desc|info|maintainer|depends|license|arch|priority|build-type)=' \
                "$target" | sed 's/"//g' | sed 's/^/  /'
            rm -f "$target"; found=true
        fi
        wget -q --user-agent="bpkgs/1.0" "${REPO_RAW[$i]}/${pkg}.binbpkg" -O "$target" 2>/dev/null
        if [ $? -eq 0 ] && [ -s "$target" ]; then
            echo -e "${B}─── [${REPO_NAMES[$i]}] ${pkg} (binary) ───${Z}"
            grep -E '^(name|version|desc|info|maintainer|depends|license|arch|priority|binary_url)=' \
                "$target" | sed 's/"//g' | sed 's/^/  /'
            rm -f "$target"; found=true
        fi
    done
    [ "$found" = false ] && die "Package '$pkg' not found in any repository."
}

# ── Upgrade all ───────────────────────────────────────────────────────────────
do_upgrade() {
    info "Upgrading all installed packages..."
    local pkgs; pkgs=$(ls "$INSTALLED_DB" 2>/dev/null | grep '\.list$' | sed 's/\.list$//' | sort)
    [ -z "$pkgs" ] && { info "Nothing installed."; return; }
    while IFS= read -r p; do
        info "Upgrading $p..."
        CONFIRM=false bash "$SELF" -n "$p" 2>/dev/null || warn "Could not upgrade $p"
    done <<< "$pkgs"
    ok "Upgrade complete."
}

# ── Update bpkgs itself ───────────────────────────────────────────────────────
do_self_update() {
    local tmp="/tmp/bpkgs_update.sh"
    info "Checking for bpkgs update..."
    wget -q --user-agent="bpkgs/1.0" "${REPO_RAW[0]}/update.sh" -O "$tmp" 2>/dev/null \
        || wget -q --user-agent="bpkgs/1.0" "${REPO_RAW[0]}/update.txt" -O "$tmp" 2>/dev/null
    if [ -s "$tmp" ]; then
        ok "Running update script..."
        bash "$tmp"; rm -f "$tmp"
    else
        warn "No update script found at ${REPO_RAW[0]}/update.sh"
        rm -f "$tmp"
    fi
}

# ── Declarative system config support ────────────────────────────────────────
# /etc/based.conf  lists packages one per line or comma-separated
# Run: bpkgs -apply   to install/reconcile declared packages
do_apply() {
    local conf="${1:-/etc/based.conf}"
    [ -f "$conf" ] || die "No config file: $conf  (create /etc/based.conf)"
    info "Applying declarative config: $conf"
    local declared=()
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "${line// }" ]] && continue
        IFS=',' read -ra pkgs <<< "$line"
        for p in "${pkgs[@]}"; do
            p=$(echo "$p" | xargs)
            [ -n "$p" ] && declared+=("$p")
        done
    done < "$conf"
    for pkg in "${declared[@]}"; do
        local bare="${pkg##*/}"
        local DB_KEY; DB_KEY=$(echo "$bare" | tr '[:upper:]' '[:lower:]')
        if [ -f "$INSTALLED_DB/${DB_KEY}.list" ]; then
            ok "$pkg (already installed)"
        else
            CONFIRM=false do_install "$pkg"
        fi
    done
    ok "Declarative apply complete."
}

# =============================================================================
#  ARGUMENT PARSING
# =============================================================================
CONFIRM=true
RESOLVE_DEPS=true
KEEP_BUILD=false
FORCE_TYPE=""
PKG=""

[ $# -eq 0 ] && { show_help; exit 0; }

case "$1" in
    -h|--help)   show_help; exit 0 ;;
    makebpkg)    makebpkg_cmd ;;
    -l)          list_installed; exit 0 ;;
    -repos)
        echo -e "${B}Configured repositories:${Z}"
        for i in "${!REPO_NAMES[@]}"; do
            local lbl=""; [ $i -eq 0 ] && lbl=" (default)"
            echo -e "  ${C}[${REPO_NAMES[$i]}]${Z}${lbl}"
            echo "    raw: ${REPO_RAW[$i]}"
            echo "    api: ${REPO_API[$i]}"
        done
        echo "  Config: $REPOS_CONF"
        exit 0 ;;
    -s)
        [ -z "${2:-}" ] && die "Usage: bpkgs -s <term>"
        do_search "$2"; exit 0 ;;
    -info)
        [ -z "${2:-}" ] && die "Usage: bpkgs -info <category/name>"
        do_info "$2"; exit 0 ;;
    -u)
        list_available "${2:-}"; exit 0 ;;
    -update)   do_self_update; exit 0 ;;
    -upgrade)  do_upgrade; exit 0 ;;
    -apply)    do_apply "${2:-/etc/based.conf}"; exit 0 ;;
    -r)
        [ -z "${2:-}" ] && die "Usage: bpkgs -r <name>"
        [ "$(id -u)" -ne 0 ] && die "Root required."
        do_remove "$2" false; exit 0 ;;
    -rr)
        [ -z "${2:-}" ] && die "Usage: bpkgs -rr <name>"
        [ "$(id -u)" -ne 0 ] && die "Root required."
        do_remove "$2" true; exit 0 ;;
    -n)
        CONFIRM=false
        shift; PKG="${1:-}"
        [ -z "$PKG" ] && die "Usage: bpkgs -n <category/name>"
        ;;
    -nodeps)
        RESOLVE_DEPS=false
        shift; PKG="${1:-}"
        [ -z "$PKG" ] && die "Usage: bpkgs -nodeps <category/name>"
        ;;
    -k)
        KEEP_BUILD=true
        shift; PKG="${1:-}"
        [ -z "$PKG" ] && die "Usage: bpkgs -k <category/name>"
        ;;
    -i)
        shift
        [ -z "${1:-}" ] && die "Usage: bpkgs -i <category/name> [-src|-bin]"
        PKG="$1"
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                -src) FORCE_TYPE="src" ;;
                -bin) FORCE_TYPE="bin" ;;
                -n)   CONFIRM=false ;;
                -k)   KEEP_BUILD=true ;;
            esac
            shift
        done
        ;;
    *)
        # Bare pkg name without -i flag is also valid
        PKG="$1"
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
                -src) FORCE_TYPE="src" ;;
                -bin) FORCE_TYPE="bin" ;;
                -n)   CONFIRM=false ;;
                -k)   KEEP_BUILD=true ;;
                -nodeps) RESOLVE_DEPS=false ;;
            esac
            shift
        done
        ;;
esac

export CONFIRM RESOLVE_DEPS KEEP_BUILD
[ -n "$PKG" ] && do_install "$PKG" "$FORCE_TYPE"

BPKGS_EOF

chmod +x /usr/local/bin/bpkgs
echo "$MSG"
echo "Run: bpkgs --help"
