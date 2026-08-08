" File:         vp4.vim
" Description:  vim global plugin for perforce integration
" Last Change:  Nov 22, 2016
" Author:       Emily Ng

"  Explorer window width configuration
" Options:
"   - 'auto'    : 自动适配宽度（根据文件名最长行）
"   - 数字      : 固定宽度（如 30、40、50）
"   - '20%'等   : 按比例设置（窗口宽度的百分比）
" 默认: 'auto'
if !exists('g:vp4_explore_width')
    let g:vp4_explore_width = 'auto'
endif

" 最小窗口宽度（用于 auto 模式）
if !exists('g:vp4_explore_min_width')
    let g:vp4_explore_min_width = 30
endif

" 最大窗口宽度（用于 auto 模式）
if !exists('g:vp4_explore_max_width')
    let g:vp4_explore_max_width = 60
endif

"  Explorer global data structures
" directory object data
" dir_data = {
"   '<full path name>' : {
"       'name' : "<name>/",
"       'folded' : <0 folded, 1 unfolded>,
"       'files' : [
"           {'name': <filename>, 'flags': <flags>}, ...
"       ],
"       'children' : [<list of children full path names>]
"   },
"   ...
" }
"
" root = //main
" parent/               //main
"     child/            //main/parent
"         file0.txt     //main/parent/child
"         file1.txt     //main/parent/child
"     file2.txt         //main/parent
let s:directory_data = {}

" line number to directory prefix map
let s:line_map = {}

" depot directory to local directory map
let s:directory_map = {}
"

"  Helper functions

" Debug helper function - only output if g:vp4_debug is true
function! s:Debug(msg)
    if exists('g:vp4_debug') && g:vp4_debug
        echom a:msg
    endif
endfunction

function! s:GetClientName()
    if g:_vp4_client == ''
        if !executable(g:vp4_perforce_executable)
            return ''
        endif
        let l:text = s:PerforceSystem('-Mj -ztag info')
        try
            let l:dict = json_decode(l:text)
            let g:_vp4_client = get(l:dict, 'clientName', '')
        catch
            call s:Debug("DBG GetClientName json_decode failed: " . l:text)
        endtry
    endif
    return g:_vp4_client
endfunction

" Get workspace dict for a specific file path.
" Returns a dict with fields matching the p4 client spec (Name, Root, Owner,
" etc.).  On failure returns {}.
" Uses g:vp4_client_for_file_cmd if set; otherwise falls back to p4 info
" (which reflects the current default client).
function! s:GetWorkspaceForFile(filename)
    let l:filepath = expand(a:filename)
    call s:Debug("DBG GetWorkspaceForFile: " . l:filepath)

    if g:vp4_client_for_file_cmd != ''
        let l:output = system(g:vp4_client_for_file_cmd . ' ' . shellescape(l:filepath))
        call s:Debug("DBG client_for_file exit=" . v:shell_error . " len=" . strlen(l:output))
        if v:shell_error == 0 && l:output != ''
            try
                let l:dict = json_decode(l:output)
                if has_key(l:dict, 'Name')
                    return l:dict
                endif
                call s:Debug("DBG vp4_client_for_file_cmd returned no 'Name' field")
            catch
                call s:Debug("DBG json_decode failed: " . l:output)
            endtry
        endif
    endif

    " Fall back to p4 info for the default client, but only if the file is
    " actually under that workspace root (avoids showing default workspace for
    " files that don't belong to any p4 workspace).
    try
        let l:info = json_decode(s:PerforceSystem('-Mj -ztag info'))
        let l:dict = {}
        if has_key(l:info, 'clientName')
            let l:dict['Name'] = l:info['clientName']
        endif
        if has_key(l:info, 'clientRoot')
            let l:dict['Root'] = l:info['clientRoot']
        endif
        if has_key(l:dict, 'Root') && stridx(l:filepath, l:dict['Root']) == 0
            return l:dict
        endif
    catch
    endtry

    return {}
endfunction

" Public wrapper — callers outside the plugin can use vp4#GetWorkspaceForFile()
" and pick whatever fields they need (Name, Root, Owner, …).
function! vp4#GetWorkspaceForFile(filename)
    return s:GetWorkspaceForFile(a:filename)
endfunction

" Get client name for a specific file path.
function! s:GetClientNameForFile(filename)
    let l:ws = s:GetWorkspaceForFile(a:filename)
    let l:name = get(l:ws, 'Name', '')
    if l:name != ''
        call s:Debug("DBG Got client for file: " . l:name)
        return l:name
    endif
    return s:GetClientName()
endfunction

"  Generic Helper functions
function! s:BufferIsEmpty()
    return line('$') == 1 && getline(1) == ''
endfunction

" Pad string by appending spaces until length of string 's' is equal to 'amt'
function! s:Pad(s,amt)
    return a:s . repeat(' ',a:amt - len(a:s))
endfunction

" Pad string by prepending spaces until length of string 's' is equal to 'amt'
function! s:PrePad(s,amt)
    return repeat(' ', a:amt - len(a:s)) . a:s
endfunction

" Echo an error message without the annoying 'Detected error in ...' header
function! s:EchoError(msg)
    echohl ErrorMsg
    echom a:msg
    echohl None
endfunction

" Echo a warning message
function! s:EchoWarning(msg)
    echohl WarningMsg
    echom a:msg
    echohl None
endfunction

function! s:GoToWindowForBufferName(name)
    if bufwinnr(bufnr(a:name)) != -1
        exe bufwinnr(bufnr(a:name)) . "wincmd w"
        return 1
    else
        return 0
    endif
endfunction

" Perforce system functions with the specific client
" Return result of calling p4 command
function! s:PerforceSystemWithClient(cmd, client, ...)
    let l:env = a:0 > 0 ? a:1 : ''
    return s:PerforceSystem(" -c " . a:client . " " . a:cmd, l:env)
endfunction

" Perforce system functions with the specific file's client.
" Return result of calling p4 command
" Optional third argument: shell env prefix string, e.g. 'P4DIFF='
function! s:PerforceSystemWithFile(cmd, filepath, ...)
    let l:env = a:0 > 0 ? a:1 : ''
    let l:client_name = s:GetClientNameForFile(a:filepath)
    if strlen(l:client_name) > 0
        call s:Debug("DBG path:" . a:filepath . " client_name:" . l:client_name)
    else
        let l:client_name = s:GetClientName()
        call s:Debug("DBG path:" . a:filepath . " use default client_name:" . l:client_name)
    endif
    return s:PerforceSystemWithClient(a:cmd, l:client_name, l:env)
endfunction

"  Perforce system functions
" Return result of calling p4 command
function! s:PerforceSystem(cmd, ...)
    let l:env = ''
    if a:0 > 0 && type(a:1) == type({}) && !empty(a:1)
        let l:env_dict = a:1
        let l:env = join(map(keys(l:env_dict), {_, k -> k . '=' . shellescape(l:env_dict[k])}), ' ') . ' '
    endif
    let l:p4cmd = l:env . g:vp4_perforce_executable . " " . a:cmd
	" Remove error output redirection to see actual error messages
	if has('win64') || has('win32')
		" Keep stderr visible on Windows
		let l:p4cmd .= ""
	else
		let prev = &shell
		set shell=sh
		" Remove 2> /dev/null to see stderr
		let l:p4cmd .= ""
	endif
    call s:Debug("DBG sys: " . l:p4cmd)
    let retval = system(l:p4cmd)
	if ! has('win64') && ! has('win32')
		let &shell=prev
	endif
    call s:Debug("DBG sys: " . l:p4cmd . " out:" . retval)
    return retval
endfunction

" Append results of p4 command to current buffer
function! s:PerforceRead(cmd, ...)
    let _modifiable = &modifiable
    set modifiable
    let command = '$read !' . g:vp4_perforce_executable
    if a:0 > 0
        let l:guessed_client = s:GetClientNameForFile(a:1)
        if strlen(l:guessed_client) > 0
            let command .= " -c " . l:guessed_client
        endif
    endif
    let command .= " " . a:cmd
    call s:Debug("DBG read: " . command)
    " Populate the window and get rid of the extra line at the top
    execute command
    1
    execute 'normal! dd'
    let &modifiable=_modifiable
endfunction

" Use current buffer as stdin to p4 command
function! s:PerforceWrite(cmd)
    let command = 'write !' . g:vp4_perforce_executable . " " . a:cmd
    call s:Debug("DBG write: " . command)
    execute command
endfunction

" Function to get the path of the file
function! s:ExpandPath(file)
    if exists("g:vp4_base_path_replacements")
        call s:Debug("We have a base path replacements")
        let l:oldPath = expand('%:p')
        let l:replacements = items(g:vp4_base_path_replacements)
        for item in l:replacements
            call s:Debug("does " . l:oldPath . " match " . item[0])
            if l:oldPath =~ item[0]
                " We have a match
                call s:Debug("Matched string " . item[0] . " in " . l:oldPath)
                let l:newFile = substitute(l:oldPath, item[0], item[1], "")
                call s:Debug("New path " . l:newFile)
                return l:newFile
            endif
        endfor
        call s:Debug("Did not find replacement, return")
    else
        call s:Debug("Using default pathing")
    endif
    return expand(a:file)
endfunction
"

"  Perforce checker infrastructure
" Returns the value of a fstat field
    " Throws an error if it failed.  It is up to the *caller* to catch the error
    " and issue an appropriate message.
function! s:PerforceFstat(field, filename)
    " NB: for some reason fstat was designed not to return an error code if
    "   1. no such file
    "   2. no such revision
    "   3. not shelved in changelist
    " It always starts a valid line with '...'; use it to validate response.
    " It does return -1 if an invalid field was requested.
    let val = s:PerforceSystemWithFile('-ztag -F%' . a:field . '% fstat ' . a:filename, a:filename)
    let val = trim(val)
    if v:shell_error == 0 && val != ''
        call s:Debug('fstat got value ' . val . ' for field ' . a:field
                    \ . ' on file ' . a:filename)
        return val
    endif

    if val == ''
        throw 'PerforceFstatError'
    endif
    if matchstr(val, 'P4PASSWD') != ''
        call s:EchoError(split(val, '\n')[0])
        return 0
    endif
endfunction

" Assert fstat field
function! s:PerforceAssert(field, filename, msg)
    try
        let file = s:PerforceStripRevision(a:filename)
        let retval = s:PerforceFstat(a:field, file)
    catch /PerforceFstatError/
        call s:EchoError(a:msg)
        return 0
    endtry
    return retval
endfunction

" Query fstat field
function! s:PerforceQuery(field, filename)
    try
        let retval = s:PerforceFstat(a:field, a:filename)
    catch /PerforceFstatError/
        return 0
    endtry
    return retval
endfunction
"

"  Perforce field checkers

" Tests for existence in depot.  Issues error message upon failure.
    " Can be used to test existence of a specific revision, or shelved in a
    " particular changelist by adding revision specifier to filename.
    "
    " Abbreviated summary:
    "   #n    - revision 'n'
    "   #have - have revision
    "   @=n   - at changelist 'n' (shelved)
function! s:PerforceAssertExists(filename)
    let msg = a:filename . ' does not exist on the server'
    return s:PerforceAssert('headRev', a:filename, msg) != ''
endfunction

" Tests for opened.  Issues error message upon failure.
function! s:PerforceAssertOpened(filename)
    let msg = a:filename . ' not opened for change'
    return  s:PerforceAssert('action', a:filename, msg) != ''
endfunction

" Tests for opened.
function! s:PerforceExists(filename)
    return s:PerforceQuery('headRev', a:filename) != ''
endfunction

" Tests for whether a given path is a directory in perforce
" given either a local path or a server path
function! s:PerforceGetDirectory(filepath)
    let filepath = a:filepath

    " p4 commands do not expect trailing '/'
    if strpart(filepath, strlen(filepath) - 1, 1) == '/'
        let filepath = strpart(filepath, 0, strlen(filepath) - 1)
    endif

    " get server path
    if filepath[0:1] == '//'
        " given server path
        let perforce_filepath = filepath
    else
        " given local path
        let perforce_filepath = filepath
        let command = 'where ' . filepath
        " NB: `p4 where` only works on directories below the root
        "     e.g. `p4 where //main` will fail if 'main' is the root
        let retval = s:PerforceSystem(command)
        if v:shell_error || strlen(retval) == 0
            return ''
        endif
        let perforce_filepath = split(retval)[0]
    endif

    " verify server path
    " TODO potentially use parent directory as input if given file
    let command = 'dirs ' . perforce_filepath
    let retval = s:PerforceSystem(command)
    let retval = trim(retval)
    if v:shell_error || (retval != perforce_filepath)
        return ''
    endif

    return perforce_filepath
endfunction

" Tests for opened.
function! s:PerforceOpened(filename)
    return s:PerforceQuery('action', a:filename) != ''
endfunction

" Return changelist that given file is open in
function! s:PerforceGetCurrentChangelist(filename)
    return s:PerforceQuery('change', a:filename)
endfunction

" Return have revision number
function! s:PerforceHaveRevision(filename)
    return s:PerforceQuery('haveRev', a:filename)
endfunction
"

"  Perforce revision specification helpers
" Return filename with any revision specifier stripped
function! s:PerforceStripRevision(filename)
    " Handle empty filename to avoid list index out of range error
    if a:filename == ''
        return ''
    endif
    return split(a:filename, '#')[0]
endfunction

" Return filename with appended revision specifier
"
" Priority list:
"   1. Embedded revision specifier in filename
"   2. Synced revision
"   3. Head revision (no specifier required)
function! s:PerforceAddRevision(filename)
    " embedded revision
    let embedded_rev = matchstr(a:filename, '#\zs[0-9]\+\ze')
    if embedded_rev != ''
        return a:filename
    endif

    " have revision
    let have_revision = s:PerforceHaveRevision(a:filename)
    if have_revision
        return a:filename . '#' . have_revision
    endif

    " no specifier
    return a:filename
endfunction

" Return filename with appended 'have revision - 1' specifier
    " If editing a file with the revision aleady embedded in the name, return
    " the revision before that instead.
function! s:PerforceAddPrevRevision(filename)
    let embedded_rev = matchstr(a:filename, '#\zs[0-9]\+\ze')
    if embedded_rev != ''
        let prev_rev = embedded_rev - 1
        return substitute(a:filename, embedded_rev, prev_rev, "")
    else
        let prev_rev = s:PerforceHaveRevision(a:filename) - 1
        return a:filename . '#' . prev_rev
    endif
endfunction

" Get the pending changelists of the current user and prompt the user to
" choose one
function! s:PerforcePromptChangelist(prompt, with_default, ...)
    " Get the pending changes in the current client
    let command = "-Ztag -Mj changes -u $USER -s pending -l -c ". s:GetClientName()

    let changes = []
    for line in split(s:PerforceSystem(command), '\n')
        let change = json_decode(line)
        if a:0 > 0 && index(a:000, change['change']) >= 0
            continue
        endif
        let change['desc'] = trim(change['desc'])
        let change['time'] = strftime("[%Y/%m/%d %T]", change['time'])
        call add(changes, change)
    endfor
    if len(changes) > 0
        if len(changes) == 1
            return changes[0]["change"]
        endif
        " Prepend with choice numbers, starting at 1
        call map(changes, 'v:key + 1 . ". " . v:val["change"] . " " . v:val["time"] . " " . v:val["desc"]')

        if a:with_default
            call add(changes, len(changes) + 1 . '. default')
        endif

        " Prompt the user
        echom a:prompt
        let change = inputlist(changes)

        call s:Debug("select input is [" . change . "]")

        " From the user's input, get the actual changelist number
        if !change | return "" | endif
        let change_number = split(changes[change - 1], ' ')[1]
        return change_number
    elseif a:with_default
        return 'default'
    else
        echom "No pending changelist found"
    endif
endfunction
"
"

"  Main functions

"  System
function! vp4#PerforceSystemWr(...)
    let cmd = join(map(copy(a:000), 'expand(v:val)'))

    " open a preview window
    pedit __vp4_scratch__
    wincmd P

    " call p4 describe
    normal! ggdG
    silent call s:PerforceRead(cmd)
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile nowrap

    " return to original windown
    wincmd p
endfunction
"

"  File editing
" Call p4 add.
function! vp4#PerforceAdd()
    let l:filename = s:ExpandPath('%')

    try
        let retval = s:PerforceFstat('headRev', l:filename)
        call s:EchoError(l:filename . ' already exists on the server: ' . retval)
        return
    catch /PerforceFstatError/
    endtry

    let l:changelist = s:PerforcePromptChangelist("Select a changelist to add " . l:filename, 1)
    call s:Debug("chose changelist " . l:changelist)
    if l:changelist != ''
        call s:PerforceSystemWithFile('add -c ' . l:changelist . ' ' . l:filename, l:filename)
    endif
endfunction

" Call p4 delete.
function! vp4#PerforceDelete(bang)
    let filename = s:ExpandPath('%')
    if !s:PerforceAssertExists(filename) | return | endif

    if !a:bang
        let do_delete = input('Are you sure you want to delete ' . filename
                \ . '? [y/n]: ')
    endif

    if a:bang || do_delete ==? 'y'
        let l:changelist = s:PerforcePromptChangelist("Select a changelist to delete " . filename, 1)
        call s:Debug("chose changelist " . l:changelist)
        if l:changelist == ''
            return
        endif
        call s:PerforceSystemWithFile('delete -c ' . l:changelist . ' ' . filename, filename)
        bdelete
    endif

endfunction

" Call p4 edit.
function! vp4#PerforceEdit(...)
    let filename = s:ExpandPath('%')
    if a:0 >= 2
        let filename = a:2
    endif
    if !s:PerforceAssertExists(filename) | return | endif
    let cl = s:PerforceGetCurrentChangelist(filename)
    let action = s:PerforceQuery('action', filename)
    if cl != 0 && action != 'integrate' && action != 'branch' && action != 'move/add'
        echom filename . ' is already opened in changelist "' . cl . '"'
        if &readonly
            setlocal noreadonly
        endif
        if !&modifiable
            setlocal modifiable
        endif
        return
    endif

    let l:changelist = ''
    if a:0 >= 1
        let l:changelist = a:1
    elseif cl != 0
        " Already opened for integrate/branch/move/add: reopen as edit in same CL
        echom 'Reopening ' . filename . ' as edit in changelist "' . cl . '"'
        let l:changelist = cl
    else
        let changelist = s:PerforcePromptChangelist("Select a changelist to open " . filename, 1)
        call s:Debug("chose changelist " . changelist)
    endif

    if l:changelist == ''
        call s:Debug("empty changelist")
        return
    endif

    let result = s:PerforceSystemWithFile('edit -c ' . l:changelist . ' ' . filename, filename)
    if result['exit_code'] == 0
        let saved_curpos = getcurpos()
        " After p4 edit, the file is writable in filesystem
        " Update vim's buffer state before reloading
        setlocal noreadonly
        setlocal modifiable
        " Save if there are unsaved changes
        if &modified
            write
        endif
        " Reload the file to ensure consistent state
        execute 'edit! ' . filename
        call setpos('.', saved_curpos)
    else
        echow result['output']
    endif
endfunction

function! vp4#PerforceEditFilesInQuickFixList()
    let l:unopened_files = []
    let l:integrate_files = []  " [filename, cl] pairs for integrate/branch/move/add

    let l:qflist = getqflist()
    let l:files = l:qflist->map({_,val -> fnamemodify(bufname(val.bufnr), ':p')})->sort()->uniq()
    call s:Debug(len(getqflist()) . ' items and ' . len(l:files) .
               \' unique files in quickfix list')

    for filename in l:files
        if !s:PerforceAssertExists(filename) | continue | endif
        let cl     = s:PerforceGetCurrentChangelist(filename)
        let action = s:PerforceQuery('action', filename)
        call s:Debug(filename . ' got "' . cl . '" action "' . action . '"')
        if cl != 0 && action != 'integrate' && action != 'branch' && action != 'move/add'
            call s:Debug(filename . ' is already opened in changelist "' . cl . '"')
            continue
        endif
        if cl != 0
            let l:integrate_files += [[filename, cl]]
        else
            let l:unopened_files += [filename]
        endif
    endfor

    " Reopen integrate/branch/move/add files as edit in their current CL
    for [l:fname, l:fcl] in l:integrate_files
        let result = s:PerforceSystemWithFile('edit -c ' . l:fcl . ' ' . l:fname, l:fname)
        if result['exit_code'] != 0
            echow result['output']
        endif
    endfor

    if len(l:unopened_files) == 0
        return
    endif

    call s:Debug('unopened files"' . l:unopened_files . '"')

    let changelist = s:PerforcePromptChangelist("Select a changelist to open the files", 1)
    call s:Debug("chose changelist " . changelist)

    if changelist != ''
        " Since files may be from different clients, we need to group them by client
        " and edit each group separately
        let l:by_client = {}
        for filename in l:unopened_files
            let l:ws = s:GetClientNameForFile(filename)
            if l:ws == ''
                let l:ws = s:GetClientName()
            endif
            if !has_key(l:by_client, l:ws)
                let l:by_client[l:ws] = []
            endif
            call add(l:by_client[l:ws], filename)
        endfor

        for [l:ws, l:files] in items(l:by_client)
            let l:files_str = join(l:files, ' ')
            let result = s:PerforceSystemWithClient('edit -c ' . changelist . ' ' . l:files_str, l:ws)
            if result['exit_code'] != 0
                echow result['output']
            endif
        endfor
    endif
endfunction

" Call p4 revert.  Confirms before performing the revert.
function! vp4#PerforceRevert(bang)
    let filename = s:ExpandPath('%')
    if !s:PerforceAssertOpened(filename) | return | endif

    let action = s:PerforceQuery('action', filename)

    if !a:bang
        let do_revert = input('Are you sure you want to revert ' . filename
                \ . '? [y/n]: ')
    endif

    if a:bang || do_revert ==? 'y'
        call s:PerforceSystemWithFile('revert ' .filename, s:ExpandPath("%:p"))

        if action == 'add'
            execute 'edit ' filename
            setlocal modifiable
            setlocal noreadonly
        else
            setlocal nomodifiable
            setlocal nomodified
            setlocal readonly

            " reload the file to refresh &readonly attribute
            execute 'edit ' filename
            setlocal nomodifiable
            setlocal readonly
        endif
    endif
endfunction
"

"  Change specification
" Call p4 shelve
function! vp4#PerforceShelve(bang)
    let filename = s:ExpandPath('%')
    if !s:PerforceAssertOpened(filename) | return | endif

    let perforce_command = 'shelve'
    let cl = s:PerforceGetCurrentChangelist(filename)

    if cl !~# 'default'
        let perforce_command .= ' -c ' . cl
        if a:bang | let perforce_command .= ' -f' | endif
        let msg = split(s:PerforceSystemWithFile(perforce_command . ' ' . filename, filename), '\n')
        if v:shell_error | call s:EchoError(msg[-1]) | endif
        let msg = filename . ' shelved in p4:' . cl
        echom msg
    else
        call s:EchoError('Files open in the default changelist'
                \ . ' may not be shelved.  Create a changelist first.')
    endif

endfunction

" Use contents of buffer to send a change specification
function! s:PerforceWriteChange()
    silent call s:PerforceWrite('change -i')

    " If the change was made successfully, mark the file as no longer modified
    " (so that Vim doesn't warn user that a file has been modified but not
    " written on exit) and close the window.
    "
    " Note: leaves an open buffer.  Unloading a buffer in an autocommand issues
    " an error message, so this buffer has been intentionally left open by the
    " author.
    if !v:shell_error
        set nomodified
        close
    endif
endfunction

" Call p4 change
    " Uses the -o/-i options to avoid the confirmation on abort.
    " Works by opening a new window to write your change description.
function! vp4#PerforceChange()
    let filename = s:ExpandPath('%')
    let perforce_command = 'change -o'
    let lnr = 25

    " If this file is already in a changelist, allow the user to modify that
    " changelist by calling `p4 change -o <cl#>`.  Otherwise, call for default
    " changelist by omitting the changelist argument.
    if s:PerforceOpened(filename)
        let changelist = s:PerforceGetCurrentChangelist(filename)
        if changelist
            let perforce_command .= ' ' . changelist
            let lnr = 27
        endif
    endif

    " Open a new split to hold the change specification.  Clear it in case of
    " any previous invocations.
    topleft new __vp4_change__
    normal! ggdG

    silent call s:PerforceRead(perforce_command)

    " Reset the 'modified' option so that only user modifications are captured
    set nomodified

    " Put cursor on the line where users write the changelist description.
    execute lnr

    " Replace write command (:w) with call to write change specification.
    " Prevents the buffer __vp4_change__ from being written to disk
    augroup WriteChange
        autocmd! * <buffer>
        autocmd BufWriteCmd <buffer> call <SID>PerforceWriteChange()
    augroup END
endfunction

" Call `p4 describe` on the changelist of the current file, if any.  Show the
" output in a preview window.
function! vp4#PerforceDescribe()

    let filename = s:ExpandPath('%')
    let current_changelist = s:PerforceGetCurrentChangelist(filename)

    if !current_changelist
        call s:EchoWarning(filename . ' is not open in a named changelist')
        return
    endif

    " open a preview window
    pedit __vp4_describe__
    wincmd P

    " call p4 describe
    normal! ggdG
    let perforce_command = "describe " . current_changelist
    silent call s:PerforceRead(perforce_command)
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile nowrap

    " return to original windown
    wincmd p
endfunction

" Prompt the user to move file currently being edited to a different changelist.
    " Present the user with a list of current changes.
function! vp4#PerforceReopen()
    let filename = s:ExpandPath('%')
    if !s:PerforceAssertOpened(filename) | return | endif

    " Prompt the user
    let currentchangelist = s:PerforceGetCurrentChangelist(filename)

    let changelist = s:PerforcePromptChangelist(filename .
        \ ' is currently open in change "' . currentchangelist
        \ . '". Select a changelist to move to: ',
        \ currentchangelist != "default", currentchangelist)

    if changelist != ''
        echom 'Moving ' . filename . ' to change ' . changelist
        " Perform the reopen command
        let perforce_command = 'reopen -c ' . changelist . ' ' . filename
        silent call s:PerforceSystemWithFile(perforce_command, filename) | redraw!
    endif
endfunction
"

"  Analysis
" Open repository revision in diff mode
    "  Options:
    "  s       diffs with shelved in file's current changelist
    "  @cl     diffs with shelved in given changelist
    "  p       diffs with previous revision (i.e. have revision - 1)
    "  #rev    diffs with given revision
    "  <none>  diffs with have revision
function! vp4#PerforceDiff(...)
    let local_file = s:ExpandPath('%:p')
    let filename = s:ExpandPath('%')

    " Check for options
    "   'a:0' is set to the number of extra arguments
    "   a:1 is the first extra argument, a:2 the second, etc.
    " @cl: Diff with shelved in a:1
    if a:0 >= 1 && a:1[0] == '@'
        let cl = split(a:1, '@')[0]
        let filename .= '@=' . trim(cl)
    " #rev: Diff with revision a:1
    elseif a:0 >= 1 && a:1[0] == '#'
        let filename = s:PerforceStripRevision(filename) . trim(a:1)
    " s: Diff with shelved in current changelist
    elseif a:0 >= 1 && a:1 =~? 's'
        let filename .= '@=' . s:PerforceGetCurrentChangelist(filename)
    " p: Diff with previous version
    elseif a:0 >= 1 && a:1 =~? 'p'
        let filename = s:PerforceAddPrevRevision(filename)
    " default: diff with have revision
    else
        if !s:PerforceAssertOpened(filename) | return | endif
        let filename .= '#have'
    endif

    " Assert valid revision
    if !s:PerforceAssertExists(filename) | return | endif

    " Setup current window
    let filetype = &filetype
    diffthis

    " Create the new window and populate it
    " Use noautocmd to prevent BufReadCmd (Vp4Enter) from firing on depot
    " paths like //depot/...#have, which would call CheckServerPath, set
    " nomodifiable, and cause E21 when ggdG tries to clear the buffer.
    noautocmd execute 'leftabove vnew ' . fnameescape(filename)
    normal! ggdG
    let perforce_command = 'print'
    if g:vp4_diff_suppress_header
        let perforce_command .= ' -q'
    endif
    let perforce_command .= ' ' . shellescape(filename, 1)
    silent call s:PerforceRead(perforce_command, local_file)

    " Set local buffer options
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile nowrap
    setlocal nomodifiable
    setlocal nomodified
    execute "set filetype=" . filetype
    diffthis
    nnoremap <buffer> <silent> q :<C-U>bdelete<CR> :windo diffoff<CR>

    " Jump back to the original window and move to the first diff hunk
    wincmd p
    normal! gg]c
endfunction

" Syntax highlighting for annotation data
function! s:PerforceAnnotateHighlight()
    syn match VP4Change /\v\d+$/
    syn match VP4Date /\v\d{4}\/\d{2}\/\d{2}/
    syn match VP4Time /\v\d{2}:\d{2}:\d{2}( [A-Z]{3})?/

    hi def link VP4Change Number
    hi def link VP4Date Comment
    hi def link VP4Time Comment
    hi def link VP4User Keyword
endfunction

" Populate change metadata, namely: user, date, description.  Assumes buffer
    " contains one changelist number per line.
function! s:PerforceAnnotateFull(lbegin, lend)
    let data = {}
    let last_cl = 0

    set modifiable
    let lnr = a:lbegin
    while lnr && lnr <= a:lend
        let line = getline(lnr)

        " Only query the changelist information from perforce if we have not
        " seen this change before.  While this could take up significant amounts
        " of memory for a large file, it should still be much faster than
        " additional calls to `p4 change`
        if !has_key(data, line)
            let data[line] = {}
            let cl_data = split(s:PerforceSystemWithFile('change -o ' . line), '\n')

            try
                let description_index = match(cl_data, '^Description')
                let data[line]['description'] = substitute(join(cl_data[description_index + 1:-1]),
                        \ "\t", "", "g")

                " Format: 'Date:\t<date> <time>'
                let date_index = match(cl_data, '^Date')
                let date = split(split(cl_data[date_index], '\t')[1], ' ')[0]
                let data[line]['date'] = date

                let user_index = match(cl_data, '^User')
                let user = split(cl_data[user_index], '\t')[1]
                let data[line]['user'] = s:PrePad(user, 8)

                " [Hack] Conveniently use the fact that we have the user name
                " now to identify it as a keyword for highlighting later.
                execute " syn keyword VP4User " . data[line]['user']
            catch
                echom 'failed to get data for change ' . line
                call s:Debug(join(cl_data))
                continue
            endtry
        endif

        " Small state machine to display the description for the current
        " changelist.  First line shows the date and user, subsequent lines show
        " the continue description, if it exceeds one line.
        let LEN = 70
        if line != last_cl
            let idx = 0
            call setline(lnr, ' '
                    \ . ' ' . data[line]['date']
                    \ . ' ' . data[line]['user']
                    \ . ' ' . line
                    \ )
        else
            let description = strpart(data[line]['description'], idx, LEN)
            call setline(lnr, s:Pad(description, LEN)
                    \ . ' ' .line
                    \ )
            let idx += LEN
        endif

        let last_cl = line
        let lnr = nextnonblank(lnr + 1)
    endwhile

    set nomodifiable
endfunction

" Open a scrollbound split containing on each line the changelist number in
    " which it was last edited.  Accepts a range to limit the section being
    " fully annotated.
function! vp4#PerforceAnnotate(...) range
    let filename = s:ExpandPath('%:p')
    if !s:PerforceAssertExists(filename) | return | endif

    " `p4 annotate` can only operate on revisions that exist in the depot.  If a
    " file is open for edit, only the annotations for the #have revision can be
    " given.  Issue a warning of the user tries to do this.
    if s:PerforceOpened(filename)
        call s:EchoWarning(filename
                \ . ' is open for edit, annotations will likely be misaligned')
    endif

    " Use revision specific perforce commands
    let filename = s:PerforceAddRevision(filename)

    " Save the cursor position and buffer number
    let saved_curpos = getcurpos()
    let saved_bufnr = bufnr(bufname("%"))

    " Open a split and perform p4 annotate command
    silent leftabove vnew Vp4Annotate
    let perforce_command = 'annotate -q'
    if !g:vp4_annotate_revision
        let perforce_command .= ' -c'
    endif
    let perforce_command .= ' ' . shellescape(filename, 1) . '| cut -d: -f1'
    call s:PerforceRead(perforce_command)

    " Perform full annotation
    if !(a:0 > 0 && a:1 == 'q') && !g:vp4_annotate_revision
        call s:PerforceAnnotateFull(a:firstline, a:lastline)
    endif

    " Clean up buffer, set local options, move cursor to saved position
    set modifiable
    %right 80
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile nowrap
    setlocal nonumber norelativenumber
    call s:PerforceAnnotateHighlight()
    call setpos('.', saved_curpos)
    set cursorbind scrollbind
    vertical resize 80
    set nomodifiable

    " q to exit
    nnoremap <buffer> <silent> q :<C-U>bdelete<CR>
            \ :windo set noscrollbind nocursorbind<CR>

    " Go back to original buffer
    execute bufwinnr(saved_bufnr) . "wincmd w"
    set cursorbind scrollbind
    syncbind
endfunction

" Map a local (modified) line number to the corresponding #have line number
" using the unified diff output from `p4 diff -du`.
" Returns -1 if the local line is a new addition not present in #have.
function! s:MapLocalLineToHave(diff_lines, lnum)
    let old_line = 1
    let new_line = 1
    let in_hunk = 0
    for l in a:diff_lines
        if l =~# '^@@ '
            let m = matchlist(l, '^@@ -\(\d\+\)\(,\d\+\)\? +\(\d\+\)\(,\d\+\)\? @@')
            if empty(m) | continue | endif
            let hunk_old = str2nr(m[1])
            let hunk_new = str2nr(m[3])
            call s:Debug('DBG MapLine hunk: ' . l . ' old=' . old_line . ' new=' . new_line)
            if a:lnum < hunk_new
                let result = old_line + (a:lnum - new_line)
                call s:Debug('DBG MapLine lnum=' . a:lnum . ' < hunk_new=' . hunk_new . ' => depot=' . result)
                return result
            endif
            let old_line = hunk_old
            let new_line = hunk_new
            let in_hunk = 1
        elseif !in_hunk
            continue
        elseif l[0:0] ==# ' '
            if new_line == a:lnum
                call s:Debug('DBG MapLine lnum=' . a:lnum . ' on context line => depot=' . old_line)
                return old_line
            endif
            let old_line += 1
            let new_line += 1
        elseif l[0:0] ==# '-'
            let old_line += 1
        elseif l[0:0] ==# '+'
            if new_line == a:lnum
                call s:Debug('DBG MapLine lnum=' . a:lnum . ' is local addition => -1')
                return -1
            endif
            let new_line += 1
        endif
    endfor
    let result = old_line + (a:lnum - new_line)
    call s:Debug('DBG MapLine lnum=' . a:lnum . ' after all hunks: old=' . old_line . ' new=' . new_line . ' => depot=' . result)
    return result
endfunction

function! vp4#PerforceAnnotateLine()
    let filename = s:PerforceStripRevision(s:ExpandPath('%:p'))
    if !s:PerforceAssertExists(filename) | return | endif

    let client_name = s:GetClientNameForFile(filename)
    let lnum = line(".")
    let have_lnum = lnum

    " If the file is writable (opened for edit), map local line number to
    " #have line number via diff, since p4 annotate operates on depot version.
    if filewritable(filename)
        let diff_out = s:PerforceSystemWithClient(
            \ 'diff -du ' . shellescape(filename, 0), client_name, {'P4DIFF': ''})
        call s:Debug('DBG AnnotateLine diff hunks: ' . join(filter(split(diff_out, "\n"), 'v:val =~# "^@@"'), ' | '))
        if !v:shell_error && diff_out =~# '@@'
            let have_lnum = s:MapLocalLineToHave(split(diff_out, "\n"), lnum)
        endif
        if have_lnum < 0
            call s:EchoWarning('vp4 AnnotateLine: line ' . lnum
                \ . ' is a local addition, not in #have')
            return
        endif
    endif

    " annotate -cq at #have: p4 annotate on a local path defaults to HEAD,
    " not #have, so line numbers won't match the file on disk without #have.
    let ann_flags = g:vp4_annotate_ignore_whitespace ? '-cq -db' : '-cq'
    let ann_cmd = 'annotate ' . ann_flags . ' ' . shellescape(filename . '#have', 0)
                \ . ' | sed -n "' . have_lnum . 'p" | cut -d: -f1'
    let cl = trim(s:PerforceSystemWithClient(ann_cmd, client_name))

    if empty(cl) || cl !~# '^\d\+$'
        call s:EchoError('vp4 AnnotateLine: no annotation for line ' . lnum)
        return
    endif

    " If this CL is a branch/integrate action, follow the integration chain
    " to surface the developer's original edit (annotate -I traces one hop).
    let flog = s:PerforceSystemWithClient(
        \ 'filelog -m 30 ' . shellescape(filename, 0), client_name)
    if !v:shell_error && !empty(flog)
        let action = matchstr(flog, 'change\s\+' . cl . '\s\+\zs\w\+')
        if action ==# 'branch' || action ==# 'integrate'
            let icmd = 'annotate -cIq' . (g:vp4_annotate_ignore_whitespace ? ' -db' : '') . ' '
                     \ . shellescape(filename . '#have', 0)
                     \ . ' | sed -n "' . have_lnum . 'p" | cut -d: -f1'
            let icl = trim(s:PerforceSystemWithClient(icmd, client_name))
            if !empty(icl) && icl =~# '^\d\+$'
                let cl = icl
            endif
        endif
    endif

    let desc_fmt = '-Ztag -F "%change% %user% %time% %desc%" describe -s -m1 '
    let output = trim(s:PerforceSystemWithClient(desc_fmt . cl, client_name))
    if v:shell_error || empty(output)
        call s:EchoError('vp4 AnnotateLine: could not describe CL ' . cl)
        return
    endif

    let fields = split(output, ' ')
    if len(fields) < 4 | return | endif
    let ts = strftime("[%Y/%m/%d %T]", fields[2])
    let desc = join(fields[3:], ' ')

    let entries = [{'filename': filename, 'lnum': lnum,
        \ 'text': fields[0] . ' ' . ts . ' ' . fields[1] . ' ' . desc}]
    call setloclist(0, entries)
    if g:vp4_open_loclist
        lopen
    endif
endfunction

" Populate the quick-fix or location list with the past revisions of this file.
    " Only lists the files and some changelist data. The file is not retrieved
    " until the user opens it.
function! vp4#PerforceFilelog(...)
    let filename = s:PerforceStripRevision(s:ExpandPath('%:p'))
    if !s:PerforceAssertExists(filename) | return | endif

    " Remember some stuff about this file
    let g:_vp4_filetype = &filetype
    let g:_vp4_curpos = getcurpos()

    " Set up the command.  Limit the maximum number of entries.
    let command = '-Mj -Ztag filelog -il ' . filename

    " Compile all the location list data
    let retval = s:PerforceSystemWithFile(command, filename)
    if v:shell_error
        echom filename . ' ' . retval
        return
    endif

    if strlen(retval) == 0
        return
    endif

    let data = []
    let g:_vp4_filelog_data = []
    for line in split(retval, '\n')
        let dict = json_decode(line)
        let depotFile = dict["depotFile"]
        let i = 0
        while i < 1000000
            let action = 'action' . i
            if !has_key(dict, action)
                break
            endif
            let user = dict['user' . i]
            let change = dict['change' . i]
            let desc = trim(dict['desc' . i])
            let client = dict['client' . i]
            let time = strftime("[%Y/%m/%d %T]", dict['time' . i])
            let rev = dict['rev' . i]
            " Set up dictionary entry
            let entry = {}
            let full_filename = depotFile . '#' . rev
            let entry['filename'] = full_filename
            let entry['lnum'] = g:_vp4_curpos[1]
            let entry['text'] = printf("%s %s %s %s %s", change, dict[action], time, user, desc)
            " Add it to the list
            call add(data, entry)
            " Also save the filename separately for later retrieval
            call add(g:_vp4_filelog_data, full_filename)
            let i += 1
        endwhile
    endfor

    " Populate the location list
    call setloclist(0, data)

    " Automatically open quick-fix or location list
    if g:vp4_open_loclist
        " Save the window that has the location list
        let g:_vp4_loclist_winnr = winnr()
        lopen
        " Add key mapping for showing diff in location list window
        nnoremap <buffer> <silent> d :<C-U>call <SID>PerforceFilelogShowDiff()<CR>
    endif

    " Set auto command for opening specific revisions of files
    augroup OpenRevision
        autocmd!
        autocmd BufEnter *#* call <SID>PerforceOpenRevision()
    augroup END
endfunction

" Show the diff for a specific revision against its previous revision
" Can be called from location list populated by Vp4Filelog
" Optional argument: line number in the location list (1-based)
function! vp4#PerforceFilelogDiff(...)
    " Get the current location list entry
    let loclist = getloclist(0)
    if empty(loclist)
        call s:EchoError('No location list available')
        return
    endif

    " Determine which item to show
    let current_idx = -1
    if a:0 > 0
        " Use the provided index (0-based)
        let current_idx = a:1
    else
        " Get the current location list item index
        let loc_info = getloclist(0, {'idx': 0})
        if !has_key(loc_info, 'idx') || loc_info.idx == 0
            call s:EchoError('No item selected in location list')
            return
        endif
        let current_idx = loc_info.idx - 1
    endif

    " The filename with revision should be stored in g:_vp4_filelog_data
    " as it's not reliably available in the location list entry
    if !exists('g:_vp4_filelog_data') || empty(g:_vp4_filelog_data)
        call s:EchoError('No filelog data available. Please run :Vp4Filelog first')
        return
    endif

    if current_idx < 0 || current_idx >= len(g:_vp4_filelog_data)
        call s:EchoError('Invalid index ' . current_idx . ' (filelog has ' . len(g:_vp4_filelog_data) . ' items)')
        return
    endif

    let filename = g:_vp4_filelog_data[current_idx]

    " Also get the entry for the text field
    if current_idx < len(loclist)
        let entry = loclist[current_idx]
    else
        " Fallback: create a minimal entry
        let entry = {'text': 'Unknown change'}
    endif

    " Debug output
    if g:vp4_debug
        echom 'Using index: ' . current_idx
        echom 'Filename: ' . filename
        if has_key(entry, 'text')
            echom 'Entry text: ' . entry['text']
        endif
    endif

    " Extract the revision number from the filename (format: //depot/path#rev)
    let rev_match = matchstr(filename, '#\zs[0-9]\+\ze$')
    if rev_match == ''
        call s:EchoError('Could not extract revision number from: ' . filename)
        return
    endif

    let rev = str2nr(rev_match)
    if rev <= 1
        call s:EchoWarning('Revision ' . rev . ' has no previous revision to diff against')
        return
    endif

    " Get the base filename without revision
    let base_filename = substitute(filename, '#[0-9]\+$', '', '')
    let prev_filename = base_filename . '#' . (rev - 1)
    let curr_filename = base_filename . '#' . rev

    " Save information about where we came from (for returning later)
    let g:_vp4_diff_return_tabpage = tabpagenr()
    let g:_vp4_diff_return_winnr = winnr()

    " Open a new window to show the diff
    let filetype = &filetype
    if bufname('%') == ''
        " If current buffer is empty, use it
        enew
    else
        " Otherwise create a new split
        tabnew
    endif

    " Make the buffer modifiable before calling append()
    setlocal modifiable

    " Add a helpful header first
    call append(0, ['# Perforce Diff for ' . base_filename,
                \ '# Comparing revision #' . (rev - 1) . ' -> #' . rev,
                \ '# Change: ' . entry['text'],
                \ ''])

    " Get the diff output using p4 diff2
    let perforce_command = 'diff2 -du ' . shellescape(prev_filename, 1)
                \ . ' ' . shellescape(curr_filename, 1)

    silent call s:PerforceRead(perforce_command)

    " Set buffer options
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
    setlocal filetype=diff
    setlocal nomodifiable

    " Map q to close and return to location list
    nnoremap <buffer> <silent> q :<C-U>call <SID>PerforceFilelogDiffClose()<CR>
endfunction

" Close the diff window and return to location list
function! s:PerforceFilelogDiffClose()
    " Close current buffer (diff window)
    bdelete

    " Try to return to the saved tab and window
    if exists('g:_vp4_diff_return_tabpage') && exists('g:_vp4_diff_return_winnr')
        " Go to the saved tab page
        if tabpagenr() != g:_vp4_diff_return_tabpage
            execute 'tabnext ' . g:_vp4_diff_return_tabpage
        endif

        " Go to the saved window (which should be the location list or the source window)
        if winnr() != g:_vp4_diff_return_winnr
            execute g:_vp4_diff_return_winnr . 'wincmd w'
        endif

        " Now find the location list window in this tab
        for winnr in range(1, winnr('$'))
            if getwinvar(winnr, '&buftype') == 'quickfix'
                " Check if it's a location list (not quickfix)
                let wininfo = getwininfo(win_getid(winnr))
                if !empty(wininfo) && wininfo[0].loclist
                    execute winnr . 'wincmd w'
                    return
                endif
            endif
        endfor
    endif

    " If we couldn't find the location list, just stay where we are
endfunction

" Show the diff for current file revision from location list
function! s:PerforceFilelogShowDiff()
    " When in location list window, get the current index
    " The line() function gives us the line number, which should match the location list index
    let loclist = getloclist(0)
    let current_line = line('.')

    " The location list index is the line number
    " But we need to find the corresponding index in g:_vp4_filelog_data
    let selected_idx = current_line - 1

    if g:vp4_debug
        echom 'Location list line: ' . current_line . ', index: ' . selected_idx
        echom 'Total items in filelog_data: ' . len(g:_vp4_filelog_data)
    endif

    " The location list window shows items from the previous window
    " We need to go back to get the actual location list data

    " Try to go to the window that has the location list
    if exists('g:_vp4_loclist_winnr') && winbufnr(g:_vp4_loclist_winnr) != -1
        execute g:_vp4_loclist_winnr . 'wincmd w'
    else
        " Fallback: go to the previous window
        wincmd p
    endif

    " Now call the diff function with the selected index (0-based)
    call vp4#PerforceFilelogDiff(selected_idx)
endfunction
"

"  Passive (called by auto commands)
" Check if file exists in the depot and is not already opened for edit.  If so,
" prompt user to open for edit.
function! vp4#PromptForOpen()
    let filename = s:ExpandPath('%')
    if !g:vp4_prompt_on_write
        return
    endif
    if !&readonly
        return
    endif
    " The file is already opened.
    let l:text = s:PerforceSystemWithFile('-Mj -ztag opened ' . filename, filename)
    if l:text != ''
        call s:Debug(filename . ' is already opened')
        return
    endif
    if s:PerforceAssertExists(filename)
        let do_edit = input(filename .
                \' is not opened for edit.  p4 edit it now? [y/n]: ')
        if do_edit ==? 'y'
            call vp4#PerforceEdit()
        endif
    endif
endfunction

" Expected to be called from opening file populated in quickfix list by
    " Vp4Filelog command.  Works by calling 'p4 print', and the filename already
    " has the revision specifier on the end.
function! s:PerforceOpenRevision()
    " Use buftype as a way to see if we've already gotten this file.
    if &buftype == 'nofile'
        return
    else
        setlocal buftype=nofile
    endif

    let filename = s:ExpandPath('%')
    if !s:PerforceAssertExists(filename) | return | endif

    " Print the file to this buffer
    silent call s:PerforceRead('print -q ' . shellescape(s:ExpandPath('%:p'), 1))
    setlocal nomodifiable

    " Use the information we remembered about the file where Filelog was invoked
    execute 'setlocal filetype=' . g:_vp4_filetype
    execute g:_vp4_curpos[1]

endfunction

" Open the local file if it exists, otherwise print the contents from the
" server.
"   //main/foo.cpp      opens haveRev or headRev
"   //main/foo.cpp#2    opens #2
"   foo.cpp#2           opens #2
"   foo.cpp             does nothing
function! vp4#CheckServerPath(filename)
    " " FIXME
    " " doesn't work on VimEnter
    " " leaves undesired empty buffer
    " let perforce_directory = s:PerforceGetDirectory(a:filename)
    " if (perforce_directory != '')
    "     call vp4#PerforceExplore(a:filename)
    " endif

    " test for existence of depot file
    if !s:PerforceExists(a:filename) | return | endif

    let requested_rev = matchstr(a:filename, '#[0-9]\+')
    let requested_rev = strpart(requested_rev, 1)

    " check for existence of local file
    let have_rev = s:PerforceQuery('haveRev', a:filename)
    let client_file = s:PerforceQuery('clientFile', a:filename)
    if (len(requested_rev) == 0 || have_rev == requested_rev) && filereadable(client_file)
        let old_bufnr = bufnr('%')
        let old_bufname = bufname('%')
        execute 'edit ' . client_file
        let new_bufnr = bufnr('%')
        let new_bufname = bufname('%')

        call s:Debug('old: ' . old_bufnr . ' ' . old_bufname)
        call s:Debug('new: ' . new_bufnr . ' ' . new_bufname)

        execute 'buffer ' . new_bufnr
        execute 'doauto BufRead'
        execute 'bdelete! ' . old_bufname

        return
    endif

    " get the file contents
    let perforce_command = 'print '
    if g:vp4_print_suppress_header
        let perforce_command .= ' -q '
    endif
    let perforce_command .= shellescape(a:filename, 1)
    call s:PerforceRead(perforce_command)

    " get filetype
    execute 'doauto BufRead ' . substitute(a:filename, '#.*', '', '')

    setlocal buftype=nofile
    setlocal nomodifiable

endfunction

"

"  Depot explorer

" Print file contents to temporary buffer for viewing without syncing
function! s:ExplorerPreviewOrOpen()
    if len(getline('.')) == 0 | return | endif

    let filename = split(getline('.'))[0]
    let directory = s:line_map[line(".")]
    let fullpath = directory . filename
    let local_path = s:directory_map[directory] . s:PerforceStripRevision(filename)

    " file
    rightbelow new
    let local_path = s:directory_map[directory] . s:PerforceStripRevision(filename)
    if filereadable(local_path)
        let command  = 'edit ' . local_path
        exe command
    else
        call vp4#CheckServerPath(fullpath)
    endif
endfunction

" Show help for explorer key mappings
function! s:ExplorerHelp()
    echo "Vp4Explore keybindings:\n"
        \ . "  <CR>  toggle directory expand/collapse\n"
        \ . "  s     sync file under cursor (skip if opened for edit)\n"
        \ . "  S     force sync file under cursor (p4 sync -f)\n"
        \ . "  -     go up to parent directory\n"
        \ . "  c     change to directory under cursor\n"
        \ . "  q     quit explorer\n"
        \ . "  ?     show this help"
endfunction

" Batch fstat for all files in a depot directory.
" Returns dict: base_filename -> '' (not have), '*' (have but outdated), '=' (at head)
function! s:ExplorerFstatDir(perforce_dir)
    let result = {}
    let pattern = '"' . a:perforce_dir . '*"'
    let output = s:PerforceSystem('-ztag fstat -T depotFile,haveRev,headRev ' . pattern)

    let depot_file = ''
    let have_rev = -1
    let head_rev = -1

    for line in split(output, '\n') + ['']
        if line == ''
            if depot_file != ''
                let fname = split(depot_file, '/')[-1]
                if have_rev < 0
                    let result[fname] = ''
                elseif have_rev == head_rev
                    let result[fname] = '='
                else
                    let result[fname] = '*'
                endif
            endif
            let depot_file = ''
            let have_rev = -1
            let head_rev = -1
            continue
        endif
        let m = matchlist(line, '\.\.\. depotFile \(.*\)')
        if !empty(m)
            let depot_file = m[1]
            continue
        endif
        let m = matchlist(line, '\.\.\. haveRev \(\d\+\)')
        if !empty(m)
            let have_rev = str2nr(m[1])
            continue
        endif
        let m = matchlist(line, '\.\.\. headRev \(\d\+\)')
        if !empty(m)
            let head_rev = str2nr(m[1])
        endif
    endfor

    return result
endfunction

" Sync file under cursor.  a:force=1 uses 'sync -f', a:force=0 skips if opened.
function! s:ExplorerSync(force)
    if len(getline('.')) == 0 | return | endif

    let filename = split(getline('.'))[0]
    if strpart(filename, strlen(filename) - 1, 1) == '/'
        call s:EchoWarning('Select a file, not a directory')
        return
    endif

    let directory = s:line_map[line('.')]
    let fullpath = s:PerforceStripRevision(directory . filename)

    if !a:force
        let action = s:PerforceQuery('action', fullpath)
        if action != ''
            call s:EchoWarning(fnamemodify(fullpath, ':t') . ' is opened for ' . action . '. Use S to force sync.')
            return
        endif
    endif

    let cmd = 'sync' . (a:force ? ' -f' : '') . ' '
                \ . g:vp4_sync_options . ' ' . shellescape(fullpath)
    let output = s:PerforceSystem(cmd)
    if v:shell_error
        call s:EchoError(output)
        return
    endif
    echo output

    " Refresh file list for this directory
    unlet s:directory_data[directory]['files']
    let saved_curpos = getcurpos()
    call s:ExplorerPopulate(directory)
    call s:ExplorerRender(g:explorer_key)
    call setpos('.', saved_curpos)
endfunction

" Change explorer root to selected directory
function! s:ExplorerChange()
    if len(getline('.')) == 0 | return | endif

    let filename = split(getline('.'))[0]
    if strpart(filename, strlen(filename) - 1, 1) != '/' | return | endif

    let fullpath = s:line_map[line(".")] . filename
    let s:directory_data[fullpath]['folded'] = 0
    call s:ExplorerPopulate(fullpath)
    call s:ExplorerRender(fullpath, 0, s:FilepathHead(fullpath))

    call setpos(".", [0, 2, 0, 0])
endfunction

" If on a directory, toggle expand/collapse.
function! s:ExplorerGoTo()
    if len(getline('.')) == 0 | return | endif

    let filename = split(getline('.'))[0]
    let directory = s:line_map[line(".")]
    let fullpath = directory . filename
    if strpart(filename, strlen(filename) - 1, 1) == '/'
        " directory

        " populate if not populated
        let d = get(s:directory_data, fullpath)
        if !has_key(d, 'files')
            call s:ExplorerPopulate(fullpath)
        else
            " toggle fold/unfold
            let d.folded = !d.folded
        endif

        let saved_curpos = getcurpos()
        call s:ExplorerRender(g:explorer_key)
        call setpos('.', saved_curpos)
    endif
endfunction

" Return head of a:filepath
function! s:FilepathHead(filepath)
    let path = split(a:filepath, '/')
    call remove(path, -1)
    return '//' . join(path, '/') . '/'
endfunction

" Set explorer root node to its parent
function! s:ExplorerPop()
    let path = s:FilepathHead(g:explorer_key)
    if len(split(path, '/')) == 0 | return | endif
    call s:ExplorerPopulate(path)
    let s:directory_data[path]['folded'] = 0
    call s:ExplorerRender(path)
endfunction

" Render the directory data as a tree, using given node as the root.  This node
" should be a directory.
function! s:ExplorerRender(key, ...)
    setlocal modifiable
    let key = a:key
    if strpart(a:key, strlen(a:key) - 1, 1) != '/'
        let key .= '/'
    endif

    " default
    let level = 0
    let root  = s:FilepathHead(key)

    if a:0 > 0
        let level = a:1
        let root  = a:2
    endif
    " Clear screen before rendering
    if level == 0
        let g:explorer_key = key
        silent normal! ggdG
    endif

    " Setup
    let d = get(s:directory_data, key)
    let prefix = repeat(' ', level * 4)

    " Print myself
    call append(line('$'), prefix . d.name)
    let s:line_map[line("$")] = root

    " Print my children
    if !d.folded
        " print directories
        for child in get(d, 'children', [])
            call s:ExplorerRender(child, level + 1, root . d.name)
        endfor

        " print files
        let prefix .= repeat(' ', 4)
        for file_obj in get(d, 'files')
            call append(line('$'), prefix . file_obj['name'] . file_obj['flags'])
            let s:line_map[line("$")] = root . d.name
        endfor
    endif

endfunction

" Calculate optimal window width based on buffer content
function! s:ExplorerAdjustWidth()
    let width_config = g:vp4_explore_width

    " Handle percentage-based width
    if width_config =~ '%$'
        let percentage = str2nr(width_config[:-2])
        if percentage > 0 && percentage < 100
            let total_width = &columns
            let target_width = total_width * percentage / 100
            exec 'vertical resize ' . target_width
        endif
        return
    endif

    " Handle fixed width (numeric)
    if width_config =~ '^\d\+$'
        exec 'vertical resize ' . width_config
        return
    endif

    " Handle auto mode
    if width_config == 'auto'
        " Find the longest line in the buffer
        let max_len = 0
        for i in range(1, line('$'))
            let line_text = getline(i)
            let line_len = strwidth(line_text)
            if line_len > max_len
                let max_len = line_len
            endif
        endfor

        " Apply min/max constraints
        let target_width = max_len + 4  " add some padding
        let target_width = max([target_width, g:vp4_explore_min_width])
        let target_width = min([target_width, g:vp4_explore_max_width])

        exec 'vertical resize ' . target_width
    endif
endfunction

" Populate directory data at given node
function! s:ExplorerPopulate(filepath)
    let perforce_filepath = a:filepath
    if strpart(a:filepath, strlen(a:filepath) - 1, 1) != '/'
        let perforce_filepath .= '/'
    endif
    call s:Debug('Populating "' . perforce_filepath . '" ...')

    if !has_key(s:directory_data, perforce_filepath)
        let s:directory_data[perforce_filepath] = {
                    \'name' : split(perforce_filepath, '/')[-1] . '/',
                    \'folded' : 0,
                    \}
    else
        let s:directory_data[perforce_filepath]['folded'] = 0
    endif

    if !has_key(s:directory_map, perforce_filepath)
        " `where` fails for root of depot, when popping directory stack
        let command = 'where ' . strpart(perforce_filepath, 0, strlen(perforce_filepath) - 1)
        let retval = s:PerforceSystem(command)
        if v:shell_error || strlen(retval) == 0
            let s:directory_map[perforce_filepath] = '/'
        else
            let local_path = split(retval)[-1]
            let s:directory_map[perforce_filepath] = local_path . '/'
        endif
    endif

    if !has_key(s:directory_data[perforce_filepath], 'files')
        let pattern = '"' . perforce_filepath . '*"'

        " Populate directories
        let perforce_command = 'dirs ' . pattern
        let dirnames = filter(split(s:PerforceSystem(perforce_command), '\n'), 'v:val =~ "^//" && v:val !~ "no such"')
        call map(dirnames, 'v:val . "/"')
        for dirname in dirnames
            if !has_key(s:directory_data, dirname)
                let s:directory_data[dirname] = {
                            \'name' : split(dirname, '/')[-1] . '/',
                            \'folded' : 1
                            \}
            endif
        endfor

        " Populate files
        let perforce_command = 'files -e ' . pattern
        let filepaths = filter(split(s:PerforceSystem(perforce_command), '\n'), 'v:val =~ "^//" && v:val !~ "no such"')
        let filenames = []
        let sync_status = s:ExplorerFstatDir(perforce_filepath)
        for filepath in filepaths
            let filename = split(split(filepath)[0], '/')[-1]
            let base_name = s:PerforceStripRevision(filename)
            let stat = get(sync_status, base_name, '')
            if stat == '='
                let flags = ' ='
            elseif stat == '*'
                let flags = ' *'
            else
                let flags = ''
            endif
            let obj = {
                        \'name' : filename,
                        \'flags' : flags,
                        \}
            call add(filenames, obj)
        endfor
        " Neovim does not support calling map with function objects
        " call map(filepaths, {idx, val -> split(split(val)[0], '/')[-1]})

        let s:directory_data[perforce_filepath]['children'] = dirnames
        let s:directory_data[perforce_filepath]['files'] = filenames
    endif

endfunction

" Open the depot file explorer
" :Vp4Explore()               - opens at current file's directory
" :Vp4Explore('.')            - opens at cwd
" :Vp4Explore('//depot/path') - opens at '//depot/path'
" :Vp4Explore('/local/path')  - opens at 'local/path'
function! vp4#PerforceExplore(...)
    let filepath = ''
    let perforce_filepath = ''

    if a:0 > 0
        let filepath = trim(a:1)
    else
        let filepath = expand('%:p:h')
    endif

    let perforce_filepath = s:PerforceGetDirectory(filepath)
    if perforce_filepath == ''
        call s:EchoWarning("Unable to resolve a Perforce directory.")
        return
    endif

    " buffer setup
    if !(s:GoToWindowForBufferName('Depot'))
        silent leftabove vnew Depot
        setlocal buftype=nofile
        setlocal nobuflisted
    endif

    call s:ExplorerPopulate(perforce_filepath)
    call s:ExplorerRender(perforce_filepath)
    call s:ExplorerAdjustWidth()

    " mappings
    nnoremap <script> <silent> <buffer> <CR> :call <sid>ExplorerGoTo()<CR>
    nnoremap <script> <silent> <buffer> -    :call <sid>ExplorerPop()<CR>
    nnoremap <script> <silent> <buffer> c    :call <sid>ExplorerChange()<CR>
    nnoremap <script> <silent> <buffer> s    :call <sid>ExplorerSync(0)<CR>
    nnoremap <script> <silent> <buffer> S    :call <sid>ExplorerSync(1)<CR>
    nnoremap <script> <silent> <buffer> q    :quit<CR>
    nnoremap <script> <silent> <buffer> ?    :call <sid>ExplorerHelp()<CR>

    " syntax
    syn match Vp4Dir /\v.*\//
    syn match Vp4Rev /\v#.*/

    hi def link Vp4Dir Identifier
    hi def link Vp4Rev Comment
endfunction
"
"

" {{{ Lightline integration

" Return a dict summarising the Perforce status of filename.
" Keys: action (edit/add/delete/…), changelist (CL number or 'default'),
"       added, modified, deleted (line counts from p4 diff hunks).
" Returns {} if the file is not opened or an error occurs.
function! vp4#FileStatusSummary(...)
    let l:file = expand(a:0 > 0 ? a:1 : '%:p')
    if empty(l:file) || !filereadable(l:file)
        return {}
    endif
    let l:output = s:PerforceSystemWithFile('-Mj -ztag fstat -T action,change ' . shellescape(l:file), l:file)
    if empty(l:output)
        return {}
    endif
    let l:fstat = {}
    try
        let l:decoded = json_decode(l:output)
        if type(l:decoded) == type({})
            let l:fstat = l:decoded
        elseif type(l:decoded) == type([]) && !empty(l:decoded) && type(l:decoded[0]) == type({})
            let l:fstat = l:decoded[0]
        endif
    catch
        return {}
    endtry
    if !has_key(l:fstat, 'action')
        return {}
    endif
    let l:action = l:fstat['action']
    let l:cl     = get(l:fstat, 'change', 'default')
    let l:result = {'action': l:action, 'changelist': l:cl,
                  \ 'added': 0, 'modified': 0, 'deleted': 0}
    if l:action ==# 'edit' || l:action ==# 'integrate'
        let [l:hp, l:hm] = [0, 0]
        let [l:a, l:m, l:d] = [0, 0, 0]
        let l:diff_lines = split(s:PerforceSystemWithFile('diff -du ' . shellescape(l:file), l:file, {'P4DIFF': ''}), '\n')
        for l:line in l:diff_lines
            if l:line =~# '^+[^+]'
                let l:hp += 1
            elseif l:line =~# '^-[^-]'
                let l:hm += 1
            elseif l:hp > 0 || l:hm > 0
                let l:x = min([l:hp, l:hm])
                let l:m += l:x | let l:a += l:hp - l:x | let l:d += l:hm - l:x
                let [l:hp, l:hm] = [0, 0]
            endif
        endfor
        if l:hp > 0 || l:hm > 0
            let l:x = min([l:hp, l:hm])
            let l:m += l:x | let l:a += l:hp - l:x | let l:d += l:hm - l:x
        endif
        let l:result['added']    = l:a
        let l:result['modified'] = l:m
        let l:result['deleted']  = l:d
    endif
    return l:result
endfunction

" }}}

" vim: foldenable foldmethod=marker
