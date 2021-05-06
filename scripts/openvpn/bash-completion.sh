_pivpn()
{
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    dashopts="-a -c -d -l -r -h -u -up -bk"
    opts="debug add clients list revoke uninstall help update backup"
    if [ "${#COMP_WORDS[@]}" -eq 2 ]
    then
        if [[ ${cur} == -* ]] ; then
            COMPREPLY=( $(compgen -W "${dashopts}" -- "${cur}") )
        else
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
        fi
    elif [[ ( "$prev" == "add" || "$prev" == "-a" ) && "${#COMP_WORDS[@]}" -eq 3 ]]
    then
        COMPREPLY=( $(compgen -W "nopass" -- "${cur}") )
    fi
    return 0
}
complete -F _pivpn pivpn
