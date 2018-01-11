" File:         vp4.vim
" Description:  vim global plugin for perforce integration
" Last Change:  Nov 22, 2016
" Author:       Emily Ng

" {{{ Initialization
if exists('g:loaded_vp4') || !executable('p4') || &cp
    if !g:perforce_debug
        finish
    endif
endif
let g:loaded_vp4 = 1
let s:directory_data = {}
let s:line_map = {}

function! vp4#sid()
    return maparg('<SID>', 'n')
endfunction
nnoremap <SID> <SID>

" Options
function! s:set(var, default)
  if !exists(a:var)
    if type(a:default)
      execute 'let' a:var '=' string(a:default)
    else
      execute 'let' a:var '=' a:default
    endif
  endif
endfunction

call s:set('g:vp4_perforce_executable', 'p4')
call s:set('g:vp4_prompt_on_write', 1)
call s:set('g:vp4_prompt_on_modify', 0)
call s:set('g:vp4_annotate_revision', 0)
call s:set('g:vp4_open_loclist', 1)
call s:set('g:vp4_filelog_max', 10)
call s:set('g:perforce_debug', 0)
call s:set('g:vp4_diff_suppress_header', 1)
call s:set('g:vp4_print_suppress_header', 1)
call s:set('g:_vp4_curpos', [0, 0, 0, 0])
call s:set('g:_vp4_filetype', 'txt')
call s:set('g:vp4_allow_open_depot_file', 1)

" }}}

" {{{ Helper functions

" {{{ Generic Helper functions
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
" }}}

" {{{ Perforce system functions
" Return result of calling p4 command
function! s:PerforceSystem(cmd)
    let command = g:vp4_perforce_executable . " " . a:cmd . " 2> /dev/null"
    if g:perforce_debug
        echom "DBG sys: " . command
    endif
    let retval = system(command)
    return retval
endfunction

" Append results of p4 command to current buffer
function! s:PerforceRead(cmd)
    let _modifiable = &modifiable
    set modifiable
    let command = '$read !' . g:vp4_perforce_executable . " " . a:cmd
    if g:perforce_debug
        echom "DBG read: " . command
    endif
    " Populate the window and get rid of the extra line at the top
    execute command
    1
    execute 'normal! dd'
    let &modifiable=_modifiable
endfunction

" Use current buffer as stdin to p4 command
function! s:PerforceWrite(cmd)
    let command = 'write !' . g:vp4_perforce_executable . " " . a:cmd
    if g:perforce_debug
        echom "DBG write: " . command
    endif
    execute command
endfunction
" }}}

" {{{ Perforce checker infrastructure
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
    let s = s:PerforceSystem('fstat -T ' . a:field . ' ' . a:filename)
    if v:shell_error || matchstr(s, '\.\.\.') == ''
        if matchstr(s, 'P4PASSWD') != ''
            call s:EchoError(split(s, '\n')[0])
            return 0
        else
            throw 'PerforceFstatError'
        endif
    endif

    " Extract the value from the string which looks like:
    "   ... headRev 65\n\n
    let val = split(split(s, '\n')[0], ' ')[2]
    if g:perforce_debug
        echom 'fstat got value ' . val . ' for field ' . a:field
                \ . ' on file ' . a:filename
    endif

    return val
endfunction

" Assert fstat field
function! s:PerforceAssert(field, filename, msg)
    try
        let retval = s:PerforceFstat(a:field, a:filename)
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
" }}}

" {{{ Perforce field checkers

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
" }}}

" {{{ Perforce revision specification helpers
" Return filename with any revision specifier stripped
function! s:PerforceStripRevision(filename)
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
" }}}
" }}}

" {{{ Main functions

" {{{ System
function! s:PerforceSystemWr(...)
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
" }}}

" {{{ File editing
" Call p4 add.
function! s:PerforceAdd()
    let filename = expand('%')

    call s:PerforceSystem('add ' .filename)
endfunction

" Call p4 delete.
function! s:PerforceDelete(bang)
    let filename = expand('%')
    if !s:PerforceAssertExists(filename) | return | endif

    if !a:bang
        let do_delete = input('Are you sure you want to delete ' . filename
                \ . '? [y/n]: ')
    endif

    if a:bang || do_delete ==? 'y'
        call s:PerforceSystem('delete ' .filename)
        bdelete
    endif

endfunction

" Call p4 edit.
function! s:PerforceEdit()
    let filename = expand('%')
    if !s:PerforceAssertExists(filename) | return | endif

    call s:PerforceSystem('edit ' .filename)

    " reload the file to refresh &readonly attribute
    execute 'edit ' filename
endfunction

" Call p4 revert.  Confirms before performing the revert.
function! s:PerforceRevert(bang)
    let filename = expand('%')
    if !s:PerforceAssertOpened(filename) | return | endif

    if !a:bang
        let do_revert = input('Are you sure you want to revert ' . filename
                \ . '? [y/n]: ')
    endif

    if a:bang || do_revert ==? 'y'
        call s:PerforceSystem('revert ' .filename)
        set nomodified
    endif

    " reload the file to refresh &readonly attribute
    execute 'edit ' filename
endfunction
" }}}

" {{{ Change specification
" Call p4 shelve
function! s:PerforceShelve(bang)
    let filename = expand('%')
    if !s:PerforceAssertOpened(filename) | return | endif

    let perforce_command = 'shelve'
    let cl = s:PerforceGetCurrentChangelist(filename)

    if cl !~# 'default'
        let perforce_command .= ' -c ' . cl
        if a:bang | let perforce_command .= ' -f' | endif
        let msg = split(s:PerforceSystem(perforce_command . ' ' . filename), '\n')
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
function! s:PerforceChange()
    let filename = expand('%')
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
function! s:PerforceDescribe()

    let filename = expand('%')
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
function! s:PerforceReopen()
    let filename = expand('%')
    if !s:PerforceAssertOpened(filename) | return | endif

    " Get the pending changes in the current client
    let perforce_command = "changes -u $USER -s pending -c $P4CLIENT"
    let changes = split(s:PerforceSystem(perforce_command), '\n')

    " Prepend with choice numbers, starting at 1
    call map(changes, 'v:key + 1 . ". " . v:val')

    " Prompt the user
    let currentchangelist = s:PerforceGetCurrentChangelist(filename)
    echom filename . ' is currently open in change "' . currentchangelist
            \ . '" Select a changelist to move to: '
    let change = inputlist(changes + [len(changes) + 1 . '. default'])

    " From the user's input, get the actual changelist number
    if !change | return | endif
    let change_number = change > len(changes) ? 'default'
            \ : split(changes[change - 1], ' ')[2]
    echom 'Moving ' . filename . ' to change ' . change_number

    " Perform the reopen command
    let perforce_command = 'reopen -c ' . change_number . ' ' . filename
    call s:PerforceSystem(perforce_command)
endfunction
" }}}

" {{{ Analysis
" Open repository revision in diff mode
    "  Options:
    "  s       diffs with shelved in file's current changelist
    "  @cl     diffs with shelved in given changelist
    "  p       diffs with previous revision (i.e. have revision - 1)
    "  #rev    diffs with given revision
    "  <none>  diffs with have revision
function! s:PerforceDiff(...)
    let filename = expand('%')

    " Check for options
    "   'a:0' is set to the number of extra arguments
    "   a:1 is the first extra argument, a:2 the second, etc.
    " @cl: Diff with shelved in a:1
    if a:0 >= 1 && a:1[0] == '@'
        let cl = split(a:1, '@')[0]
        let filename .= '@=' . cl
    " #rev: Diff with revision a:1
    elseif a:0 >= 1 && a:1[0] == '#'
        let filename = s:PerforceStripRevision(filename) . a:1
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
    execute 'leftabove vnew ' . shellescape(filename, 1)
    let perforce_command = 'print'
    if g:vp4_diff_suppress_header
        let perforce_command .= ' -q'
    endif
    let perforce_command .= ' ' . shellescape(filename, 1)
    silent call s:PerforceRead(perforce_command)

    " Set local buffer options
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile nowrap
    setlocal nomodifiable
    setlocal nomodified
    execute "set filetype=" . filetype
    diffthis
    nnoremap <buffer> <silent> q :<C-U>bdelete<CR> :windo diffoff<CR>
endfunction

" Syntax highlighting for annotation data
function! s:PerforceAnnotateHighlight()
    syn match VP4Change /\v\d+$/
    syn match VP4Date /\v\d{4}\/\d{2}\/\d{2}/

    hi def link VP4Change Number
    hi def link VP4Date Comment
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
            let cl_data = split(s:PerforceSystem('change -o ' . line), '\n')

            try
                let data[line]['date'] = split(split(cl_data[17], '\t')[1], ' ')[0]
                let data[line]['user'] = s:PrePad(split(cl_data[21], '\t')[1], 8)
                let data[line]['description'] = substitute(join(cl_data[26:-1]),
                        \ "\t", "", "g")

                " [Hack] Conveniently use the fact that we have the user name
                " now to identify it as a keyword for highlighting later.
                execute " syn keyword VP4User " . data[line]['user']
            catch
                echom 'failed to get data for change ' . line
                if g:perforce_debug
                    echom join(cl_data)
                endif
                continue
            endtry
        endif

        " Small state machine to display the description for the current
        " changelist.  First line shows the date and user, subsequent lines show
        " the continue description, if it exceeds one line.
        if line != last_cl
            let idx = 0
            let LEN = 40
            call setline(lnr, strpart(data[line]['description'], idx, LEN)
                    \ . ' ' . data[line]['date']
                    \ . ' ' . data[line]['user']
                    \ . ' ' . line
                    \ )
        else
            let idx += LEN
            let LEN = 60
            call setline(lnr, strpart(data[line]['description'], idx, LEN)
                    \ . ' ' .line
                    \ )
        endif

        let last_cl = line
        let lnr = nextnonblank(lnr + 1)
    endwhile

    set nomodifiable
endfunction

" Open a scrollbound split containing on each line the changelist number in
    " which it was last edited.  Accepts a range to limit the section being
    " fully annotated.
function! s:PerforceAnnotate(...) range
    let filename = expand('%')
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
    %right
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

" Populate the quick-fix or location list with the past revisions of this file.
    " Only lists the files and some changelist data.  The file is not retrieved
    " until the user opens it.
function! s:PerforceFilelog()
    let filename = s:PerforceStripRevision(expand('%'))
    if !s:PerforceAssertExists(filename) | return | endif

    " Remember some stuff about this file
    let g:_vp4_filetype = &filetype
    let g:_vp4_curpos = getcurpos()

    " Set up the command.  Limit the maximum number of entries.
    let command = 'filelog'
    if g:vp4_filelog_max > 0
        let command .= ' ' . '-m ' . g:vp4_filelog_max
    endif
    let command .= ' ' . filename

    " Compile all the location list data
    let data = []
    for line in split(s:PerforceSystem(command), '\n')
        let fields = split(line, '\s')

        " Cheap way to filter out irrelevant lines such as just the filename
        " (which is the first line), or 'branch into' lines
        if len(fields) < 8
            continue
        endif

        " Set up dictionary entry
        let entry = {}
        let entry['filename'] = filename . fields[1]
        let entry['lnum'] = g:_vp4_curpos[1]
        let entry['text'] = join(fields[2:-1])

        " Add it to the list
        call add(data, entry)
    endfor

    " Populate the location list
    call setloclist(0, data)

    " Automatically open quick-fix or location list
    if g:vp4_open_loclist
        lopen
    endif

    " Set auto command for opening specific revisions of files
    augroup OpenRevision
        autocmd!
        autocmd BufEnter *#* call <SID>PerforceOpenRevision()
    augroup END
endfunction
" }}}

" {{{ Passive (called by auto commands)
" Check if file exists in the depot and is not already opened for edit.  If so,
" prompt user to open for edit.
function! s:PromptForOpen()
    let filename = expand('%')
    if &readonly && s:PerforceAssertExists(filename)
        let do_edit = input(filename .
                \' is not opened for edit.  p4 edit it now? [y/n]: ')
        if do_edit ==? 'y'
            setlocal autoread
            call s:PerforceSystem('edit ' .filename)
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

    let filename = expand('%')
    if !s:PerforceAssertExists(filename) | return | endif

    " Print the file to this buffer
    silent call s:PerforceRead('print -q ' . shellescape(filename, 1))
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
function! s:CheckServerPath(filename)
    " test for existence of depot file
    if !s:PerforceExists(a:filename) | return | endif

    let requested_rev = matchstr(a:filename, '#[0-9]\+')
    let requested_rev = strpart(requested_rev, 1)

    " check for existence of local file
    let have_rev = s:PerforceQuery('haveRev', a:filename)
    if len(requested_rev) == 0 || have_rev == requested_rev
        let old_bufnr = bufnr('%')
        let old_bufname = bufname('%')
        let client_file = s:PerforceQuery('clientFile', a:filename)
        execute 'edit ' . client_file
        let new_bufnr = bufnr('%')
        let new_bufname = bufname('%')

        if g:perforce_debug
            echom 'old: ' . old_bufnr . ' ' . old_bufname
            echom 'new: ' . new_bufnr . ' ' . new_bufname
        endif

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
    let perforce_command .= shellescape(filename, 1)
    call s:PerforceRead(perforce_command)

    " get filetype
    execute 'doauto BufRead ' . substitute(filename, '#.*', '', '')

    setlocal buftype=nofile
    setlocal nomodifiable

endfunction

" }}}

" {{{ Depot explorer

" Change explorer root to selected directory
function! s:ExplorerChange()
    let filename = split(getline('.'))[0]
    if strpart(filename, strlen(filename) - 1, 1) != '/' | return | endif

    let fullpath = s:line_map[line(".")] . filename
    let s:directory_data[fullpath]['folded'] = 0
    call s:ExplorerPopulate(fullpath)
    call s:ExplorerRender(fullpath, 0, s:FilepathHead(fullpath))
endfunction

" If on a directory, toggle the directory.
" If on a file, go to that file.
function! s:ExplorerGoTo()
    let filename = split(getline('.'))[0]
    if strpart(filename, strlen(filename) - 1, 1) == '/'
        " directory
        let fullpath = s:line_map[line(".")] . filename

        " populate if not populated
        let d = get(s:directory_data, fullpath)
        if !has_key(d, 'files')
            call s:ExplorerPopulate(fullpath)
        endif

        " toggle fold/unfold
        let d.folded = !d.folded
        let saved_curpos = getcurpos()
        call s:ExplorerRender(s:explorer_key, 0, s:explorer_root)
        call setpos('.', saved_curpos)
    else
        " file
        call s:CheckServerPath(filename)
    endif
endfunction

" Return head of a:filepath
function! s:FilepathHead(filepath)
    let path = split(a:filepath, '/')
    call remove(path, -1)
    return '//' . join(path, '/') . '/'
endfunction

function! s:ExplorerPop()
    call s:ExplorerPopulate(s:explorer_root)
    let root = s:FilepathHead(s:explorer_root)
    call s:ExplorerRender(s:explorer_root, 0, root)
    let s:explorer_key = s:explorer_root
    let s:explorer_root = root
endfunction

" Render the directory data as a tree, using `a:key` as the root
function! s:ExplorerRender(key, level, root)
    " Clear screen before rendering
    if a:level == 0
        silent normal! ggdG
    endif

    " Setup
    let d = get(s:directory_data, a:key)
    let prefix = repeat(' ', a:level * 4)

    " Print myself
    call append(line('$'), prefix . d.name)
    let s:line_map[line("$")] = a:root

    " Print my children
    if !d.folded
        " print directories
        for child in get(d, 'children', [])
            call s:ExplorerRender(child, a:level + 1, a:root . d.name)
        endfor

        " print files
        let prefix .= repeat(' ', 4)
        for filename in get(d, 'files', [])
            call append(line('$'), prefix . filename)
            let s:line_map[line("$")] = a:root
        endfor
    endif

endfunction

" Populate directory data at given node
function! s:ExplorerPopulate(filepath)
    if !has_key(s:directory_data, a:filepath)
        let s:directory_data[a:filepath] = {
                    \'name' : split(a:filepath, '/')[-1] . '/',
                    \'folded' : 0,
                    \}
    endif

    if !has_key(s:directory_data[a:filepath], 'files')
        let pattern = '"' . a:filepath . '*"'

        " Populate directories
        let perforce_command = 'dirs ' . pattern
        let dirnames = split(s:PerforceSystem(perforce_command), '\n')
        call map(dirnames, {idx, val -> val . '/'})
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
        let filenames = split(s:PerforceSystem(perforce_command), '\n')
        call map(filenames, {idx, val -> split(split(val)[0], '/')[-1]})

        let s:directory_data[a:filepath]['children'] = dirnames
        let s:directory_data[a:filepath]['files'] = filenames
    endif

endfunction

" Open the depot file explorer
function! s:PerforceExplore()
    let perforce_filename = s:PerforceQuery('depotFile', expand('%:p'))
    let perforce_filepath = s:FilepathHead(perforce_filename)
    let root = s:FilepathHead(perforce_filepath)

    " buffer setup
    silent leftabove vnew Depot
    setlocal buftype=nofile
    vertical resize 60

    let s:explorer_key = perforce_filepath
    let s:explorer_root = root
    call s:ExplorerPopulate(perforce_filepath)
    call s:ExplorerRender(perforce_filepath, 0, root)

    " dir_data = {
    "   '<full path name>' : {
    "       'name' : "<name>/",
    "       'folded' : <0 folded, 1 unfolded>,
    "       'files' : [<list of file names>],
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

    " mappings
    nnoremap <script> <silent> <buffer> <CR> :call <sid>ExplorerGoTo()<CR>
    nnoremap <script> <silent> <buffer> -    :call <sid>ExplorerPop()<CR>
    nnoremap <script> <silent> <buffer> C    :call <sid>ExplorerChange()<CR>
    nnoremap <script> <silent> <buffer> q    :quit<CR>

    " syntax
    syn match Vp4Dir /\v.*\//
    syn match Vp4Rev /\v#.*/

    hi def link Vp4Dir Identifier
    hi def link Vp4Rev Comment
endfunction
" }}}
" }}}

" {{{ Auto-commands
augroup PromptOnWrite
    autocmd!
    if g:vp4_prompt_on_write
        autocmd BufWritePre * call <SID>PromptForOpen()
    endif
    if g:vp4_prompt_on_modify
        autocmd FileChangedRO * call <SID>PromptForOpen()
    endif
augroup END

augroup Vp4Enter
    autocmd!
    if g:vp4_allow_open_depot_file
        autocmd VimEnter,BufReadCmd \(//\)\|\(#[0-9]\+\)  call <SID>CheckServerPath(expand('%'))
    endif
augroup END
" }}}

" {{{ Register commands
command! -nargs=? Vp4Diff call <SID>PerforceDiff(<f-args>)
command! -range=% -nargs=? Vp4Annotate <line1>,<line2>call <SID>PerforceAnnotate(<f-args>)
command! Vp4Change call <SID>PerforceChange()
command! Vp4Filelog call <SID>PerforceFilelog()
command! -bang Vp4Revert call <SID>PerforceRevert(<bang>0)
command! -bang Vp4Delete call <SID>PerforceDelete(<bang>0)
command! Vp4Reopen call <SID>PerforceReopen()
command! Vp4Edit call <SID>PerforceEdit()
command! Vp4Add call <SID>PerforceAdd()
command! -bang Vp4Shelve call <SID>PerforceShelve(<bang>0)
command! Vp4Describe call <SID>PerforceDescribe()
command! -nargs=+ Vp4 call <SID>PerforceSystemWr(<f-args>)
command! Vp4Info call <SID>PerforceSystemWr('fstat ' . expand('%'))
command! Vp4Explore call <SID>PerforceExplore()
" }}}

" vim: foldenable foldmethod=marker
