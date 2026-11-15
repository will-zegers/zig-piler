#!/usr/bin/env bash

if [ -z $1 ]; then
  echo "Usage: $0 <chapter> [state]"
  exit 1
fi

# skipping these files for now since they need an extra platform-specific source file
SKIP="
  tests/chapter_9/valid/stack_arguments/stack_alignment.c
  tests/chapter_10/valid/push_arg_on_page_boundary.c
"

# tests with calls to <math.c> functions
NEEDS_LIBMATH="
  tests/chapter_13/valid/function_calls/standard_library_call.c
  tests/chapter_13/valid/libraries/double_params_and_result.c
"

chapter=$(($1))

if [ ! -z $2 ]; then
  stage="--$2"
fi

out_file="results.txt"

passed=0
total=0
function test_directory {
  local dir=$1
  local is_library_dir=false
  if [[ $dir =~ "libraries" ]]; then
    is_library_dir=true
  fi
  local expect_fail=$([[ $dir =~ "invalid" ]] && echo true || echo false)

  for file in $dir/*; do

    # recursive call on subdirectory
    if [ -d "$file" ]; then
      test_directory "$file"

    # run zig-piler on any .c files
    elif [[ $file =~ \.c$ ]] && ! [[ $SKIP =~ $file ]]; then
      local basename=${file::-2} # remove the '.c' extension

      local linked_libs=""
      for f in $NEEDS_LIBMATH; do
        if [[ $f == $file ]]; then
          linked_libs="-lm"
        fi
      done

      # ignore client files, just add them as an additional source for the base file
      if $is_library_dir; then
        if [[ $file =~ "_client" ]]; then
          continue
        else
          file="$file ${basename}_client.c"
        fi
      fi

      total=$((total + 1))
      zig-out/bin/zig-piler $stage ${file} ${linked_libs} &> results.txt
      res=$?
      rm -rf $basename ${basename}.s ${basename}_client.s

      # check the error output for memory leak reports
      grep "error(SafeAllocator): leaked" results.txt &> /dev/null
      leak=$?
      if [ $leak -eq 0 ]; then
        echo "  [!] $file shows a memory leak"
      fi

      if [ $res -ne 0 ] && $expect_fail; then   # fail-expect-fail
        if [ $leak -ne 0 ]; then
          passed=$((passed + 1))
        fi
      elif [ $res -eq 0 ] && $expect_fail; then # pass-expect-fail
        echo "Error not caught in $file"
      elif [ $res -ne 0 ]; then                 # fail-expect-pass
        echo "Failed to compile $file"
      else                                      # pass-expect-pass
        if [ $leak -ne 0 ]; then
          passed=$((passed + 1))
        fi
      fi
    fi
  done
}

zig build || exit 1

for (( i = 1; i <= chapter; i++ )); do
  echo "Testing chapter $i"
  test_directory "tests/chapter_$i"
done
rm $out_file

if [[ $passed -eq $total ]]; then echo -n 🥳
elif [[ $passed -gt $(($total - $passed)) ]]; then echo -n 🤔
elif [[ $passed -gt 0 ]]; then echo -n 🫠
else echo -n 💀
fi
echo " $passed / $total tests successfull "

