" File:         vp4.vim
" Description:  vim global plugin for perforce integration
" Last Change:  Nov 22, 2016
" Author:       Emily Ng

" {{{ Initialization
if exists('g:loaded_vp4') || !executable('p4') || &cp
    if exists('g:vp4_debug') && !g:vp4_debug
        finish
    endif
endif
let g:loaded_vp4 = 1

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
call s:set('g:vp4_annotate_revision', 0)
call s:set('g:vp4_annotate_ignore_whitespace', 1)
call s:set('g:vp4_open_loclist', 1)
call s:set('g:vp4_filelog_max', 10)
call s:set('g:vp4_debug', 0)
call s:set('g:vp4_diff_suppress_header', 1)
call s:set('g:vp4_print_suppress_header', 1)
call s:set('g:_vp4_curpos', [0, 0, 0, 0])
call s:set('g:_vp4_filetype', 'txt')
call s:set('g:vp4_allow_open_depot_file', 1)
call s:set('g:vp4_sync_options', '')
call s:set('g:vp4_base_path_replacements', {})
call s:set('g:vp4_disable_default_changelist', 0)
call s:set('g:vp4_client_for_file_cmd', '')
call s:set('g:vp4_cache_ttl', 600)
call s:set('g:_vp4_client', '')
call s:set('g:_vp4_loclist_winnr', 0)
call s:set('g:_vp4_filelog_data', [])
call s:set('g:_vp4_diff_return_tabpage', 0)
call s:set('g:_vp4_diff_return_winnr', 0)

" }}}

" {{{ Auto-commands
augroup PromptOnWrite
    autocmd!
    if g:vp4_prompt_on_write
        autocmd BufWritePre * call vp4#PromptForOpen()
    endif
augroup END

augroup Vp4Enter
    autocmd!
    if g:vp4_allow_open_depot_file
        autocmd VimEnter,BufReadCmd \(//\)\|\(#[0-9]\+\)  call vp4#CheckServerPath(expand('%'))
    endif
augroup END

augroup Vp4StatusCache
    autocmd!
    autocmd BufEnter     * call s:UpdateVp4CacheIfStale()
    autocmd BufWritePost * call s:UpdateVp4Cache()
    autocmd User Vp4Changed call s:UpdateVp4Cache()
augroup END

function! s:UpdateVp4Cache()
    let l:f = expand('%:p')
    if empty(l:f) || !filereadable(l:f)
        return
    endif
    let b:vp4_workspace      = vp4#GetWorkspaceForFile(l:f)
    let b:vp4_status_summary = vp4#FileStatusSummary(l:f)
    let b:vp4_cache_time     = localtime()
endfunction

function! s:UpdateVp4CacheIfStale()
    if localtime() - get(b:, 'vp4_cache_time', 0) >= g:vp4_cache_ttl
        call s:UpdateVp4Cache()
    endif
endfunction
" }}}

" {{{ Register commands
command! -nargs=? Vp4Diff call vp4#PerforceDiff(<f-args>)
command! -range=% -nargs=? Vp4Annotate <line1>,<line2>call vp4#PerforceAnnotate(<f-args>)
command! Vp4Change call vp4#PerforceChange()
command! -nargs=? Vp4Filelog call vp4#PerforceFilelog(<f-args>)
command! Vp4FilelogDiff call vp4#PerforceFilelogDiff()
command! -bang Vp4Revert call vp4#PerforceRevert(<bang>0)
command! -bang Vp4Delete call vp4#PerforceDelete(<bang>0)
command! Vp4Reopen call vp4#PerforceReopen()
command! -nargs=? Vp4Edit call vp4#PerforceEdit(<f-args>)
command! Vp4QuickfixEdit call vp4#PerforceEditFilesInQuickFixList()
command! Vp4CoEdit call vp4#PerforceEditFilesInQuickFixList()
command! Vp4Add call vp4#PerforceAdd()
command! Vp4AnnotateLine call vp4#PerforceAnnotateLine()
command! Vp4AnnotateLineDiff call vp4#PerforceAnnotateLineDiff()
command! -bang Vp4Shelve call vp4#PerforceShelve(<bang>0)
command! Vp4Describe call vp4#PerforceDescribe()
command! -nargs=+ Vp4 call vp4#PerforceSystemWr(<f-args>)
command! Vp4Info call vp4#PerforceSystemWr('fstat ' . expand('%'))
command! -nargs=? Vp4Explore call vp4#PerforceExplore(<f-args>)
" }}}

" vim: foldenable foldmethod=marker
