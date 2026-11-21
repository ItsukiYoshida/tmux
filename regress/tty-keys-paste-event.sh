#!/bin/sh

# With the pasteevents feature, a paste arrives as a kitty clipboard (OSC 5522)
# paste event. Text is preferred to an image and must reach the pane as a
# bracketed paste with the paste end sequence removed. A PNG image alone must
# be saved to a file whose path is pasted instead. A paste with no usable type
# must insert nothing.

PATH=/bin:/usr/bin
TERM=screen
export PATH TERM

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
INNER="$TEST_TMUX -LtestI$$ -f/dev/null"
OUTER="$TEST_TMUX -LtestO$$ -f/dev/null"

fail()
{
	echo "$*" >&2
	exit 1
}

cleanup()
{
	$OUTER kill-server 2>/dev/null
	$INNER kill-server 2>/dev/null
	[ -n "$TMP" ] && rm -f "$TMP"
	[ -n "$path" ] && rm -rf "${path%/*}"
}
trap cleanup 0
trap 'exit 1' 1 2 15

TMP=$(mktemp)

$INNER new-session -d -s inner -x200 -y10 \
    "stty raw -echo; printf '\033[?2004h'; exec cat -v" || exit 1
$INNER set-option -g status off || exit 1
$INNER set-option -g assume-paste-time 0 || exit 1
$INNER set-option -as terminal-features '*:pasteevents' || exit 1
$OUTER new-session -d -s outer -x200 -y10 "$INNER attach -t inner" || exit 1
$OUTER set-option -g assume-paste-time 0 || exit 1

i=0
while [ -z "$($INNER list-clients -F '#{client_name}')" ] ||
    [ "$($INNER display-message -p '#{bracket_paste_flag}')" != 1 ]; do
	[ "$i" -lt 100 ] || fail 'client did not attach or enable bracketed paste'
	sleep 0.05
	i=$((i + 1))
done

b64()
{
	printf "$1" | base64 | tr -d '\n'
}

send_raw()
{
	bytes=$(printf '%s' "$1" | od -An -v -tx1)
	$OUTER send-keys -H $bytes || exit 1
}

# Send a paste event offering the given MIME types.
send_event()
{
	send_raw "$(printf '\033]5522;type=read:status=OK:pw=%s\033\\' \
	    "$(b64 token)")"
	send_raw "$(printf '\033]5522;type=read:status=DATA:mime=Lg==;%s\033\\' \
	    "$(b64 "$1")")"
	send_raw "$(printf '\033]5522;type=read:status=DONE\033\\')"
}

# Answer a read request with one DATA packet per remaining argument.
send_reply()
{
	mime=$(b64 "$1")
	shift
	send_raw "$(printf '\033]5522;type=read:status=OK\033\\')"
	for chunk do
		send_raw "$(printf '\033]5522;type=read:status=DATA:mime=%s;%s\033\\' \
		    "$mime" "$(b64 "$chunk")")"
	done
	send_raw "$(printf '\033]5522;type=read:status=DONE\033\\')"
}

wait_output()
{
	i=0
	while [ "$i" -lt 100 ]; do
		actual=$($INNER capture-pane -p | tr -d '\n')
		case "$actual" in
		$1) return 0 ;;
		esac
		sleep 0.05
		i=$((i + 1))
	done
	fail "got '$actual', expected '$1'"
}

send_event 'image/png text/plain;charset=utf-8 text/plain'
send_reply 'text/plain;charset=utf-8' 'hello\033[201~' 'world'
expected='^[[200~helloworld^[[201~'
wait_output "$expected"

send_event 'image/png text/html'
send_reply image/png '\211PNG\r\n\032\n' '\000\001\002'
wait_output "$expected"'^[[200~/*.png^[[201~'
path=${actual#"$expected"^[[200~}
path=${path%^[[201~}
printf '\211PNG\r\n\032\n\000\001\002' >"$TMP"
cmp "$path" "$TMP" || fail "$path does not hold the pasted image"
expected=$expected"^[[200~$path^[[201~"

send_event 'text/uri-list'
send_raw x
wait_output "$expected"x

exit 0
