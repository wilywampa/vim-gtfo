let s:iswin = has('win32') || has('win64') || has('win32unix') || has('win64unix')
let s:ismac = has('gui_macvim') || has('mac')
let s:istmux = !(empty($TMUX))
"GUI Vim
let s:isgui = has('gui_running') || &term ==? 'builtin_gui'
"non-GUI Vim running within a GUI environment
let s:is_gui_available = s:ismac || s:iswin || (!empty($DISPLAY) && $TERM !=# 'linux')

let s:termpath = ''
let s:tmux_1_6 = 0

func! s:beep(s)
  echohl ErrorMsg | echom 'gtfo: '.a:s | echohl None
endf
func! s:trimws(s)
  return substitute(a:s, '^\s*\(.\{-}\)\s*$', '\1', '')
endf
func! s:scrub(s)
  "replace \\ with \ (greedy) #21
  return substitute(a:s, '\\\\\+', '\', 'g')
endf
func! s:empty(s)
  return strlen(s:trimws(a:s)) == 0
endf

func! s:init()
  " initialize missing keys with empty strings.
  let g:gtfo#terminals = extend(get(g:, "gtfo#terminals", {}),
        \ { 'win' : '', 'mac' : '', 'unix': '' }, 'keep')

  if s:iswin
    let s:termpath = s:empty(g:gtfo#terminals.win) ? s:find_cygwin_bash() : g:gtfo#terminals.win
  elseif s:ismac
    let s:termpath = s:empty(g:gtfo#terminals.mac) ? '' : g:gtfo#terminals.mac
  else
    let s:termpath = s:empty(g:gtfo#terminals.unix) ? '' : g:gtfo#terminals.unix
  endif

  let s:termpath = s:trimws(s:termpath)

  if s:istmux
    call system('tmux -V')
    let s:tmux_1_6 = v:shell_error
  endif
endf

func! s:try_find_git_bin(binname)
  "try 'Program Files', else fall back to 'Program Files (x86)'.
  for programfiles_path in [$ProgramW6432, $ProgramFiles, $ProgramFiles.' (x86)']
    let path = substitute(programfiles_path, '\', '/', 'g').'/'.a:binname
    if executable(path)
      return path
    endif
  endfor
  return ''
endf

func! s:find_cygwin_bash()
  let path = s:try_find_git_bin('Git/usr/bin/mintty.exe')
  let path = '' !=# path ? path : s:try_find_git_bin('Git/bin/bash.exe')
  "return path or fallback to vanilla cygwin.
  return '' !=# path ? path : 
        \ (executable($SystemDrive.'/cygwin/bin/bash') ? $SystemDrive.'/cygwin/bin/bash' : '')
endf

func! s:force_cmdexe()
  if &shell !~? "cmd"
    let s:shell=&shell | let s:shslash=&shellslash | let s:shcmdflag=&shellcmdflag
    set shell=$COMSPEC noshellslash shellcmdflag=/c
  endif
endf

func! s:restore_shell()
  if exists("s:shell")
    let &shell=s:shell | let &shellslash=s:shslash | let &shellcmdflag=s:shcmdflag
  endif
endf

func! s:cygwin_cmd(path, dir, validfile)
  let startcmd = executable('cygstart') ? 'cygstart' : 'start'
  return a:validfile
        \ ? startcmd.' explorer /select,$(cygpath -w '.shellescape(a:path).')'
        \ : startcmd.' explorer $(cygpath -w '.shellescape(a:dir).')'
endf

func! gtfo#open#file(path) "{{{
  if exists('+shellslash') && &shellslash
    "Windows: force expand() to return `\` paths so explorer.exe won't choke. #11
    let l:shslash=1 | set noshellslash
  endif

  let l:path = s:scrub(expand(a:path, 1))
  let l:dir = isdirectory(l:path) ? l:path : fnamemodify(l:path, ":h")
  let l:validfile = filereadable(l:path)

  if exists("l:shslash")
    set shellslash
  endif

  if !isdirectory(l:dir) "this happens if the directory was moved/deleted.
    echom 'gtfo: invalid/missing directory: '.l:dir
    return
  endif

  if executable('cygpath')
    silent call system(s:cygwin_cmd(l:path, l:dir, l:validfile))
  elseif s:iswin
    call s:force_cmdexe()
    silent exec '!start explorer '.(l:validfile ? '/select,'.shellescape(l:path, 1) : shellescape(l:dir, 1))
    call s:restore_shell()
  elseif !s:is_gui_available && !executable('xdg-open')
    if s:istmux "fallback to 'got'
      call gtfo#open#term(l:dir, "")
    else
      call s:beep('failed to open file manager')
    endif
  elseif s:ismac
    if l:validfile
      silent call system('open --reveal '.shellescape(l:path))
    else
      silent call system('open '.shellescape(l:dir))
    endif
  elseif executable('xdg-open')
    silent call system("xdg-open ".shellescape(l:dir)." &")
  else
    call s:beep('xdg-open is not in your $PATH. Try "sudo apt-get install xdg-utils"')
  endif
endf "}}}

func! gtfo#open#term(dir, cmd) "{{{
  let l:dir = s:scrub(expand(a:dir, 1))
  if !isdirectory(l:dir) "this happens if a directory was deleted outside of vim.
    call s:beep('invalid/missing directory: '.l:dir)
    return
  endif

  if s:istmux
    if exists("a:cmd") && a:cmd == 'win'
      silent call system("tmux new-window 'cd \"" . l:dir . "\"; $SHELL'")
    else
      silent call system('tmux split-window -'.
          \ gtfo#open#splitdirection()." 'cd \"" . l:dir . "\"; $SHELL'")
    endif
  elseif &shell !~? "cmd" && executable('cygstart') && executable('mintty')
    " https://code.google.com/p/mintty/wiki/Tips
    silent exec '!cd '.shellescape(l:dir, 1).' && cygstart mintty /bin/env CHERE_INVOKING=1 /bin/bash'
    if !s:isgui | redraw! | endif
  elseif s:iswin && &shell !~? "cmd" && executable('mintty')
    silent call system('cd '.shellescape(l:dir).' && mintty - &')
  elseif s:iswin
    call s:force_cmdexe()
    if s:isgui
      " Prevent cygwin/msys from inheriting broken $VIMRUNTIME.
      " WEIRD BUT TRUE: This correctly unsets $VIMRUNTIME in the child shell,
      "                 without modifying $VIMRUNTIME in the running gvim.
      let $VIMRUNTIME=''
    endif

    if s:termpath =~? "bash" && executable(s:termpath)
      silent exe '!start '.$COMSPEC.' /c "cd '.shellescape(l:dir, 1).' & "'.s:termpath.'" --login -i "'
    elseif s:termpath =~? "mintty" && executable(s:termpath)
      silent exe '!start /min '.$COMSPEC.' /c "cd '.shellescape(l:dir, 1).' & "'.s:termpath.'" - " & exit'
    else "Assume it's a path with the required arguments (considered 'not executable' by Vim).
      if s:empty(s:termpath) | let s:termpath = 'cmd.exe /k'  | endif
      " This will nest quotes (""foo" "bar""), and yes, that is what cmd.exe expects.
      silent exe '!start '.s:termpath.' "cd '.shellescape(l:dir, 1).'"'
    endif
    call s:restore_shell()
  elseif s:ismac
    if (s:empty(s:termpath) && $TERM_PROGRAM ==? 'iTerm.app') || s:termpath ==? "iterm"
      silent call system("open -a iTerm ".shellescape(l:dir))
    else
      if s:empty(s:termpath) | let s:termpath = 'Terminal' | endif
      silent call system("open -a ".shellescape(s:termpath)." ".shellescape(l:dir))
    endif
  elseif s:is_gui_available
    if !s:empty(s:termpath)
      silent call system(shellescape(s:termpath)." ".shellescape(l:dir))
    elseif executable('gnome-terminal')
      silent call system('gnome-terminal --window -e "$SHELL -c \"cd '''.l:dir.''' ; exec $SHELL\""')
    else
      call s:beep('failed to open terminal')
    endif
    if !s:isgui | redraw! | endif
  else
    call s:beep('failed to open terminal')
  endif
endf "}}}

func! gtfo#open#splitdirection()
  if system('tmux display-message -pF "#F"') =~# 'Z'
    call system('tmux resize-pane -Z')
  endif
  let tmuxcols = split(system('tmux display-message -pF "#{client_width} #{pane_width}"'))
  let l:split=0
  for win in range(1,winnr('$'))
    if winwidth(win) < &columns
      let split=1
    endif
  endfor
  if tmuxcols[0] > 160 && tmuxcols[0] == tmuxcols[1] && !split
      \ && (str2float(&columns) / str2float(&lines)) > 2.5
    return 'h'
  else
    return 'v'
  endif
endf

call s:init()
