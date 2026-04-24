#!/usr/bin/env bash
# LaraKit — Interactive prompt helpers

# ask <var> <question> [default]
ask() {
  local var="$1" question="$2" default="${3:-}"
  if [[ "${LARAKIT_QUIET:-false}" == "true" ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local prompt
  if [[ -n "$default" ]]; then
    prompt="${question} ${DIM}[${default}]${NC}: "
  else
    prompt="${question}: "
  fi
  local value
  read -r -p "$(echo -e "  ${YELLOW}?${NC}  ${prompt}")" value
  value="${value:-$default}"
  printf -v "$var" '%s' "$value"
}

# ask_secret <var> <question>
ask_secret() {
  local var="$1" question="$2"
  if [[ "${LARAKIT_QUIET:-false}" == "true" ]]; then
    printf -v "$var" '%s' ""
    return
  fi
  local value
  read -r -s -p "$(echo -e "  ${YELLOW}?${NC}  ${question}: ")" value
  echo
  printf -v "$var" '%s' "$value"
}

# ask_yn <var> <question> [y|n default]
ask_yn() {
  local var="$1" question="$2" default="${3:-n}"
  if [[ "${LARAKIT_QUIET:-false}" == "true" ]]; then
    [[ "$default" == "y" ]] && printf -v "$var" 'true' || printf -v "$var" 'false'
    return
  fi
  local opts value
  if [[ "$default" == "y" ]]; then opts="${GREEN}Y${NC}/n"; else opts="y/${GREEN}N${NC}"; fi
  read -r -p "$(echo -e "  ${YELLOW}?${NC}  ${question} [${opts}]: ")" value
  value="${value:-$default}"
  if [[ "$value" =~ ^[Yy]$ ]]; then
    printf -v "$var" 'true'
  else
    printf -v "$var" 'false'
  fi
}

# ask_choice <var> <question> <option1> <option2> ...
ask_choice() {
  local var="$1" question="$2"
  shift 2
  local options=("$@")
  if [[ "${LARAKIT_QUIET:-false}" == "true" ]]; then
    printf -v "$var" '%s' "${options[0]}"
    return
  fi
  echo -e "  ${YELLOW}?${NC}  ${question}"
  for i in "${!options[@]}"; do
    echo -e "     ${BOLD}$((i + 1)))${NC} ${options[$i]}"
  done
  local choice
  while true; do
    read -r -p "$(echo -e "     Enter choice [1-${#options[@]}]: ")" choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#options[@]}" ]]; then
      printf -v "$var" '%s' "${options[$((choice - 1))]}"
      break
    fi
    echo -e "  ${RED}Invalid choice. Enter a number between 1 and ${#options[@]}.${NC}"
  done
}

# ask_multiselect <result_var> <question> <option1> <option2> ...
# Toggles with space, confirms with enter
ask_multiselect() {
  local var="$1" question="$2"
  shift 2
  local options=("$@")
  local selected=()
  for i in "${!options[@]}"; do selected[$i]=false; done

  echo -e "  ${YELLOW}?${NC}  ${question}"
  echo -e "     ${DIM}Enter numbers separated by spaces (e.g. 1 3 5), or 'all':${NC}"
  for i in "${!options[@]}"; do
    echo -e "     ${BOLD}$((i + 1)))${NC} ${options[$i]}"
  done

  if [[ "${LARAKIT_QUIET:-false}" == "true" ]]; then
    printf -v "$var" '%s' "${options[*]}"
    return
  fi

  local input
  read -r -p "$(echo -e "     Your selection: ")" input

  local result=()
  if [[ "$input" == "all" ]]; then
    result=("${options[@]}")
  else
    for idx in $input; do
      if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 1 ]] && [[ "$idx" -le "${#options[@]}" ]]; then
        result+=("${options[$((idx - 1))]}")
      fi
    done
  fi

  printf -v "$var" '%s' "${result[*]}"
}

confirm_or_exit() {
  local msg="${1:-Continue?}"
  local proceed
  ask_yn proceed "$msg" "y"
  if [[ "$proceed" != "true" ]]; then
    info "Aborted."
    exit 0
  fi
}
