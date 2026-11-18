#!/bin/zsh
# Flags literal spacing, radii, colours, opacities, shadows and font sizes in the operator views.
# Use the tokens in Transcribe/Views/DesignSystem.swift instead. A line ending in
# "// design: fixed — <why>" is allowed; so is anything between "design-lint: off" and "design-lint: on".
# PresentationView is exempt: it is a projector view sized from its own font-size setting.
cd "${0:A:h}/.." || exit 2
pattern='(padding|spacing)\(?[:,]? *(\.[a-z]+, *)?([1-9][0-9]*(\.[0-9]+)?|0\.[0-9]+)\)?|cornerRadius: *[0-9]|Radius: *[0-9]|opacity\(0?\.[0-9]|shadow\(|\.font\(\.system\(size: *[0-9]|Color\.(red|orange|yellow|green|blue|purple|pink)\b|\((\.red|\.orange|\.yellow|\.green|\.blue|\.purple|\.pink)\)'
found=0
for file in Transcribe/Views/*.swift; do
  case ${file:t} in DesignSystem.swift|PresentationView.swift) continue ;; esac
  out=$(awk '
    /design-lint: off/ { skip = 1 } /design-lint: on/ { skip = 0; next }
    skip || /design: fixed/ || /^[[:space:]]*\/\// { next }
    { printf "%s:%d: %s\n", FILENAME, FNR, $0 }' "$file" | grep -E -- "$pattern")
  [[ -n $out ]] && { print -r -- "$out"; found=1 }
done
(( found )) && { print "\nUse a Design token, or mark the line \"// design: fixed — <why>\"."; exit 1 }
print "design lint: clean"
