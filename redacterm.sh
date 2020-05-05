#!/bin/bash

# RedacTerm
# Copyright (c) 2020 Paul Taylor @bao7uo
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this output_file except in compliance with the License.
# You may obtain a copy of the License at

# http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

if [ -z "${BASH_VERSINFO}" ] || [ -z "${BASH_VERSINFO[0]}" ] || [ ${BASH_VERSINFO[0]} -lt 4 ]
  then echo "Requires Bash 4"
  exit 1
fi

echo -ne '\x1b7'  # save cursor position and attribute
TTY_SAVED_CONFIG="$(stty -g)"
stty -echo        # prevent input echoing to terminal

run=""

function safe_exit {
  run="stop"
  prompt_write
  echo -n "[SIG] - Press Enter for clean exit" 
}

trap "safe_exit" INT TERM QUIT

PROMPT="$(PS1=\"$PS1\" echo -n | bash -i 2>&1)"
PROMPT=$(echo -n "${PROMPT%exit}")

PERLBB='s/\e\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]//g;s/\e[PX^_].*?\e\\//g;s/\e\][^\a]*(?:\a|\e\\)//g;s/\e[\[\]A-Z\\^_@]//g;'

PROMPT_PLAIN=$(echo -n "$PROMPT" | perl -pe "$PERLBB")

PROMPT_LENGTH=${#PROMPT_PLAIN}

key=""
key_byte=""

irow=""
icol=""

prow=""
pcol=""

crow=""
ccol=""

erow=""
ecol=""

trows=""
tcols=""

edit=""

fcolour=0
bcolour=49

mode_change=""

declare -A effects=(
  [1]="" # bold
  [2]="" # faint
  [3]="" # italic
  [4]="" # uline
  [5]="" # slow
  [6]="" # reverse
  [7]="" # crossed
  [53]="" # overlined
)

function read_key_byte {
  if [ -n "$1" ]; then 
    read -rsN1 -t 0.1 key_byte
  else 
    read -rsN1 key_byte 
  fi
}

function read_escape_seq {  # ensure only escape sequence read
  escape_seq='E'
  read_key_byte pause 
  re_esc='[\[O\ ]'
  if [[ $key_byte =~ $re_esc ]]; then # detect if esc ir esc seq
    escape_seq+=$key_byte
    key_byte=' '
    re_esc_seq='[^~A-Z]' 
    while [[ $key_byte =~ $re_esc_seq ]]; do
      read_key_byte
      escape_seq+=$key_byte
    done
    key=$escape_seq
  else
    key='1b'
  fi
}

function get_key {
  read_key_byte
  if [[ $key_byte =~ [0-9A-Za-z\ !-~] ]]; then
    key="$key_byte"
  elif [ $(printf "%x" "'$key_byte") == "1b" ]; then
    read_escape_seq 
  else key=$(printf "%02x" "'$key_byte")
  fi
}

function get_terminal {
  trows=$(stty size | cut -d' ' -f1)
  tcols=$(stty size | cut -d' ' -f2) 
}

function get_cursor_pos {
  echo -ne "\x1b[6n" > /dev/tty
  IFS=';' read -t 1 -s -d 'R' ROW COL < /dev/tty
  crow="${ROW#*\[}"
  ccol="${COL#*\[}"
}

function set_menu_key {
  echo -ne "\x1b[7m" 
}

function unset_menu_key {
  echo -ne "\x1b[27m" 
}

function initial_menu_key {
  set_menu_key
  echo -ne "${1:0:1}" # grab first char
  unset_menu_key
  echo -ne "${1:1:$(( ${#1} - 1 ))}" # remaining chars
}

function status_initial_menu_key {
  result="$1"
  [ -z "$edit" ] && result=$(initial_menu_key $result)
  echo -n $result
}

function clear_to_line_end {
  echo -ne "\x1b[2K"
}

function status_clear {
  get_terminal
  cursor_set_pos $trows 1
  clear_to_line_end
}

function fill_row {
  cursor_set_pos $2 1
  crow=$prow	# save prev row
  ccol=$pcol	# save prev col
  set_colour $3
  for (( i=1; i<=$tcols; i++ )); do
    echo -n "$1"
  done
  cursor_set_pos $prow $pcol
  set_colour 0    
}

function status_update {
  ptrows=$trows
  ptcols=$tcols
  get_terminal
  if [ "$ptrows" != "$trows" ] || [ "$ptcols" != "$tcols" ] || [ "$mode_change" == "true" ]; then
    [ -z "$edit" ] && fill_row " " $trows 42
    [ -n "$edit" ] && fill_row " " $trows 43
    mode_change=""
  fi
  cursor_set_pos $trows 1
  printf -v status_row "%0"${#trows}"d" $prow
  printf -v status_col "%0"${#tcols}"d" $pcol
  [ -z "$edit" ] && set_colour 30 42
  [ -n "$edit" ] && set_colour 30 43
  status_edit=$(status_initial_menu_key "edit")
  status_colour=$(status_initial_menu_key "fg")
  status_background=$(status_initial_menu_key "bg")
  status_reset=$(status_initial_menu_key "reset")
  status_quit=$(status_initial_menu_key "quit")
  echo -n " RedacTerm | R:$status_row/$trows,C:$status_col/$tcols | "
  [ -z "$edit" ] && echo -n "$status_edit | $status_colour | $status_background | fx "
  [ -z "$edit" ] && set_menu_key && echo -n "1234567890" && unset_menu_key
  [ -z "$edit" ] && echo -n " | $status_reset | $status_quit" 
  [ -n "$edit" ] && echo -n "[Esc] to leave edit mode"
  set_colour 0
  cursor_set_pos $prow $pcol
}

function cursor_set_pos {
  echo -ne "\x1b[$1;$2H" 
  prow=$crow
  pcol=$ccol
  crow=$1 
  ccol=$2
}

function cursor_move {
# arg1 direction arg2 distance arg3 enter
  declare -A DIRS_RDELTAS=(
    [U]="-1"
    [D]="1"
    [L]="0"
    [R]="0"
  )

  declare -A DIRS_CDELTAS=(
    [U]="0"
    [D]="0"
    [L]="-1"
    [R]="1"
  )

  r_delta=${DIRS_RDELTAS[$1]} 
  c_delta=${DIRS_CDELTAS[$1]}
  r_delta_multiple=$(( $r_delta * $2 ))
  c_delta_multiple=$(( $c_delta * $2 ))

  r_new=$(( $crow + $r_delta_multiple ))
  c_new=$(( $ccol + $c_delta_multiple ))

  if [ $r_new -gt $trows ]; then r_new=1
  elif [ $r_new -le 0 ]; then r_new=$trows
  fi
  if [ $c_new -gt $tcols ]; then c_new=1
  elif [ $c_new -le 0 ]; then c_new=$tcols
        fi
  
  cursor_set_pos $r_new $c_new

  [ -n "$3" ] && erow=$crow && ecol=$ccol
}

function set_colour {
  colour_builder=""
  for i in $@; do
    colour_builder+="\x1b["$i"m"
  done
  echo -ne $colour_builder
}

function edit_mode_set {
  edit="true"
  mode_change="true"
  if [ -z "$erow" ]; then erow=$crow; else crow=$erow; fi
  if [ -z "$ecol" ]; then ecol=$ccol; else ccol=$ecol; fi
  cursor_set_pos $erow $ecol
}

function edit_mode_unset {
  edit=""
  mode_change="true"
  erow=$crow
  erow=$crow
}

function edit_tab { 
  set_colour $fcolour $bcolour
  echo -n "   "
  set_colour 0
  cursor_move R 3
}
  
function edit_enter { 
  erow=$(( $erow + 1 ))
  cursor_set_pos $erow $ecol
}
  
function edit_backspace {
  cursor_move L 1
  echo -n " "
}

function edit_delete {
  echo -n " "
}

function edit_type {
  set_colour 0 $fcolour $bcolour ${effects[@]}
  echo -n "$key" 
  set_colour 0
  cursor_move R 1
}

function colour_cycle {
  new_colour=$3
  [ "$3" == "0" ] && new_colour=$(( $1 - 1 ))
  new_colour=$(( $new_colour + 1 ))
  [ "$new_colour" == "$(( $2 + 1 ))" ] && new_colour=$1
  echo -n $new_colour
}

function prompt_write {
  cursor_set_pos $(( $irow - 1)) 1
  clear_to_line_end
  echo -n "$PROMPT"
  cursor_move R $PROMPT_LENGTH 
}

function colour_sample {
 prompt_write
 set_colour 0 $fcolour $bcolour ${effects[@]}
 echo -ne "(*) - Colour Sample "
 set_colour 0
 cursor_move R 1
}

function effect_toggle {
  if [ "${effects[$1]}" == "$1" ]; then effects[$1]="";
  else effects[$1]="$1"
  fi
  colour_sample
}

function colour_var_reset {
  fcolour=29
  bcolour=49
  for effect in "${!effects[@]}"; do
    effects[$effect]=""
  done
  colour_sample
}

function colour_mode_set_f {
  fcolour=$(colour_cycle 30 39 $fcolour)
  colour_sample
}

function colour_mode_set_b {
  bcolour=$(colour_cycle 40 49 $bcolour)
  colour_sample
}

get_cursor_pos
irow=$crow
icol=$ccol
status_update
prompt_write
 
while [ -z "$run" ] ; do
  get_key
  [ -n "$run" ] && break

  declare -A KEY_DEFS=(
  )

  declare -A KEY_DEFS_MENU=(
    ["Q"]="break"
    ["1B"]="break"
    ["E"]="edit_mode_set"
    ["F"]="colour_mode_set_f"
    ["B"]="colour_mode_set_b"
    ["R"]="colour_var_reset"
    ["1"]="effect_toggle 1"  # bold
    ["2"]="effect_toggle 2"  # faint
    ["3"]="effect_toggle 3"  # italic
    ["4"]="effect_toggle 4"  # uline
    ["5"]="effect_toggle 5"  # slow
    ["6"]="effect_toggle 7"  # reverse
    ["7"]="effect_toggle 9"  # crossed
    ["8"]="effect_toggle 53 " # overlined
  )

  declare -A KEY_DEFS_EDIT=(
    ["E[A"]="cursor_move U 1 true"
    ["E[B"]="cursor_move D 1 true"
    ["E[C"]="cursor_move R 1 true"
    ["E[D"]="cursor_move L 1 true"
    ["1B"]="edit_mode_unset"
    ["09"]="edit_tab"
    ["0A"]="edit_enter"
    ["7F"]="edit_backspace"
    ["E[3~"]="edit_delete"
  )
 
  [ -n "$edit" ] && [[ $key =~ ^[A-Za-z0-9\ !-~]{1}$ ]] && edit_type

  key=$(echo -n "$key" | tr [:lower:] [:upper:]) 

  ${KEY_DEFS[$key]}

  [ -z "$edit" ] && ${KEY_DEFS_MENU[$key]}
  
  [ -n "$edit" ] && ${KEY_DEFS_EDIT[$key]}
  
  status_update
done

status_clear


echo -ne "\x1b8" # restore cursor position and attributes
cursor_set_pos $(( $irow - 1 )) 1
clear_to_line_end

stty "$TTY_SAVED_CONFIG"
