#!/bin/bash

# Run this script from the root of the systemd's git repository
# or set REPO_ROOT to a correct path.
#
# Example execution on Fedora:
# dnf install docker
# systemctl start docker
# export CONT_NAME="my-fancy-container"
# ci/travis-centos.sh SETUP RUN CLEANUP

PHASES=(${@:-SETUP RUN CLEANUP})
CENTOS_RELEASE="${CENTOS_RELEASE:-latest}"
CONT_NAME="${CONT_NAME:-centos-$CENTOS_RELEASE-$RANDOM}"
DOCKER_EXEC="${DOCKER_EXEC:-docker exec -it $CONT_NAME}"
DOCKER_RUN="${DOCKER_RUN:-docker run}"
REPO_ROOT="${REPO_ROOT:-$PWD}"
ADDITIONAL_DEPS=(yum-utils iputils hostname libasan libubsan clang llvm)
CONFIGURE_OPTS=(
    --disable-timesyncd
    --disable-kdbus
    --disable-terminal
    --enable-gtk-doc
    --enable-compat-libs
    --disable-sysusers
    --disable-ldconfig
    --enable-lz4
    --with-sysvinit-path=/etc/rc.d/init.d
)

function info() {
    echo -e "\033[33;1m$1\033[0m"
}

function travis_ping() {
    while :; do
        echo "[TRAVIS_PING]"
        sleep 60
    done
}

set -e

source "$(dirname $0)/travis_wait.bash"

for phase in "${PHASES[@]}"; do
    case $phase in
        SETUP)
            info "Setup phase"
            info "Using Travis $CENTOS_RELEASE"
            # Pull a Docker image and start a new container
            docker pull centos:$CENTOS_RELEASE
            info "Starting container $CONT_NAME"
            $DOCKER_RUN -v $REPO_ROOT:/build:rw \
                        -w /build --privileged=true --name $CONT_NAME \
                        -dit --net=host centos:$CENTOS_RELEASE /sbin/init
            # Beautiful workaround for Fedora's version of Docker
            sleep 1
            $DOCKER_EXEC yum makecache
            # Install necessary build/test requirements
            $DOCKER_EXEC yum -y upgrade
            $DOCKER_EXEC yum -y install "${ADDITIONAL_DEPS[@]}"
            $DOCKER_EXEC yum-builddep -y systemd
            ;;
        RUN)
            info "Run phase"
            # Build systemd
            $DOCKER_EXEC ./autogen.sh
            $DOCKER_EXEC ./configure "${CONFIGURE_OPTS[@]}"
            $DOCKER_EXEC make
            # Run the internal testsuite
            # Let's install the new systemd and "reboot" the container to avoid
            # unexpected fails due to incompatibilities with older systemd
            $DOCKER_EXEC make install
            docker restart $CONT_NAME
            if ! $DOCKER_EXEC make check; then
                $DOCKER_EXEC cat test-suite.log
                exit 1
            fi
            ;;
        RUN_ASAN)
            # We need newer gcc due to a bug with gcc4 and libasan
            $DOCKER_EXEC yum -y install centos-release-scl
            $DOCKER_EXEC yum -y install devtoolset-8 devtoolset-8-libasan-devel libasan5 devtoolset-8-libubsan-devel libubsan1
            $DOCKER_EXEC bash -c "echo -e 'source scl_source enable devtoolset-8' > ~/.bashrc"
            # Build systemd with Address Sanitizer
            # Wrap following commands in bash -i to allow loading of .bashrc
            $DOCKER_EXEC /bin/bash -ic "gcc --version"
            $DOCKER_EXEC /bin/bash -ic './autogen.sh'
            # Turn off some newer gcc warnings as RHEL7 systemd is not ready to
            # comply with them
            docker exec -it \
                -e CFLAGS="-O0 -g -ftrapv -Wimplicit-fallthrough=0 -Wformat-truncation=0 -Wno-cast-function-type -Wno-logical-op" \
                $CONT_NAME \
                /bin/bash -ic "./configure --enable-address-sanitizer --enable-undefined-sanitizer ${CONFIGURE_OPTS[@]}"

            # A disgusting workaround for old gudev introspection, which goes haywire with ASan
            ASAN_INTERCEPT="intercept_strstr=false:intercept_strspn=false:intercept_strpbrk=false:intercept_memcmp=false:strict_memcmp=false:intercept_strndup=0:intercept_strlen=0:intercept_strchr=0"
            docker exec -it \
                -e LD_PRELOAD=/lib64/libasan.so.5 \
                -e ASAN_OPTIONS="detect_leaks=false:check_printf=false:symbolize=false:detect_deadlocks=false:replace_str=false:replace_intrin=false:$ASAN_INTERCEPT" \
                $CONT_NAME /bin/bash -ic 'make -j4 '

            # Run the internal testsuite
            # Never remove halt_on_error from UBSAN_OPTIONS. See https://github.com/systemd/systemd/commit/2614d83aa06592aedb.
            travis_wait docker exec --interactive=false \
                -e UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1 \
                -e ASAN_OPTIONS=strict_string_checks=1:detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1 \
                $CONT_NAME \
                /bin/bash -ic "make check || (cat test-suite.log; exit 1)"
            ;;
        CLEANUP)
            info "Cleanup phase"
            docker stop $CONT_NAME
            docker rm -f $CONT_NAME
            ;;
        *)
            echo >&2 "Unknown phase '$phase'"
            exit 1
    esac
done
