#!/bin/bash
#
# Copyright 2023 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# An end-to-end test for Skyfocus & working sets.

# --- begin runfiles.bash initialization ---
set -euo pipefail
if [[ ! -d "${RUNFILES_DIR:-/dev/null}" && ! -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]]; then
  if [[ -f "$0.runfiles_manifest" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles_manifest"
  elif [[ -f "$0.runfiles/MANIFEST" ]]; then
    export RUNFILES_MANIFEST_FILE="$0.runfiles/MANIFEST"
  elif [[ -f "$0.runfiles/bazel_tools/tools/bash/runfiles/runfiles.bash" ]]; then
    export RUNFILES_DIR="$0.runfiles"
  fi
fi
if [[ -f "${RUNFILES_DIR:-/dev/null}/bazel_tools/tools/bash/runfiles/runfiles.bash" ]]; then
  source "${RUNFILES_DIR}/bazel_tools/tools/bash/runfiles/runfiles.bash"
elif [[ -f "${RUNFILES_MANIFEST_FILE:-/dev/null}" ]]; then
  source "$(grep -m1 "^bazel_tools/tools/bash/runfiles/runfiles.bash " \
            "$RUNFILES_MANIFEST_FILE" | cut -d ' ' -f 2-)"
else
  echo >&2 "ERROR: cannot find @bazel_tools//tools/bash/runfiles:runfiles.bash"
  exit 1
fi
# --- end runfiles.bash initialization ---

source "$(rlocation "io_bazel/src/test/shell/integration_test_setup.sh")" \
  || { echo "integration_test_setup.sh not found!" >&2; exit 1; }

case "$(uname -s | tr [:upper:] [:lower:])" in
msys*|mingw*|cygwin*)
  declare -r is_windows=true
  ;;
*)
  declare -r is_windows=false
  ;;
esac

if "$is_windows"; then
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL="*"
fi

add_to_bazelrc "build --experimental_enable_skyfocus"

function set_up() {
  # Ensure we always start with a fresh server so that the following
  # env vars are picked up on startup. This could also be `bazel shutdown`,
  # but clean is useful for stateless tests.
  bazel clean --expunge

  # The focus command is currently implemented for InMemoryGraphImpl,
  # not SerializationCheckingGraph. This env var disables
  # SerializationCheckingGraph from being used as the evaluator.
  export DONT_SANITY_CHECK_SERIALIZATION=1
}

function test_working_set_can_be_used_with_build_command() {
  local -r pkg=${FUNCNAME[0]}
  mkdir ${pkg}|| fail "cannot mkdir ${pkg}"
  mkdir -p ${pkg}
  echo "input" > ${pkg}/in.txt
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g",
  srcs = ["in.txt"],
  outs = ["out.txt"],
  cmd = "cp \$< \$@",
)
EOF

  bazel build //${pkg}:g \
    --experimental_working_set=${pkg}/in.txt >$TEST_log 2>&1 \
    || "unexpected failure"
  expect_log "Focusing on"
}

function test_correctly_rebuilds_with_working_set_containing_files() {
  local -r pkg=${FUNCNAME[0]}
  mkdir ${pkg}|| fail "cannot mkdir ${pkg}"
  mkdir -p ${pkg}
  echo "input" > ${pkg}/in.txt
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g",
  srcs = ["in.txt"],
  outs = ["out.txt"],
  cmd = "cp \$< \$@",
)
EOF

  out=$(bazel info "${PRODUCT_NAME}-genfiles")/${pkg}/out.txt

  bazel build //${pkg}:g --experimental_working_set=${pkg}/in.txt
  assert_contains "input" $out

  echo "first change" >> ${pkg}/in.txt
  bazel build //${pkg}:g --experimental_working_set=${pkg}/in.txt
  assert_contains "first change" $out

  echo "second change" >> ${pkg}/in.txt
  bazel build //${pkg}:g
  assert_contains "second change" $out
}

function test_correctly_rebuilds_with_working_set_containing_directories() {
  # Setting directories in the working set works, because the rdep edges look like:
  #
  # FILE_STATE:[dir] -> FILE:[dir] -> FILE:[dir/BUILD], FILE:[dir/file.txt]
  #
  # ...and the FILE SkyKeys directly depend on their respective FILE_STATE SkyKeys,
  # which are the nodes that are invalidated by SkyframeExecutor#handleDiffs
  # at the start of every build, and are also kept by Skyfocus.
  #
  # In other words, defining a working set of directories will automatically
  # include all the files under those directories for focusing.

  local -r pkg=${FUNCNAME[0]}
  mkdir -p ${pkg}
  echo "input" > ${pkg}/in.txt
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g",
  srcs = ["in.txt"],
  outs = ["out.txt"],
  cmd = "cp \$< \$@",
)
EOF

  out=$(bazel info "${PRODUCT_NAME}-genfiles")/${pkg}/out.txt

  # Define working set to be a directory, not file
  bazel build //${pkg}:g --experimental_working_set=${pkg}
  assert_contains "input" $out

  # Incrementally builds ${pkg}/in.txt file
  echo "first change" >> ${pkg}/in.txt
  bazel build //${pkg}:g
  assert_contains "first change" $out

  echo "second change" >> ${pkg}/in.txt
  bazel build //${pkg}:g
  assert_contains "second change" $out

  # Incrementally builds new target in ${pkg}/BUILD file
  cat >> ${pkg}/BUILD <<EOF
genrule(
  name = "another_genrule",
  srcs = ["in.txt"],
  outs = ["out2.txt"],
  cmd = "cp \$< \$@",
)
EOF
  bazel build //${pkg}:another_genrule || fail "expected build success"
}

function test_correctly_rebuilds_with_working_set_containing_directories_recursively() {
  local -r pkg=${FUNCNAME[0]}
  mkdir -p ${pkg}/a/b
  echo "content_a" > ${pkg}/a/in.txt
  echo "content_b" > ${pkg}/a/b/in.txt
  cat > ${pkg}/a/BUILD <<EOF
genrule(
  name = "a",
  srcs = ["in.txt", "//${pkg}/a/b"],
  outs = ["out.txt"],
  cmd = "cat \$(location in.txt) \$(location //${pkg}/a/b) > \$@",
)
EOF
  cat > ${pkg}/a/b/BUILD <<EOF
genrule(
  name = "b",
  srcs = ["in.txt"],
  outs = ["out.txt"],
  cmd = "cat \$(location in.txt) > \$@",
  visibility = ["//visibility:public"],
)
EOF

  out=$(bazel info "${PRODUCT_NAME}-genfiles")/${pkg}/a/out.txt

  # Set only //a as the working set
  bazel build //${pkg}/a --experimental_working_set=${pkg}/a
  assert_contains "content_a" $out
  assert_contains "content_b" $out

  # File in //a/b edited, build succeeds.
  echo "a change" >> ${pkg}/a/b/in.txt
  bazel build //${pkg}/a &> "$TEST_log" || fail "expected build succeed"
  assert_contains "a change" $out
}



function test_focus_command_prints_info_about_graph() {
  local -r pkg=${FUNCNAME[0]}
  mkdir ${pkg}|| fail "cannot mkdir ${pkg}"
  mkdir -p ${pkg}
  echo "input" > ${pkg}/in.txt
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g",
  srcs = ["in.txt"],
  outs = ["out.txt"],
  cmd = "cp \$< \$@",
)
EOF

  out=$(bazel info "${PRODUCT_NAME}-genfiles")/${pkg}/out.txt
  bazel build //${pkg}:g\
    --experimental_skyfocus_dump_post_gc_stats \
    --experimental_working_set=${pkg}/in.txt >$TEST_log 2>&1

  expect_log "Focusing on .\+ roots, .\+ leafs"
  expect_log "Nodes in reverse transitive closure from leafs: .\+"
  expect_log "Nodes in direct deps of reverse transitive closure: .\+"
  expect_log "Rdep edges: .\+ -> .\+"
  expect_log "Heap: .\+MB -> .\+MB (.\+% reduction)"
  expect_log "Node count: .\+ -> .\+ (.\+% reduction)"
}

function test_focus_command_dump_keys_prints_more_info_about_graph() {
  local -r pkg=${FUNCNAME[0]}
  mkdir ${pkg}|| fail "cannot mkdir ${pkg}"
  mkdir -p ${pkg}
  echo "input" > ${pkg}/in.txt
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g",
  srcs = ["in.txt"],
  outs = ["out.txt"],
  cmd = "cp \$< \$@",
)
EOF

  out=$(bazel info "${PRODUCT_NAME}-genfiles")/${pkg}/out.txt
  bazel build //${pkg}:g \
    --experimental_skyfocus_dump_keys \
    --experimental_working_set=${pkg}/in.txt >$TEST_log 2>&1

  expect_log "Focusing on .\+ roots, .\+ leafs"

  # additional info
  expect_log "Rdeps kept:"
  expect_log "BUILD_DRIVER:"

  expect_log "Deps kept:"
  expect_log "BUILD_CONFIGURATION:"

  expect_log "Summary of kept keys:"
  expect_log "BUILD_DRIVER"
}

function test_builds_new_target_after_using_focus() {
  local -r pkg=${FUNCNAME[0]}
  mkdir ${pkg}|| fail "cannot mkdir ${pkg}"
  mkdir -p ${pkg}
  echo "input" > ${pkg}/in.txt
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g",
  srcs = ["in.txt"],
  outs = ["g.txt"],
  cmd = "cp \$< \$@",
)
genrule(
  name = "g2",
  srcs = ["in.txt"],
  outs = ["g2.txt"],
  cmd = "cp \$< \$@",
)
genrule(
  name = "g3",
  outs = ["g3.txt"],
  cmd = "touch \$@",
)
EOF

  bazel build //${pkg}:g
  echo "a change" >> ${pkg}/in.txt

  bazel build //${pkg}:g \
    --experimental_working_set=${pkg}/in.txt
  bazel build //${pkg}:g
  bazel build //${pkg}:g2 || fail "cannot build //${pkg}:g2"
  bazel build //${pkg}:g3 || fail "cannot build //${pkg}:g3"
}

function test_working_set_can_be_reduced_without_reanalysis() {
  local -r pkg=${FUNCNAME[0]}
  mkdir ${pkg}|| fail "cannot mkdir ${pkg}"
  mkdir -p ${pkg}
  echo "input1" > ${pkg}/in.txt
  echo "input2" > ${pkg}/in2.txt
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g",
  srcs = ["in.txt", "in2.txt"],
  outs = ["g.txt"],
  cmd = "cat \$(location in.txt) \$(location in2.txt) > \$@",
)
EOF

  out=$(bazel info "${PRODUCT_NAME}-genfiles")/${pkg}/g.txt

  bazel build //${pkg}:g --experimental_working_set=${pkg}/in.txt,${pkg}/in2.txt
  assert_contains "input1" $out
  assert_contains "input2" $out
  echo "a change" >> ${pkg}/in.txt
  bazel build //${pkg}:g --experimental_working_set=${pkg}/in.txt &> "$TEST_log"
  assert_contains "a change" $out
  expect_not_log "discarding analysis cache"
}

function test_working_set_expansion_causes_reanalysis() {
  local -r pkg=${FUNCNAME[0]}
  mkdir ${pkg}|| fail "cannot mkdir ${pkg}"
  mkdir -p ${pkg}
  echo "input1" > ${pkg}/in.txt
  echo "input2" > ${pkg}/in2.txt
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g",
  srcs = ["in.txt", "in2.txt"],
  outs = ["g.txt"],
  cmd = "cat \$(location in.txt) \$(location in2.txt) > \$@",
)
EOF

  out=$(bazel info "${PRODUCT_NAME}-genfiles")/${pkg}/g.txt

  bazel build //${pkg}:g --experimental_working_set=${pkg}/in.txt
  assert_contains "input1" $out
  assert_contains "input2" $out
  echo "a change" >> ${pkg}/in2.txt
  bazel build //${pkg}:g --experimental_working_set=${pkg}/in.txt,${pkg}/in2.txt &> "$TEST_log"
  assert_contains "a change" $out
  expect_log "discarding analysis cache"
}

function test_focus_emits_profile_data() {
  local -r pkg=${FUNCNAME[0]}
  mkdir ${pkg}|| fail "cannot mkdir ${pkg}"
  mkdir -p ${pkg}
  echo "input" > ${pkg}/in.txt
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g",
  srcs = ["in.txt"],
  outs = ["out.txt"],
  cmd = "cp \$< \$@",
)
EOF

  bazel build //${pkg}:g \
    --experimental_working_set=${pkg}/in.txt \
    --profile=/tmp/profile.log &> "$TEST_log" || fail "expected success"
  grep '"ph":"X"' /tmp/profile.log > "$TEST_log" \
    || fail "Missing profile file."

  expect_log '"SkyframeFocuser"'
  expect_log '"focus.mark"'
  expect_log '"focus.sweep_nodes"'
  expect_log '"focus.sweep_edges"'
}

function test_info_supports_printing_working_set() {
  local -r pkg=${FUNCNAME[0]}
  mkdir ${pkg}|| fail "cannot mkdir ${pkg}"
  mkdir -p ${pkg}
  touch ${pkg}/in.txt
  touch ${pkg}/in2.txt
  touch ${pkg}/not.used
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g",
  srcs = ["in.txt", "in2.txt"],
  outs = ["out.txt"],
  cmd = "cat \$(location in.txt) \$(location in2.txt) > \$@",
)
EOF

  # Fresh build, so there is no working set.
  bazel info working_set &> "$TEST_log" \
    || fail "expected working_set to be a valid key"
  expect_log "No working set found."
  expect_not_log "${pkg}/in.txt"

  # Initial build with working set.
  bazel build //${pkg}:g --experimental_working_set=${pkg}/in.txt
  bazel info working_set &> "$TEST_log"
  expect_log "${pkg}/in.txt"

  # Working set is expanded.
  bazel build //${pkg}:g --experimental_working_set=${pkg}/in.txt,${pkg}/in2.txt
  bazel info working_set &> "$TEST_log"
  expect_log "${pkg}/in.txt"
  expect_log "${pkg}/in2.txt"

  # Working set can be expanded to include files not in the downward transitive closure.
  bazel build //${pkg}:g --experimental_working_set=${pkg}/in.txt,${pkg}/in2.txt,${pkg}/not.used
  bazel info working_set &> "$TEST_log"
  expect_log "${pkg}/in.txt"
  expect_log "${pkg}/in2.txt"
  expect_log "${pkg}/not.used"

  # The active set is retained for subsequent builds that don't pass the flag.
  bazel build //${pkg}:g
  bazel info working_set &> "$TEST_log"
  expect_log "${pkg}/in.txt"
  expect_log "${pkg}/in2.txt"
  expect_log "${pkg}/not.used"
}

function test_errors_after_editing_non_working_set_file_in_same_dir() {
  local -r pkg=${FUNCNAME[0]}
  mkdir -p ${pkg}
  echo "input" > ${pkg}/in.txt
  echo "input2" > ${pkg}/in2.txt
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g",
  srcs = ["in.txt", "in2.txt"],
  outs = ["out.txt"],
  cmd = "cat \$(location in.txt) \$(location in2.txt) > \$@",
)
EOF

  out=$(bazel info "${PRODUCT_NAME}-genfiles")/${pkg}/out.txt

  # Define the working set as in.txt only.
  bazel build //${pkg}:g --experimental_working_set=${pkg}/in.txt
  assert_contains "input" $out
  assert_contains "input2" $out

  # Edit in2.txt, which is outside of the working set. Build fails.
  echo "a change" >> ${pkg}/in2.txt
  bazel build //${pkg}:g &> "$TEST_log" && fail "expected build to fail"
  expect_log "detected changes outside of the working set"
  expect_log "${pkg}/in2.txt"

  # Fix the working set to include in2.txt, build succeeds.
  bazel build //${pkg}:g --experimental_working_set=${pkg}/in.txt,${pkg}/in2.txt \
    || fail "expected build to succeed"
  assert_contains "a change" $out
}

function test_errors_after_editing_non_working_set_through_dep() {
  local -r pkg=${FUNCNAME[0]}
  mkdir -p ${pkg}
  echo "input" > ${pkg}/in.txt
  echo "input2" > ${pkg}/in2.txt
  cat > ${pkg}/BUILD <<EOF
genrule(
  name = "g1",
  srcs = ["in.txt"],
  outs = ["intermediate.txt"],
  cmd = "cat \$(location in.txt) > \$@",
)

genrule(
  name = "g2",
  srcs = ["intermediate.txt", "in2.txt"],
  outs = ["out.txt"],
  cmd = "cat \$(location intermediate.txt) \$(location in2.txt) > \$@",
)
EOF

  out=$(bazel info "${PRODUCT_NAME}-genfiles")/${pkg}/out.txt

  # Define the working set as in2.txt only.
  bazel build //${pkg}:g2 --experimental_working_set=${pkg}/in2.txt
  assert_contains "input" $out
  assert_contains "input2" $out

  # File outside of working set edited (in.txt), build fails.
  echo "a change" >> ${pkg}/in.txt
  bazel build //${pkg}:g2 &> "$TEST_log" && fail "expected build to fail"
  expect_log "detected changes outside of the working set"
  expect_log "${pkg}/in.txt"

  # Fix the working set to include in2.txt, build succeeds.
  bazel build //${pkg}:g2 --experimental_working_set=${pkg}/in.txt,${pkg}/in2.txt \
    || fail "expected build to succeed"
  assert_contains "a change" $out
}

function test_errors_after_editing_non_working_set_in_sibling_dir() {
  local -r pkg=${FUNCNAME[0]}
  mkdir -p ${pkg}/a ${pkg}/b
  echo "content_a" > ${pkg}/a/in.txt
  echo "content_b" > ${pkg}/b/in.txt
  cat > ${pkg}/a/BUILD <<EOF
genrule(
  name = "a",
  srcs = ["in.txt", "//${pkg}/b"],
  outs = ["out.txt"],
  cmd = "cat \$(location in.txt) \$(location //${pkg}/b) > \$@",
)
EOF
  cat > ${pkg}/b/BUILD <<EOF
genrule(
  name = "b",
  srcs = ["in.txt"],
  outs = ["out.txt"],
  cmd = "cat \$(location in.txt) > \$@",
  visibility = ["//visibility:public"],
)
EOF

  out=$(bazel info "${PRODUCT_NAME}-genfiles")/${pkg}/a/out.txt

  # Set only //a as the working set
  bazel build //${pkg}/a --experimental_working_set=${pkg}/a
  assert_contains "content_a" $out
  assert_contains "content_b" $out

  # File in //b edited, build fails.
  echo "a change" >> ${pkg}/b/in.txt
  bazel build //${pkg}/a &> "$TEST_log" && fail "expected build to fail"
  expect_log "detected changes outside of the working set"
  expect_log "${pkg}/b/in.txt"

  # Fix the working set to include //b, build succeeds.
  bazel build //${pkg}/a --experimental_working_set=${pkg}/a,${pkg}/b \
    || fail "expected build to succeed"
  assert_contains "a change" $out
}

function test_errors_after_editing_non_working_set_in_parent_dir() {
  local -r pkg=${FUNCNAME[0]}
  mkdir -p ${pkg}/a/b
  echo "content_a" > ${pkg}/a/in.txt
  echo "content_b" > ${pkg}/a/b/in.txt
  cat > ${pkg}/a/BUILD <<EOF
genrule(
  name = "a",
  srcs = ["in.txt"],
  outs = ["out.txt"],
  cmd = "cat \$(location in.txt) > \$@",
  visibility = ["//visibility:public"],
)
EOF
  cat > ${pkg}/a/b/BUILD <<EOF
genrule(
  name = "b",
  srcs = ["in.txt", "//${pkg}/a"],
  outs = ["out.txt"],
  cmd = "cat \$(location in.txt) \$(location //${pkg}/a) > \$@",
)
EOF

  out=$(bazel info "${PRODUCT_NAME}-genfiles")/${pkg}/a/b/out.txt

  # Set only //a/b as the working set
  bazel build //${pkg}/a/b --experimental_working_set=${pkg}/a/b
  assert_contains "content_a" $out
  assert_contains "content_b" $out

  # File in //a edited, build fails.
  echo "a change" >> ${pkg}/a/in.txt
  bazel build //${pkg}/a/b &> "$TEST_log" && fail "expected build to fail"
  expect_log "detected changes outside of the working set"
  expect_log "${pkg}/a/in.txt"

  # Fix the working set to include //a, build succeeds.
  bazel build //${pkg}/a/b --experimental_working_set=${pkg}/a,${pkg}/a/b \
    || fail "expected build to succeed"
  assert_contains "a change" $out
}

run_suite "Tests for Skyfocus"
