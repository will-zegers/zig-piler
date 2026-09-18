#!/usr/bin/env bash

if [ -z $1 ]; then
  echo "Usage: $0 <chapter> [state]"
  exit 1
fi

chapter=$(($1))

if [ ! -z $2 ]; then
  stage="--$2"
fi

passed=0
total=0
function test_directory {
  local dir=$1
  local expect_fail=$([[ $dir =~ "invalid" ]] && echo true || echo false)

  for file in $dir/*; do
    # recursive call on subdirectory
    if [ -d "$file" ]; then
      test_directory "$file"

    # run zig-piler on any .c files
    elif [[ $file =~ \.c$ ]]; then
      total=$((total + 1))

      zig-out/bin/zig-piler $stage "$file" &> /dev/null
      res=$?

      if [ $res -ne 0 ] && $expect_fail; then   # fail-expect-fail
        passed=$((passed + 1))
      elif [ $res -eq 0 ] && $expect_fail; then # pass-expect-fail
        echo "Error not caught in $file"
      elif [ $res -ne 0 ]; then                 # fail-expect-pass
        echo "Failed to compile $file"
      else                                      # pass-expect-pass
        passed=$((passed + 1))
      fi
    fi
  done
}

zig build || exit 1

for (( i = 1; i <= chapter; i++ )); do
  echo "Testing chapter $i"
  test_directory "tests/chapter_$i"
done

if [[ $passed -eq $total ]]; then echo -n 🥳
elif [[ $passed -gt $(($total - $passed)) ]]; then echo -n 🤔
elif [[ $passed -gt 0 ]]; then echo -n 🫠
else echo -n 💀
fi
echo " $passed / $total tests successfull "
