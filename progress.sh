#!/usr/bin/env bash

if [ -z "$_progress_included" ]; then
	_progress_included=true
else
	return 0
fi

#    An asynchronous progress bar inspired by APT PackageManagerFancy Progress
#    Copyright (C) 2018  Kristoffer Minya
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <https://www.gnu.org/licenses/>
set -a

# The following terms are used for maintainment
# FIXME  :   Code that needs to improved or does not work
# DEBUG  :   Code that needs to be debugged
# TEST   :   Code that needs to be tested for alternatives 
# TODO   :   Reminder for code that needs to be added or changed
# FUTURE :   For future changes, this must be considered
# IDEA   :   Ideas for future improvement or added features

percentage=""
last_reported_progress=""

#-- In which rate reporting should be done
reporting_steps=${reporting_steps:-1}       # reporting_step can be set by the caller, defaults to 1

#-- progress bar mode: percent, eta (time estimate), wait (time estimate)
bar_mode="${bar_mode:-percent}"

foreground="${foreground:-$(tput setaf 0)}" # Foreground can be set by the caller, defaults to black
background="${background:-$(tput setab 2)}" # Background can be set by the caller, defaults to green
reset_color="$(tput sgr0)"

#-- Options to change progressbar look
LEFT_BRACKET="${LEFT_BRACKET:-[}"
RIGHT_BRACKET="${RIGHT_BRACKET:-]}"
FILL="${FILL:-#}"
REMAIN="${REMAIN:-.}"

#-- Command aliases for readability
___stty() {
	stty ${1+"$@"} </dev/tty
}
___echo() {
	echo ${1+"$@"} >/dev/tty
}
___printf() {
	printf ${1+"$@"} >/dev/tty
}
___tput() {
	tput ${1+"$@"} >/dev/tty
}
___save_cursor() {
	___tput sc ${1+"$@"}
}
___restore_cursor() {
	___tput rc ${1+"$@"}
}
___disable_cursor() {
	___tput civis ${1+"$@"}
}
___enable_cursor() {
	___tput cnorm ${1+"$@"}
}
___scroll_area() {
	___tput csr ${1+"$@"}
}
___move_to() {
	___tput cup ${1+"$@"}
}
___move_up() {
	___tput cuu ${1+"$@"}
}
___flush() {
	___tput ed ${1+"$@"}
}


# Bash does not handle floats
# This section defines some math functions using awk
# ==================================================
export LC_ALL=C

math::floor() {
  #-- This function takes a pseudo-floating point as argument
  #-- and rounds down to nearest integer
  awk -v f="$1" 'BEGIN{f=int(f); print f}'
}

math::round() {
  #-- This function takes a pseudo-floating point as argument
  #-- and rounds to nearest integer
  awk -v f="$1" 'BEGIN {printf "%.0f\n", f}'
}

math::min() {
  #-- Takes two values as arguments and compare them
  awk -v f1="$1" -v f2="$2" 'BEGIN{if (f1<=f2) min=f1; else min=f2; print min "\n"}'
}

math::max() {
  #-- Takes two values as arguments and compare them
  awk -v f1="$1" -v f2="$2" 'BEGIN{if (f1>f2) max=f1; else max=f2; print max "\n"}'
}

math::calc() {
  #-- Normal calculator
  awk "BEGIN{print $*}"
}

math::linear_regression() {
  #-- Fit a straight line to some x and y data and calculate an (x/y) estimate for a (y/x) target value.
  #-- Parameters are: x values and y values (both as a single string, values separated by space), target axis (x or y), and target value
  #-- The estimate will be written to stdout if it can be calculated.
  #-- Nothing is written if there is not enough data, or if the fitted line is vertical, or if it is horizontal and the target axis is y.
  #-- The return value of the function reflects whether an estimate was produced (0) or not (1).
  awk "
    BEGIN {
      n_x = split(\"$1\", data_x, \" \")
      n_y = split(\"$2\", data_y, \" \")
      if (n_x < n_y) n = n_x; else n = n_y
      if (n < 2) exit 1
      target_axis=\"$3\"
      target = $4
      min_x = \"\"
      for (i = 1; i <= n; ++i) {
        x = data_x[i]
        if (length(min_x) == 0 || x < min_x) {
          min_x = x
        }
      }
      sum_x = 0
      sum_x2 = 0
      sum_y = 0
      sum_xy = 0
      for (i = 1; i <= n; ++i) {
        x = data_x[i] - min_x
        y = data_y[i]
        sum_x += x
        sum_x2 += x * x
        sum_y += y
        sum_xy += x * y
      }
      avg_x = sum_x / n
      avg_y = sum_y / n
      m_y = sum_xy - sum_y * avg_x
      m_x = sum_x2 - sum_x * avg_x
      estimate = \"\"
      if (m_x != 0) {
        m = m_y / m_x
        y0 = avg_y - avg_x * m
        if (target_axis == \"x\") {
          estimate = y0 + (target - min_x) * m
        } else if (target_axis == \"y\" && m != 0) {
          estimate = min_x + (target - y0) / m
        }
      }
      if (length(estimate)) {
        print estimate
        exit 0
      } else {
        exit 1
      }
    }
  "
}


####################################################




# The main function stack
# ==================================================


__tty_size() {
  set -- $(___stty size)
  HEIGHT=$1
  WIDTH=$2
}

__change_scroll_area() {
  local -i n_rows=$1
  #-- Return if number of lines is 1
  if (( n_rows <= 1)); then
    return 1
  fi

  ((n_rows-=2))

  #-- Go down one line to avoid visual glitch 
  #-- when terminal scroll region shrinks by 1
  ___echo

  #-- Save cursor position
  ___save_cursor

  #-- Set scroll region
  ___scroll_area 0 $n_rows

  #-- Restore cursor
  ___restore_cursor

  #-- Move up 1 line in case cursor was saved outside scroll region
  ___move_up 2

  ___echo

  #-- Set tty size to reflect changes to scroll region
  #-- this is to avoid i.e pagers to override the progress bar
  ((++n_rows))

  #-- Temporarily disabling SIGWINCH to avoid a loop caused by stty sending SIGWINCH whenever theres a change in size
  trap '' WINCH
  ___stty rows $n_rows
  trap handle_sigwinch WINCH
}

__status_changed() {
  local StepsDone TotalSteps time_estimate seconds_remaining hours_remaining remain_sign
  local -i __int_percentage

  __is_number "$1" || return
  __is_number "$2" || return
  StepsDone="$1"
  TotalSteps="$2"

  #-- FIXME
  #-- Sanity check reporting_steps, if this value is too big no progress will be written
  #-- Should that really be checked here?

  percentage=$(math::calc "$(math::calc "$StepsDone/$TotalSteps")*100.00")
  sampled_times+=($(( $(date '+%s') - $start_time )))
  sampled_pctgs+=($percentage)

  ((__int_percentage=$(math::round "$percentage")))

  if (( __int_percentage < (last_reported_progress + reporting_steps) )); then
    return 1
  fi

  time_estimate=$(math::linear_regression "${sampled_times[*]}" "${sampled_pctgs[*]}" y 100)
  if [ -n "$time_estimate" ] && [ "$bar_mode" == "eta" ]; then
    time_estimate=$(math::round $time_estimate)
    seconds_remaining=$(( start_time + time_estimate - $(date '+%s') ))
    if (( seconds_remaining > 24 * 60 * 60 * 365 )); then
      printf -v progress_str "ETA:  [%+7.1fy]" $(math::calc "$seconds_remaining / $(( 24 * 60 * 60 * 365 ))")
    elif (( seconds_remaining > 24 * 60 * 60 * 7 )); then
      printf -v progress_str "ETA:  [%+7.1fw]" $(math::calc "$seconds_remaining / $(( 24 * 60 * 60 * 7 ))")
    elif (( seconds_remaining > 24 * 60 * 60 )); then
      printf -v progress_str "ETA:  [%+7.1fd]" $(math::calc "$seconds_remaining / $(( 24 * 60 * 60 ))")
    else
      printf -v progress_str "ETA:  [%(%H:%M:%S)T]" $(( start_time + time_estimate ))
    fi
  elif [ -n "$time_estimate" ] && [ "$bar_mode" == "wait" ]; then
    seconds_remaining=$(( start_time + $(math::round $time_estimate) - $(date '+%s') ))
    if (( seconds_remaining < 0 )); then
      remain_sign="-"
      seconds_remaining=$(( -seconds_remaining ))
    else
      remain_sign=""
    fi
    printf -v hours_remaining "%s%d" "$remain_sign" $(( seconds_remaining / 3600 ))
    printf -v progress_str "Wait: [%2s:%02d:%02d]" "$hours_remaining" $(( (seconds_remaining % 3600 ) / 60 )) $(( seconds_remaining % 60 ))
  else
    printf -v progress_str "Progress: [%3li%%]" $__int_percentage
  fi
}

__progress_string() {
  local output Percent
  local -i OutputSize BarSize BarDone it
  
  output=""
  Percent="$1"
  ((OutputSize=$2))

  #-- Return an empty string if OutputSize is less than 3
  if ((OutputSize < 3)); then
    echo "$output"
    return 1
  fi

  ((BarSize=OutputSize-2))
  
  BarDone=$(math::max 0 "$(math::min $BarSize "$(math::floor "$(math::calc "$Percent*$BarSize")")")")
  
  output="${LEFT_BRACKET}"
  for (( it = 0; it < BarDone; it++ )); do
    output+="${FILL}"
  done
  for (( it = 0; it < BarSize - BarDone; it++ )); do
    output+="${REMAIN}"
  done
  output+="${RIGHT_BRACKET}"
  
  echo "$output"

  return 0
}

__draw_status_line() {
  __tty_size
  if (( HEIGHT < 1 || WIDTH < 1 )); then
    return 1
  fi

  local current_percent progress_bar
  local -i padding progressbar_size
  ((padding=4))

  progress_bar=""

  #-- Save the cursor
  ___save_cursor
  #-- Make cursor invisible
  ___disable_cursor

  #-- Move to last row
  ___move_to $((HEIGHT)) 0
  ___printf '%s' "${background}${foreground}${progress_str}${reset_color}"

  ((progressbar_size=WIDTH-padding-${#progress_str}))
  current_percent=$(math::calc "$percentage/100.00")
  
  progress_bar="$(__progress_string "${current_percent}" ${progressbar_size})"

  ___printf '%s' " ${progress_bar} "

  #-- Restore the cursor
  ___restore_cursor
  ___enable_cursor

  ((last_reported_progress=$(math::round "$percentage")))

  return 0
}

# checks if $1 is a floating-point number
# (leading zeros forbidden, digits before and after decimal point required, scientific notation allowed)
__is_number() {
  if [[ "$1" =~ ^[+-]?(0|[1-9][0-9]*)([.][0-9]+)?(e[+-]?(0|[1-9][0-9]*))?$ ]]; then
    return 0
  else
    echo "Not a number: $1" >&2
    return 1
  fi
}


bar::start() {
  #-- TODO: Track process that called this function
  # proc...
  # Check if /dev/tty is available
  if ! bash -c ': >/dev/tty </dev/tty' >/dev/null 2>&1; then
    echo "Can't read/write /dev/tty" >&2
    return 1
  fi
  E_START_INVOKED=-1
  #-- reset bar state
  percentage="0.0"
  last_reported_progress=-1
  reporting_steps=${reporting_steps:-1}
  bar_mode="${bar_mode:-percent}"
  case "$bar_mode" in
    percent|eta|wait)
      ;;
    *)
      echo "bar_mode is '$bar_mode' - supported values: percent, eta, wait" >&2
      ;;
  esac
  start_time=$(date '+%s')
  unset sampled_times sampled_pctgs
  declare -a sampled_times sampled_pctgs
  __tty_size
  __change_scroll_area $HEIGHT
}

bar::stop() {
  E_STOP_INVOKED=-1
  if (( ! ${E_START_INVOKED:-0} )); then
    echo "Warn: bar::stop called but bar::start was not invoked" >&2 
    ___echo "Returning." # Exit or return?
    return 1
  fi
  #-- Reset bar::start check
  E_START_INVOKED=0

  __tty_size
  if ((HEIGHT > 0)); then
    #-- Passing +2 here because we changed tty size to 1 less than it actually is
    __change_scroll_area $((HEIGHT+2))

    #-- tput ed might fail (OS X) in which case we force clear
    trap '___printf "\033[J"' ERR

    #-- Flush progress bar
    ___flush
   
    trap - ERR
    #-- Go up one row after flush
    ___move_up 1
    ___echo
  fi
  #-- Restore original (if any) handler
  trap - WINCH
  return 0
}

#-- FIXME: Pass worker pid?
bar::status_changed() {
  if (( ! ${E_START_INVOKED:-0} )); then
    echo "ERR: bar::start not called" >&2
    ___echo "Exiting."
    exit 1
  fi

  if ! __status_changed "$1" "$2"; then
    return 1
  fi
  
  __draw_status_line
  return $?
}


####################################################


# This section defines some functions that should be
# triggered for traps
# ==================================================


handle_sigwinch() {
  __tty_size
  n_rows=$HEIGHT
  __change_scroll_area $n_rows
  __draw_status_line
}

handle_exit() {
  #-- if stop_exit doesn't have value it means it wasn't invoked
  (( ${E_START_INVOKED:-0} && ! ${E_STOP_INVOKED:-0} )) && bar::stop
  trap - EXIT
  exit
}


####################################################

set +a

trap handle_sigwinch WINCH
trap handle_exit EXIT HUP INT QUIT PIPE TERM
