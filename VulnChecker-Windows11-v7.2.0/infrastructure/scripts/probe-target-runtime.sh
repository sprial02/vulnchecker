#!/bin/sh
# Read-only probe; works before remote Python modules and file transfer are usable.
printf '\n__TRIGUARD_RUNTIME_V1_BEGIN__\n'
for triguard_python in __TRIGUARD_CONFIGURED_PYTHON__ /usr/bin/python3.13 /usr/bin/python3.12 /usr/bin/python3.11 /usr/bin/python3.10 /usr/bin/python3.9 /usr/bin/python3.8 /usr/local/bin/python3 /usr/bin/python3 /usr/libexec/platform-python; do
    if test -x "$triguard_python"; then
        triguard_version=$("$triguard_python" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)
        printf 'PYTHON|%s|%s\n' "$triguard_python" "$triguard_version"
    fi
done
printf '__TRIGUARD_RUNTIME_V1_END__\n'
