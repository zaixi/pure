# Pure
# by Sindre Sorhus
# https://github.com/sindresorhus/pure
# MIT License

# For my own and others sanity
# git:
# %b => current branch
# %a => current action (rebase/merge)
# prompt:
# %F => color dict
# %f => reset color
# %~ => current path
# %* => time
# %n => username
# %m => shortname host
# %(?..) => prompt conditional - %(condition.true.false)
# terminal codes:
# \e7   => save cursor position
# \e[2A => move cursor 2 lines up
# \e[1G => go to position 1 in terminal
# \e8   => restore cursor position
# \e[K  => clears everything after the cursor on the current line
# \e[2K => clear everything on the current line

prompt_pure_set_title() {
	setopt localoptions noshwordsplit

	# emacs terminal does not support settings the title
	(( ${+EMACS} )) && return

	case $TTY in
		# Don't set title over serial console.
		/dev/ttyS[0-9]*) return;;
	esac

	# Show hostname if connected via ssh.
	local hostname=
	if [[ -n $prompt_pure_state[username] ]]; then
		# Expand in-place in case ignore-escape is used.
		hostname="${(%):-(%m) }"
	fi

	local -a opts
	case $1 in
		expand-prompt) opts=(-P);;
		ignore-escape) opts=(-r);;
	esac

	# Set title atomically in one print statement so that it works
	# when XTRACE is enabled.
	print -n $opts $'\e]0;'${hostname}${2}$'\a'
}

prompt_pure_preexec() {
	if [[ -n $prompt_pure_git_fetch_pattern ]]; then
		# detect when git is performing pull/fetch (including git aliases).
		local -H MATCH MBEGIN MEND match mbegin mend
		if [[ $2 =~ (git|hub)\ (.*\ )?($prompt_pure_git_fetch_pattern)(\ .*)?$ ]]; then
			# we must flush the async jobs to cancel our git fetch in order
			# to avoid conflicts with the user issued pull / fetch.
			async_flush_jobs 'prompt_pure'
		fi
	fi

	# shows the current dir and executed command in the title while a process is active
	prompt_pure_set_title 'ignore-escape' "$PWD:t: $2"

	# Disallow python virtualenv from updating the prompt, set it to 12 if
	# untouched by the user to indicate that Pure modified it. Here we use
	# magic number 12, same as in psvar.
	export VIRTUAL_ENV_DISABLE_PROMPT=${VIRTUAL_ENV_DISABLE_PROMPT:-12}
}

prompt_pure_preprompt_render() {
	setopt localoptions noshwordsplit

	# Set color for git branch/dirty status, change color if dirty checking has
	# been delayed.
	local git_color=242
	[[ -n ${prompt_pure_git_last_dirty_check_timestamp+x} ]] && git_color=red

	# Initialize the preprompt array.
	local -a preprompt_parts

	# Add git branch and dirty status info.
	typeset -gA prompt_pure_vcs_info
	if [[ -n $prompt_pure_vcs_info[branch] ]]; then
		preprompt_parts+=("%F{$git_color}"'${prompt_pure_vcs_info[branch]}${prompt_pure_git_dirty}%f')
	fi
	# Git pull/push arrows.
	if [[ -n $prompt_pure_git_arrows ]]; then
		preprompt_parts+=('%F{cyan}${prompt_pure_git_arrows}%f')
	fi

	if [[ $1 != precmd ]]; then
		(( total=$EPOCHREALTIME-$start_time ))
		if [[  (( $total > $PURE_GIT_TIMEOUT_MS)) ]];then
			add-zsh-hook -d precmd prompt_pure_precmd
			add-zsh-hook -d preexec prompt_pure_preexec
			preprompt_parts=''
		fi
	fi

	# Construct the new prompt with a clean preprompt.
	local -ah ps1
	ps1=(
		${prompt_pure_state[username]}
		${prompt_pure_state[dir]}
		${preprompt_parts}  # Join parts, space separated.
		${prompt_pure_state[newline]} # Separate preprompt and prompt.
		${prompt_pure_state[prompt]}
	)

	PROMPT="${(j..)ps1}"

	# Expand the prompt for future comparision.
	local expanded_prompt
	expanded_prompt="${(S%%)PROMPT}"

	if [[ $prompt_pure_last_prompt != $expanded_prompt ]]; then
		# Redraw the prompt.
		zle && zle .reset-prompt
	fi

	typeset -g prompt_pure_last_prompt=$expanded_prompt
}

prompt_pure_precmd() {
	# get hook start time
	typeset -g start_time=$EPOCHREALTIME

	# shows the full path in the title
	prompt_pure_set_title 'expand-prompt' '%~'

	# preform async git dirty check and fetch
	prompt_pure_async_tasks

	# print the preprompt

	prompt_pure_preprompt_render "precmd"

	if [[ -n $ZSH_THEME ]]; then
		print "WARNING: Oh My Zsh themes are enabled (ZSH_THEME='${ZSH_THEME}'). Pure might not be working correctly."
		print "For more information, see: https://github.com/sindresorhus/pure#oh-my-zsh"
		unset ZSH_THEME  # Only show this warning once.
	fi
}

prompt_pure_async_git_aliases() {
	setopt localoptions noshwordsplit
	local -a gitalias pullalias

	# list all aliases and split on newline.
	gitalias=(${(@f)"$(command git config --get-regexp "^alias\.")"})
	for line in $gitalias; do
		parts=(${(@)=line})           # split line on spaces
		aliasname=${parts[1]#alias.}  # grab the name (alias.[name])
		shift parts                   # remove aliasname

		# check alias for pull or fetch (must be exact match).
		if [[ $parts =~ ^(.*\ )?(pull|fetch)(\ .*)?$ ]]; then
			pullalias+=($aliasname)
		fi
	done

	print -- ${(j:|:)pullalias}  # join on pipe (for use in regex).
}

prompt_pure_async_vcs_info() {
	setopt localoptions noshwordsplit

	# configure vcs_info inside async task, this frees up vcs_info
	# to be used or configured as the user pleases.
	zstyle ':vcs_info:*' enable git
	zstyle ':vcs_info:*' use-simple true
	# only export two msg variables from vcs_info
	zstyle ':vcs_info:*' max-exports 2
	# export branch (%b) and git toplevel (%R)
	zstyle ':vcs_info:git*' formats '%b' '%R'
	zstyle ':vcs_info:git*' actionformats '%b|%a' '%R'

	vcs_info

	local -A info
	info[pwd]=$PWD
	info[top]=$vcs_info_msg_1_
	info[branch]=$vcs_info_msg_0_

	print -r - ${(@kvq)info}
}

# fastest possible way to check if repo is dirty
prompt_pure_async_git_dirty() {
	setopt localoptions noshwordsplit
	local untracked_dirty=$1

	if [[ $untracked_dirty = 0 ]]; then
		command git diff --no-ext-diff --quiet --exit-code
	else
		test -z "$(command git status --porcelain --ignore-submodules -unormal)"
	fi

	return $?
}

prompt_pure_async_git_fetch() {
	setopt localoptions noshwordsplit

	# set GIT_TERMINAL_PROMPT=0 to disable auth prompting for git fetch (git 2.3+)
	export GIT_TERMINAL_PROMPT=0
	# set ssh BachMode to disable all interactive ssh password prompting
	export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-"ssh"} -o BatchMode=yes"

	# Default return code, indicates Git fetch failure.
	local fail_code=99

	# Guard against all forms of password prompts. By setting the shell into
	# MONITOR mode we can notice when a child process prompts for user input
	# because it will be suspended. Since we are inside an async worker, we
	# have no way of transmitting the password and the only option is to
	# kill it. If we don't do it this way, the process will corrupt with the
	# async worker.
	setopt localtraps monitor

	# Make sure local HUP trap is unset to allow for signal propagation when
	# the async worker is flushed.
	trap - HUP

	trap '
		# Unset trap to prevent infinite loop
		trap - CHLD
		if [[ $jobstates = suspended* ]]; then
			# Set fail code to password prompt and kill the fetch.
			fail_code=98
			kill %%
		fi
	' CHLD

	command git -c gc.auto=0 fetch >/dev/null &
	wait $! || return $fail_code

	unsetopt monitor

	# check arrow status after a successful git fetch
	prompt_pure_async_git_arrows
}

prompt_pure_async_git_arrows() {
	setopt localoptions noshwordsplit
	command git rev-list --left-right --count HEAD...@'{u}'
}

prompt_pure_async_tasks() {
	setopt localoptions noshwordsplit

	# initialize async worker
	((!${prompt_pure_async_init:-0})) && {
		async_start_worker "prompt_pure" -u -n
		async_register_callback "prompt_pure" prompt_pure_async_callback
		typeset -g prompt_pure_async_init=1
	}

	# Update the current working directory of the async worker.
	async_worker_eval "prompt_pure" builtin cd -q $PWD

	typeset -gA prompt_pure_vcs_info

	local -H MATCH MBEGIN MEND
	if [[ $PWD != ${prompt_pure_vcs_info[pwd]}* ]]; then
		# stop any running async jobs
		async_flush_jobs "prompt_pure"

		# reset git preprompt variables, switching working tree
		unset prompt_pure_git_dirty
		unset prompt_pure_git_last_dirty_check_timestamp
		unset prompt_pure_git_arrows
		unset prompt_pure_git_fetch_pattern
		prompt_pure_vcs_info[branch]=
		prompt_pure_vcs_info[top]=
	fi
	unset MATCH MBEGIN MEND

	async_job "prompt_pure" prompt_pure_async_vcs_info

	# # only perform tasks inside git working tree
	[[ -n $prompt_pure_vcs_info[top] ]] || return

	prompt_pure_async_refresh
}

prompt_pure_async_refresh() {
	setopt localoptions noshwordsplit

	if [[ -z $prompt_pure_git_fetch_pattern ]]; then
		# we set the pattern here to avoid redoing the pattern check until the
		# working three has changed. pull and fetch are always valid patterns.
		typeset -g prompt_pure_git_fetch_pattern="pull|fetch"
		async_job "prompt_pure" prompt_pure_async_git_aliases
	fi

	async_job "prompt_pure" prompt_pure_async_git_arrows

	# do not preform git fetch if it is disabled or in home folder.
	if (( ${PURE_GIT_PULL:-1} )) && [[ $prompt_pure_vcs_info[top] != $HOME ]]; then
		# tell worker to do a git fetch
		async_job "prompt_pure" prompt_pure_async_git_fetch
	fi

	# if dirty checking is sufficiently fast, tell worker to check it again, or wait for timeout
	integer time_since_last_dirty_check=$(( EPOCHSECONDS - ${prompt_pure_git_last_dirty_check_timestamp:-0} ))
	if (( time_since_last_dirty_check > ${PURE_GIT_DELAY_DIRTY_CHECK:-1800} )); then
		unset prompt_pure_git_last_dirty_check_timestamp
		# check check if there is anything to pull
		async_job "prompt_pure" prompt_pure_async_git_dirty ${PURE_GIT_UNTRACKED_DIRTY:-1}
	fi
}

prompt_pure_check_git_arrows() {
	setopt localoptions noshwordsplit
	local arrows left=${1:-0} right=${2:-0}

	(( right > 0 )) && arrows+=${PURE_GIT_DOWN_ARROW:-⇣}
	(( left > 0 )) && arrows+=${PURE_GIT_UP_ARROW:-⇡}

	[[ -n $arrows ]] || return
	typeset -g REPLY=$arrows
}

prompt_pure_async_callback() {
	setopt localoptions noshwordsplit
	local job=$1 code=$2 output=$3 exec_time=$4 next_pending=$6
	local do_render=0

	case $job in
		prompt_pure_async_vcs_info)
			local -A info
			typeset -gA prompt_pure_vcs_info

			# parse output (z) and unquote as array (Q@)
			info=("${(Q@)${(z)output}}")
			local -H MATCH MBEGIN MEND
			if [[ $info[pwd] != $PWD ]]; then
				# The path has changed since the check started, abort.
				return
			fi
			# check if git toplevel has changed
			if [[ $info[top] = $prompt_pure_vcs_info[top] ]]; then
				# if stored pwd is part of $PWD, $PWD is shorter and likelier
				# to be toplevel, so we update pwd
				if [[ $prompt_pure_vcs_info[pwd] = ${PWD}* ]]; then
					prompt_pure_vcs_info[pwd]=$PWD
				fi
			else
				# store $PWD to detect if we (maybe) left the git path
				prompt_pure_vcs_info[pwd]=$PWD
			fi
			unset MATCH MBEGIN MEND

			# update has a git toplevel set which means we just entered a new
			# git directory, run the async refresh tasks
			[[ -n $info[top] ]] && [[ -z $prompt_pure_vcs_info[top] ]] && prompt_pure_async_refresh

			# always update branch and toplevel
			prompt_pure_vcs_info[branch]=$info[branch]
			prompt_pure_vcs_info[top]=$info[top]

			do_render=1
			;;
		prompt_pure_async_git_aliases)
			if [[ -n $output ]]; then
				# append custom git aliases to the predefined ones.
				prompt_pure_git_fetch_pattern+="|$output"
			fi
			;;
		prompt_pure_async_git_dirty)
			local prev_dirty=$prompt_pure_git_dirty
			if (( code == 0 )); then
				unset prompt_pure_git_dirty
			else
				typeset -g prompt_pure_git_dirty="*"
			fi

			[[ $prev_dirty != $prompt_pure_git_dirty ]] && do_render=1

			# When prompt_pure_git_last_dirty_check_timestamp is set, the git info is displayed in a different color.
			# To distinguish between a "fresh" and a "cached" result, the preprompt is rendered before setting this
			# variable. Thus, only upon next rendering of the preprompt will the result appear in a different color.
			(( $exec_time > 5 )) && prompt_pure_git_last_dirty_check_timestamp=$EPOCHSECONDS
			;;
		prompt_pure_async_git_fetch|prompt_pure_async_git_arrows)
			# prompt_pure_async_git_fetch executes prompt_pure_async_git_arrows
			# after a successful fetch.
			case $code in
				0)
					local REPLY
					prompt_pure_check_git_arrows ${(ps:\t:)output}
					if [[ $prompt_pure_git_arrows != $REPLY ]]; then
						typeset -g prompt_pure_git_arrows=$REPLY
						do_render=1
					fi
					;;
				99|98)
					# Git fetch failed.
					;;
				*)
					# Non-zero exit status from prompt_pure_async_git_arrows,
					# indicating that there is no upstream configured.
					if [[ -n $prompt_pure_git_arrows ]]; then
						unset prompt_pure_git_arrows
						do_render=1
					fi
					;;
			esac
			;;
	esac

	if (( next_pending )); then
		(( do_render )) && typeset -g prompt_pure_async_render_requested=1
		return
	fi

	[[ ${prompt_pure_async_render_requested:-$do_render} = 1 ]] && prompt_pure_preprompt_render
	unset prompt_pure_async_render_requested
}

prompt_pure_state_setup() {
	setopt localoptions noshwordsplit

	# Check SSH_CONNECTION and the current state.
	local ssh_connection=${SSH_CONNECTION:-$PROMPT_PURE_SSH_CONNECTION}
	local username
	if [[ -z $ssh_connection ]] && (( $+commands[who] )); then
		# When changing user on a remote system, the $SSH_CONNECTION
		# environment variable can be lost, attempt detection via who.
		local who_out
		who_out=$(who -m 2>/dev/null)
		if (( $? )); then
			# Who am I not supported, fallback to plain who.
			who_out=$(who 2>/dev/null | grep ${TTY#/dev/})
		fi

		local reIPv6='(([0-9a-fA-F]+:)|:){2,}[0-9a-fA-F]+'  # Simplified, only checks partial pattern.
		local reIPv4='([0-9]{1,3}\.){3}[0-9]+'   # Simplified, allows invalid ranges.
		# Here we assume two non-consecutive periods represents a
		# hostname. This matches foo.bar.baz, but not foo.bar.
		local reHostname='([.][^. ]+){2}'

		# Usually the remote address is surrounded by parenthesis, but
		# not on all systems (e.g. busybox).
		local -H MATCH MBEGIN MEND
		if [[ $who_out =~ "\(?($reIPv4|$reIPv6|$reHostname)\)?\$" ]]; then
			ssh_connection=$MATCH

			# Export variable to allow detection propagation inside
			# shells spawned by this one (e.g. tmux does not always
			# inherit the same tty, which breaks detection).
			export PROMPT_PURE_SSH_CONNECTION=$ssh_connection
		fi
		unset MATCH MBEGIN MEND
	fi

	username='%F{071}%n%f@%F{071}%m%f:'

	# show username@host if logged in through SSH
	[[ -n $ssh_connection ]] && username='%F{242}%n@%m%f'

	# show username@host if root, with username in white
	[[ $UID -eq 0 ]] && username='%F{red}%n%f@%F{071}%m%f:'

	if [[ "$PURE_SHORT_DIR" == true ]]; then
		dir='%F{blue}$(_fish_collapsed_pwd)%f '
	else
		dir='%F{blue}%~%f '
	fi

	## prompt turns red if the previous command didn't exit with 0
	prompt='%(?.%F{green}.%F{red})❯%f '

	if [[ "$PURE_NEW_LINE" == true ]]; then
		# This variable needs to be set, usually set by promptinit.
		newline=$'\n%{\r%}'
	else
		newline=''
	fi

	if [[ -n $PURE_GIT_TIMEOUT_MS ]]; then
		PURE_GIT_TIMEOUT_MS=$(awk 'BEGIN{print '$PURE_GIT_TIMEOUT_MS'/10}')
	else
		PURE_GIT_TIMEOUT_MS=0.3
	fi

	typeset -gA prompt_pure_state
	prompt_pure_state=(
		username "$username"
		dir      "$dir"
		prompt	 "$prompt"
		newline  "$newline"
	)
}

function _fish_collapsed_pwd() {
    local pwd="$1"
    local home="$HOME"
    local size=${#home}
    [[ $# == 0 ]] && pwd="$PWD"
    [[ -z "$pwd" ]] && return
    if [[ "$pwd" == "/" ]]; then
        echo "/"
        return
    elif [[ "$pwd" == "$home" ]]; then
        echo "~"
        return
    fi
    [[ "$pwd" == "$home/"* ]] && pwd="~${pwd:$size}"
    if [[ -n "$BASH_VERSION" ]]; then
        local IFS="/"
        local elements=($pwd)
        local length=${#elements[@]}
        for ((i=0;i<length-1;i++)); do
            local elem=${elements[$i]}
            if [[ ${#elem} -gt 1 ]]; then
                elements[$i]=${elem:0:1}
            fi
        done
    else
        local elements=("${(s:/:)pwd}")
        local length=${#elements}
        for i in {1..$((length-1))}; do
            local elem=${elements[$i]}
            if [[ ${#elem} > 1 ]]; then
                elements[$i]=${elem[1]}
            fi
        done
    fi
    local IFS="/"
    echo "${elements[*]}"
}

prompt_pure_setup() {
	# Prevent percentage showing up if output doesn't end with a newline.
	export PROMPT_EOL_MARK=''

	prompt_opts=(subst percent)

	# borrowed from promptinit, sets the prompt options in case pure was not
	# initialized via promptinit.
	setopt noprompt{bang,cr,percent,subst} "prompt${^prompt_opts[@]}"

	zmodload zsh/zle
	zmodload zsh/parameter

	autoload -Uz add-zsh-hook
	autoload -Uz vcs_info
	autoload -Uz async && async

	# The add-zle-hook-widget function is not guaranteed
	# to be available, it was added in Zsh 5.3.
	autoload -Uz +X add-zle-hook-widget 2>/dev/null

	add-zsh-hook precmd prompt_pure_precmd
	add-zsh-hook preexec prompt_pure_preexec

	prompt_pure_state_setup

	unset ZSH_THEME  # Guard against Oh My Zsh themes overriding Pure.
}

prompt_pure_setup "$@"
