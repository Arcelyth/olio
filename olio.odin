package olio

import "core:sys/posix"
import "core:c/libc"
import "core:os"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:bytes"
import "core:time"
import "core:mem"

E_Row :: struct {
    idx: int,
    size: int,
    rsize: int,
    chars: [dynamic]byte,
    render: [dynamic]byte,
    hl: [dynamic]Highlight,
    hl_open_comment: bool
}

Config :: struct {      // editor's config
    cx, cy: int,        // cursor's position
    rx: int, 
    screen_row: int,
    screen_col: int,
    rowoff, coloff: int,    // offset
    num_rows: int,
    dirty: int,         // be modified
    row: [dynamic]E_Row,
    origin_termios: posix.termios,
    filename: string,
    status_msg: string,
    status_msg_time: time.Time,
    syntax: ^Syntax
}

Buffer :: bytes.Buffer  // append buffer

E: Config

Result :: enum {
    Err,
    Ok,
}

Highlight :: enum {
    Hl_Normal,
    Hl_Comment,
    Hl_Mlcomment,
    Hl_Keyword1,
    Hl_Keyword2,
    Hl_Number,
    Hl_String,
    Hl_Escape,
    Hl_Match
}

Key :: union {
    byte,
    Arrow
}

Arrow :: enum {
    Backspace = 127,
    Arrow_Left = 1000,
    Arrow_Right,
    Arrow_Up,
    Arrow_Down,
    Page_Up,
    Page_Down,
    Home_Key,
    End_Key,
    Del_Key
}

Syntax_Flag :: enum {
    Hl_Highlight_Numbers,
    Hl_Highlight_String,
    Hl_Highlight_Escape,
}

Syntax :: struct {
    filetype: string,
    filematch: []string,
    keywords: []string,
    singleline_comment_start: string,
    multiline_comment_start: string,
    multiline_comment_end: string,
    flags: bit_set[Syntax_Flag; u32]
}

C_Hl_Extensions := []string {".c", ".h", ".cpp"}
C_Hl_Keywords := []string {
    "switch", "if", "while", "for", "break", "continue", "return", "else", "struct", "union", "typedef", "static", "enum", "class", "case",
    "int|", "long|", "double|", "float|", "char|", "unsigned|", "signed|", "void|"
}

Odin_Hl_Extensions := []string {".odin"}
Odin_Hl_Keywords := []string {
    "if", "else", "for", "switch", "case", "break", "continue", "return", "defer", 
    "do", "when", "where", "fallthrough", "proc", "struct", "enum", "union", 
    "bit_field", "bit_set", "map", "dynamic", "import", "export", "foreign", 
    "package", "using", "distinct", "opaque", "inline", "no_inline", "asm", 
    "context", "cast", "auto_cast", "transmute", "in", "notin", "not_in",
    "size_of", "offset_of", "type_info_of", "typeid_of", "type_of", "align_of",
    "or_return", "or_else", "or_break", "or_continue",

    "int|", "uint|", "uintptr|", "i8|", "i16|", "i32|", "i64|", "i128|", 
    "u8|", "u16|", "u32|", "u64|", "u128|", "f16|", "f32|", "f64|", 
    "bool|", "b8|", "b16|", "b32|", "b64|", "string|", "cstring|", "rune|", 
    "any|", "rawptr|", "typeid|", "complex32|", "complex64|", "complex128|",
    "quaternion64|", "quaternion128|", "quaternion256|", "matrix|",
    "i16le|", "i32le|", "i64le|", "i128le|", "u16le|", "u32le|", "u64le|", "u128le|",
    "i16be|", "i32be|", "i64be|", "i128be|", "u16be|", "u32be|", "u64be|", "u128be|",
    "f16le|", "f32le|", "f64le|", "f16be|", "f32be|", "f64be|",
    "true|", "false|", "nil|",
}

Hl_Db := []Syntax {
    Syntax {
        "c", 
        C_Hl_Extensions,
        C_Hl_Keywords,
        "//", "/*", "*/",
        {.Hl_Highlight_Numbers, .Hl_Highlight_String, .Hl_Highlight_Escape}
    },
    Syntax {
        "odin",
        Odin_Hl_Extensions,
        Odin_Hl_Keywords,
        "//", "/*", "*/",
        {.Hl_Highlight_Numbers, .Hl_Highlight_String, .Hl_Highlight_Escape}
    }
}

Olio_Version := "0.0.1"
Tab_Stop := 4
Quit_Times := 3

append_row :: proc(line: []byte) {
    e := E_Row {0, len(line), 0, slice.clone_to_dynamic(line), {}, {}, false}
    append(&E.row, e)
    editor_update_row(&E.row[E.num_rows])
    E.num_rows = len(E.row)
    E.dirty += 1
}

/*** file IO ***/
editor_open :: proc (path: string) {
    E.filename = path
    select_syntax_highlight()
    content, ok := os.read_entire_file(path)
    defer delete(content)
    if !ok do die("Failed to read file")

    start := 0 
    for i := 0; i < len(content); i += 1 {
        if content[i] == '\n' {
            line := content[start:i]
            if len(line) > 0 && content[len(line)-1] == '\r' do line = content[:len(line)-1]
            insert_row(E.num_rows, line)
            start = i + 1
        }
    } 
    E.dirty = 0
}

rows_to_string :: proc() -> ([]byte, int) {
    totlen := 0
    buf : [dynamic]byte
    for r in E.row {
        append(&buf, ..r.chars[:])
        append(&buf, '\n')
        totlen += r.size + 1
    }
    return buf[:], totlen
} 

editor_save :: proc() {
    if E.filename == "" {
        E.filename = editor_prompt("Save as: %s (ESC to cancel)", nil)
        if E.filename == "" {
            set_status_message("Save aborted")
            return 
        }
    }
    buf, len := rows_to_string()
    defer delete(buf)
    fd, err := os.open(E.filename, os.O_RDWR | os.O_CREATE | os.O_TRUNC, 0o644)
    if err != nil {
        os.close(fd)
        set_status_message("Can't save! I/O error: %s", err)
        return 
    }
    defer os.close(fd)
    _, err = os.write(fd, buf)
    if err != nil do set_status_message("Can't save! I/O error: %s", err)
    else { 
        set_status_message("%d bytes written to disk", len)
        E.dirty = 0
        select_syntax_highlight()
    }
}

read_key :: proc() -> Key {
    buffer: [1]byte
    for {
        nread, err := os.read(os.stdin, buffer[:])
        if err != nil do die("read byte error")
        if nread == 1 do break
    }
    c := buffer[0]
    if c == '\x1b' {
        seq: [3]byte
        if nread, err := os.read(os.stdin, seq[0:1]); err != nil || nread != 1 do return '\x1b'
        if nread, err := os.read(os.stdin, seq[1:2]); err != nil || nread != 1 do return '\x1b'
        if seq[0] == '[' {
            if seq[1] >= '0' && seq[1] <= '9' {
                if nread, err := os.read(os.stdin, seq[2:3]); err != nil || nread != 1 do return '\x1b'
                if seq[2] == '~' {
                    switch seq[1] {
                    case '1': return .Home_Key
                    case '3': return .Del_Key
                    case '4': return .End_Key
                    case '5': return .Page_Up
                    case '6': return .Page_Down
                    case '7': return .Home_Key
                    case '8': return .End_Key
                    }
                }
            } else {
                switch seq[1] {
                case 'A': return .Arrow_Up
                case 'B': return .Arrow_Down
                case 'C': return .Arrow_Right
                case 'D': return .Arrow_Left
                case 'H': return .Home_Key
                case 'F': return .End_Key
                }
            }
        } else if (seq[0] == 'O') {
            switch seq[1] {
                case 'H': return .Home_Key
                case 'F': return .End_Key
            }
        }
        return '\x1b'
    } else {
        if c == 127 do return .Backspace
        return c
    }
}

/*** input ***/

move_cursor :: proc(key: Key) {
    switch key {
    case .Arrow_Left: 
        if E.cx != 0 do E.cx -= 1
        else if E.cy > 0 {  
            E.cy -= 1
            E.cx = E.row[E.cy].size
        }
    case .Arrow_Right: 
        if E.cy < E.num_rows {
            if E.cx < E.row[E.cy].size do E.cx += 1
            else if E.cx == E.row[E.cy].size {
                if E.cy < E.num_rows - 1 do E.cy, E.cx = E.cy + 1, 0
            }
        }
    case .Arrow_Up: if E.cy != 0 do E.cy -= 1
    case .Arrow_Down: if E.cy < E.num_rows do E.cy += 1
    }
    rowlen := 0
    if E.cy < E.num_rows do rowlen = E.row[E.cy].size
    if E.cx > rowlen do E.cx = rowlen
}

quit_times := Quit_Times

handle_keypress :: proc() {
    c := read_key() 
    switch v in c {
    case Arrow:
        switch v {
        case .Page_Up, .Page_Down: 
            if c == .Page_Up do E.cy = E.rowoff
            else if c == .Page_Down {
                E.cy = E.rowoff + E.screen_row - 1
                if E.cy > E.num_rows do E.cy = E.num_rows
            }
            for _ in 0..<E.screen_row {
                move_cursor(c == .Page_Up ? .Arrow_Up : .Arrow_Down)
            }
        case .Home_Key: E.cx = 0
        case .End_Key: if E.cy < E.num_rows do E.cx = E.row[E.cy].size
        case .Arrow_Up, .Arrow_Down, .Arrow_Left, .Arrow_Right: move_cursor(c)
        case .Backspace, .Del_Key: 
            if c == .Del_Key do move_cursor(.Arrow_Right)
            del_char()
        }
    case byte: 
        switch v {
        case '\r': insert_newline()
        case cntl_key('h'): del_char()
        case cntl_key('s'): editor_save()
        case cntl_key('l'), '\x1b': 
        case cntl_key('f'): editor_find()
        case cntl_key('q'): {
            if E.dirty != 0 && quit_times > 0 {
                set_status_message("WARNING!!! File has unsaved changes. Press Ctrl-Q %d more times to quit.", quit_times)
                quit_times -= 1
                return 
            }
            exit(0)
        }
        case: insert_char(v)
        }
    } 
    quit_times = Quit_Times
}

editor_prompt :: proc(prompt: string, callback: proc([]byte, Key) = nil) -> string {
    buf: [dynamic]byte
    defer delete(buf)
    for {
        set_status_message(prompt, string(buf[:]))
        refresh_screen()

        c := read_key()
        switch v in c {
        case Arrow: 
            if v == .Del_Key || v == .Backspace {
                if len(buf) > 0 do pop(&buf)
            }
        case byte: 
            if v == cntl_key('h') {
                if len(buf) > 0 do pop(&buf)
            }
            else if v == '\x1b' {
                set_status_message("")
                if callback != nil do callback(buf[:], c)
                return ""
            } else if v == '\r' {
                if len(buf) != 0 {
                    set_status_message("")
                    if callback != nil do callback(buf[:], c)
                    return strings.clone_from_bytes(buf[:])
                }
            } else if !is_cntl(v) && v < 128 {
                append(&buf, v)
            }
        } 
        if callback != nil do callback(buf[:], c)
    }
}

/*** output ***/

clear_screen :: proc(buf: ^Buffer) {
    bytes.buffer_write_string(buf, "\x1b[2J")
    bytes.buffer_write_string(buf, "\x1b[H")
}

draw_rows :: proc(buf: ^Buffer) {
    for r in 0..<E.screen_row {
        filerow := r + E.rowoff
        if filerow >= E.num_rows {
            if E.num_rows == 0 && r == E.screen_row / 3 {
                wel := fmt.tprintf("Olio editor -- version %s", Olio_Version)
                if len(wel) > E.screen_col do wel = strings.cut(wel, 0, E.screen_col)
                padding := (E.screen_col - len(wel)) / 2
                if padding > 0 {
                    bytes.buffer_write_string(buf, "~")
                    padding -= 1
                }
                for _ in 0..<padding do bytes.buffer_write_string(buf, " ") 
                bytes.buffer_write_string(buf, wel)
            } else {
                bytes.buffer_write_string(buf, "~")
            }
        } else {
            if E.coloff < E.row[filerow].rsize {
                len := E.row[filerow].rsize - E.coloff
                if len < 0 do len = 0
                if len > E.screen_col do len = E.screen_col
                c := E.row[filerow].render[E.coloff:]
                hl := E.row[filerow].hl[E.coloff:]
                current_color := -1
                for j in 0..<len {
                    if is_cntl(c[j]) {
                        sym := c[j] <= 26 ? '@' + c[j] : '?'
                        bytes.buffer_write_string(buf, "\x1b[7m")
                        bytes.buffer_write_byte(buf, sym)
                        bytes.buffer_write_string(buf, "\x1b[m")
                        if current_color != -1 {
                            color_f := fmt.tprintf("\x1b[%dm", current_color)
                            bytes.buffer_write_string(buf, color_f)
                        }
                    } else if hl[j] == .Hl_Normal {
                        if current_color != -1 {
                            bytes.buffer_write_string(buf, "\x1b[39m")
                            current_color = -1 
                        }
                        bytes.buffer_write_byte(buf, c[j])
                    } else {
                        color := syntax_to_color(hl[j])
                        if color != current_color {
                            current_color = color
                            color_f := fmt.tprintf("\x1b[%dm", color)
                            bytes.buffer_write_string(buf, color_f)
                        }
                        bytes.buffer_write_byte(buf, c[j])
                    }
                }
            }
            bytes.buffer_write_string(buf, "\x1b[39m")
        }
        bytes.buffer_write_string(buf, "\x1b[K")    // erase in line
        bytes.buffer_write_string(buf, "\r\n") 
    }
}

refresh_screen :: proc() {
    editor_scroll()
    buffer: Buffer
    bytes.buffer_write_string(&buffer, "\x1b[?25l")
    bytes.buffer_write_string(&buffer, "\x1b[H")
    draw_rows(&buffer)
    draw_status_bar(&buffer)
    draw_status_message_bar(&buffer)
    pos := fmt.tprintf("\x1b[%d;%dH", E.cy - E.rowoff + 1, E.rx - E.coloff + 1)
    bytes.buffer_write_string(&buffer, pos)
    bytes.buffer_write_string(&buffer, "\x1b[?25h")
    os.write_string(os.stdout, bytes.buffer_to_string(&buffer))
}

editor_scroll :: proc() {
    E.rx = 0
    if E.cy < E.num_rows do E.rx = row_cx_to_rx(&E.row[E.cy], E.cx)
    if E.cy < E.rowoff do E.rowoff = E.cy
    if E.cy >= E.rowoff + E.screen_row do E.rowoff = E.cy - E.screen_row + 1
    if E.rx < E.coloff do E.coloff = E.rx
    if E.rx >= E.coloff + E.screen_col do E.coloff = E.rx - E.screen_col + 1
}

editor_update_row :: proc(row: ^E_Row) {
    tabs := 0
    for j in 0..<row.size do if row.chars[j] == '\t' do tabs += 1

    resize(&row.render, row.size + tabs*(Tab_Stop - 1))

    idx := 0
    for j in 0..<row.size {
        if row.chars[j] == '\t' {
            row.render[idx] = ' '
            idx += 1
            for idx % Tab_Stop != 0 {
                row.render[idx] = ' '
                idx += 1
            }
        } else {
            row.render[idx] = row.chars[j]
            idx += 1
        }
    }
    row.rsize = idx
    update_syntax(row)
}

draw_status_bar :: proc(buf: ^Buffer) {
    bytes.buffer_write_string(buf, "\x1b[7m")
    status := fmt.tprintf("%.20s - %d lines %s", E.filename != "" ? E.filename : "[No Name]", E.num_rows, E.dirty != 0 ? "(modified)" : "")
    rstatus := fmt.tprintf("%s | %d/%d", E.syntax != nil ? E.syntax.filetype : "no ft", E.cy + 1, E.num_rows)
    if len(status) > E.screen_col do status = status[:E.screen_col]
    bytes.buffer_write_string(buf, status)
    for i in len(status)..<E.screen_col { 
        if E.screen_col - i == len(rstatus) {
            bytes.buffer_write_string(buf, rstatus)
            break
        } else do bytes.buffer_write_string(buf, " ")
    }
    bytes.buffer_write_string(buf, "\x1b[m")
    bytes.buffer_write_string(buf, "\r\n")
}

set_status_message :: proc(format: string, args: ..any) {
    E.status_msg = fmt.tprintf(format, ..args)
    E.status_msg_time = time.now()
}

draw_status_message_bar :: proc(buf: ^Buffer) {
    bytes.buffer_write_string(buf, "\x1b[K")
    len := len(E.status_msg)
    if len > E.screen_col do len = E.screen_col
    if len > 0 && time.since(E.status_msg_time) < 5 * time.Second do bytes.buffer_write_string(buf, E.status_msg)
}

/*** row operations ***/

row_cx_to_rx :: proc(row: ^E_Row, cx: int) -> int {
    rx := 0
    for j := 0; j < cx; j += 1 {
        if row.chars[j] == '\t' do rx += Tab_Stop - 1 - rx % Tab_Stop
        rx += 1
    }
    return rx
}

row_rx_to_cx :: proc(row: ^E_Row, rx: int) -> int {
    cur_rx := 0
    for i in 0..<row.size {
        if row.chars[i] == '\t' do cur_rx += Tab_Stop - 1 - cur_rx % Tab_Stop
        cur_rx += 1
        if cur_rx > rx do return i 
    }
    return row.size
}

free_row :: proc(row: ^E_Row) {
    delete(row.render)
    delete(row.chars)
    delete(row.hl)
} 

row_append_string :: proc(row: ^E_Row, s: []byte) {
    append(&row.chars, ..s) 
    row.size += len(s)
    editor_update_row(row)
    E.dirty += 1
}

row_insert_char :: proc(row: ^E_Row, at_: int, c: byte) {
    at := at_ < 0 || at_ > row.size ? row.size : at_
    inject_at(&row.chars, at, c)
    row.size = len(row.chars)
    editor_update_row(row)
    E.dirty += 1
}

row_del_char :: proc(row: ^E_Row, at: int) {
    if at < 0 || at >= row.size do return 
    ordered_remove(&row.chars, at)
    row.size = len(row.chars)
    editor_update_row(row)
    E.dirty += 1
}

del_row :: proc(at: int) {
    if at < 0 || at >= E.num_rows do return
    free_row(&E.row[at])
    ordered_remove(&E.row, at)
    for j in at..<E.num_rows-1 do E.row[j].idx -= 1
    E.num_rows = len(E.row)
    E.dirty += 1
}

insert_row :: proc(at: int, s: []byte) {
    if at < 0 || at > E.num_rows do return 
    for j in at+1..=E.num_rows do E.row[j].idx += 1
    new_row := E_Row {at, len(s), 0, slice.clone_to_dynamic(s), {}, {}, false}
    inject_at(&E.row, at, new_row)
    editor_update_row(&E.row[at])
    E.num_rows += 1
    E.dirty += 1
}

/*** editor operations ***/

insert_char :: proc(c: byte) {
    if E.cy == E.num_rows do insert_row(E.num_rows, []byte{})
    row_insert_char(&E.row[E.cy], E.cx, c)
    E.cx += 1
}

insert_newline :: proc() {
    if E.cx == 0 do insert_row(E.cy, []byte{})
    else {
        row := &E.row[E.cy]
        insert_row(E.cy + 1, row.chars[E.cx:])
        row = &E.row[E.cy]
        resize(&row.chars, E.cx)
        row.size = E.cx
        editor_update_row(row)
    }
    E.cy += 1
    E.cx = 0
}

del_char :: proc() {
    if E.cy == E.num_rows do return
    if E.cx == 0 && E.cy == 0 do return 
    row := &E.row[E.cy]
    if E.cx > 0 {
        row_del_char(row, E.cx - 1)
        E.cx -= 1
    } else {
        E.cx = E.row[E.cy - 1].size
        row_append_string(&E.row[E.cy - 1], row.chars[:])
        del_row(E.cy)
        E.cy -= 1
    }
}

/*** terminal ***/

die :: proc(msg: string) {
    disable_raw_mode()
    fmt.println(msg)
    os.exit(1)
}

exit :: proc(code: int) {
    disable_raw_mode()
    os.exit(code)
}

enable_raw_mode :: proc() {
    if posix.tcgetattr(posix.STDIN_FILENO, &E.origin_termios) != posix.result.OK do die("tcgetattr error")
    raw := E.origin_termios
    raw.c_iflag -= {
        posix.CInput_Flag_Bits.BRKINT,
        posix.CInput_Flag_Bits.ICRNL,
        posix.CInput_Flag_Bits.INPCK,
        posix.CInput_Flag_Bits.ISTRIP,
        posix.CInput_Flag_Bits.IXON,
    }
    raw.c_oflag -= {
        posix.COutput_Flag_Bits.OPOST,
    }
    raw.c_cflag -= {
        posix.CControl_Flag_Bits.CS8,
    }
    raw.c_lflag -= {
        posix.CLocal_Flag_Bits.ECHO,
        posix.CLocal_Flag_Bits.ICANON,
        posix.CLocal_Flag_Bits.IEXTEN,
        posix.CLocal_Flag_Bits.ISIG,
    }
    raw.c_cc[posix.Control_Char.VMIN] = 0
    raw.c_cc[posix.Control_Char.VTIME] = 1
    if posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &raw) != posix.result.OK do die("tcsetattr error")
}

disable_raw_mode :: proc() {
    if posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &E.origin_termios) != posix.result.OK do die("tcsetattr error")
}

get_cursor_pos :: proc(conf: ^Config) -> Result {
    buf: [dynamic]byte
    if _, err := os.write_string(os.stdout, "\x1b[6n"); err != nil do return .Err // report active position
    fmt.printf("\r\n")
    for i in 0..<size_of(buf) - 1 {
        b: [1]byte
        if _, err := os.read(os.stdin, b[:]); err != nil do break
        if b[0] == 'R' do break
        append(&buf, b[0])
    }
    if buf[0] != '\x1b' || buf[1] != '[' do return .Err // parse the response which is a escape sequence
    res := buf[2:]
    if ss := strings.split(string(res), ";"); len(ss) == 2 {
        if res, ok := strconv.parse_int(ss[0]); ok do conf.screen_row = res
        if res, ok := strconv.parse_int(ss[1]); ok do conf.screen_col = res
    } 
    return .Ok
}

get_window_size :: proc(conf: ^Config) -> Result {
    if _, err := os.write_string(os.stdout, "\x1b[999C\x1b[999B"); err != nil do return .Err
    return get_cursor_pos(conf)
}

/*** find ***/

editor_find :: proc() {
    saved_cx, saved_cy := E.cx, E.cy
    saved_coloff, saved_rowoff := E.coloff, E.rowoff
    query := editor_prompt("Search: %s (Use ESC/Arrow/Enter)", find_callback)
    defer delete(query)
    if query == "" {    // restore values when escape
        E.cx, E.cy = saved_cx, saved_cy
        E.coloff, E.rowoff = saved_coloff, saved_rowoff
    }
}

last_match := -1
direction := 1
saved_hl_line := 0
saved_hl := [dynamic]Highlight {}

find_callback :: proc(query: []byte, key: Key) {
    if len(saved_hl) != 0 {
        copy(E.row[saved_hl_line].hl[:], saved_hl[:])
        clear(&saved_hl)
    }   
#partial switch v in key {
    case byte:
        if v == '\r' || v == '\x1b' {
            last_match = -1
            direction = 1
            return
        }
    case Arrow:
        if v == .Arrow_Right || v == .Arrow_Down do direction = 1
        else if v == .Arrow_Left || v == .Arrow_Up do direction = -1
    }

    #partial switch v in key {
    case byte:
        if v == '\r' || v == '\x1b' {
            last_match = -1
            direction = 1
            return
        }
    case Arrow:
        if v == .Arrow_Right || v == .Arrow_Down do direction = 1
        else if v == .Arrow_Left || v == .Arrow_Up do direction = -1
    }

    #partial switch v in key {
    case Arrow:
    case:
        last_match = -1
        direction = 1
    }

    current := last_match
    for i in 0..<E.num_rows {
        current += direction
        if current == -1 do current = E.num_rows - 1
        else if current == E.num_rows do current = 0
        row := &E.row[current]
        idx := strings.index(string(row.render[:]), string(query))
        if idx >= 0 {
            last_match = current
            E.cy = current
            E.cx = row_rx_to_cx(row, idx)
            E.rowoff = E.num_rows
            saved_hl_line = current
            resize(&saved_hl, row.rsize)
            copy(saved_hl[:], row.hl[:])
            for i in 0..<len(query) {
                row.hl[idx + i] = .Hl_Match
            }
            break
        }
    }
}

/*** syntax highlighting ***/

update_syntax :: proc(row: ^E_Row) {
    resize(&row.hl, row.rsize)
    if E.syntax == nil do return 
    keywords := E.syntax.keywords
    scs := E.syntax.singleline_comment_start
    mcs := E.syntax.multiline_comment_start
    mce := E.syntax.multiline_comment_end
    prev_sep := true
    in_string: byte = 0     // ' or " 
    in_comment := row.idx > 0 && E.row[row.idx - 1].hl_open_comment
    for i := 0; i < row.rsize; i += 1 {
        c := row.render[i]
        prev_hl := (i > 0) ? row.hl[i - 1] : .Hl_Normal
    
        if len(scs) != 0 && in_string == 0 && !in_comment {
            if strings.has_prefix(string(row.render[i:]), scs) {
                for j in i..<row.rsize {
                    row.hl[j] = .Hl_Comment
                }
                break
            }
        }

        if len(mcs) != 0 && len(mce) != 0 && in_string == 0 {
            if in_comment {
                row.hl[i] = .Hl_Mlcomment
                if strings.has_prefix(string(row.render[i:]), mce) {
                    for j in i..<len(mce) do row.hl[j] = .Hl_Mlcomment
                    i += len(mce) - 1
                    in_comment, prev_sep = false, true
                    continue
                } else do continue
            } else if strings.has_prefix(string(row.render[i:]), mcs) {
                for j in i..<len(mcs) do row.hl[j] = .Hl_Mlcomment
                i += len(mcs) - 1
                in_comment = true
                continue
            }
        }

        if .Hl_Highlight_String in E.syntax.flags {
            if in_string != 0 {
                row.hl[i] = .Hl_String
                if c == '\\' && i + 1 < row.rsize {
                    if .Hl_Highlight_Escape in E.syntax.flags {
                        row.hl[i] = .Hl_Escape
                        row.hl[i+1] = .Hl_Escape
                    } else do row.hl[i+1] = .Hl_String
                    i += 1
                    continue
                }
                if c == in_string do in_string = 0
                prev_sep = true
                continue
            } else {
                if c == '"' || c == '\'' {
                    in_string = c
                    row.hl[i] = .Hl_String
                    continue
                }
            }
        }
        if .Hl_Highlight_Numbers in E.syntax.flags {
            if (is_digit(c) && (prev_sep || prev_hl == .Hl_Number)) || (c == '.' && prev_hl == .Hl_Number){
                row.hl[i] = .Hl_Number
                prev_sep = false
                continue
            } else do row.hl[i] = .Hl_Normal
        }

        if prev_sep {
            found_kw := false
            for keyword in keywords {
                idx := strings.last_index(keyword, "|")
                kw := idx >= 0 ? keyword[:idx] : keyword
                kw_len := len(kw)
                if strings.has_prefix(string(row.render[i:]), kw) {
                    next_char_idx := i + kw_len
                    is_end_or_sep := next_char_idx >= row.rsize || is_separator(row.render[next_char_idx])
                    if is_end_or_sep { 
                        for j in i..<i + kw_len do row.hl[j] = idx >= 0 ? .Hl_Keyword2 : .Hl_Keyword1
                        i += kw_len - 1
                        found_kw = true
                        break
                    }
                }
            }
            if found_kw {
                prev_sep = false
                continue
            }
        }
        prev_sep = is_separator(c)
    }

    changed := row.hl_open_comment != in_comment
    row.hl_open_comment = in_comment
    if changed && row.idx + 1 < E.num_rows do update_syntax(&E.row[row.idx + 1])
}

syntax_to_color :: proc(hl: Highlight) -> int {
    #partial switch hl {
    case .Hl_Comment, .Hl_Mlcomment: return 32
    case .Hl_Keyword1: return 33
    case .Hl_Keyword2: return 34
    case .Hl_Number: return 31
    case .Hl_Match: return 36
    case .Hl_String: return 35
    case .Hl_Escape: return 34
    case: return 37
    }
}

is_separator :: proc(c: byte) -> bool {
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f' do return true
    switch c {
    case '\x00', ',', '.', '(', ')', '+', '-', '/', '*', '=', '~', '%', '<', '>', '[', ']', ';': return true
    case: return false
    }
}

select_syntax_highlight :: proc() {
    E.syntax = nil
    if E.filename == "" do return 
    for &e in Hl_Db {
        for ft in e.filematch {
            if strings.has_suffix(E.filename, ft) {
                E.syntax = &e
                for r in 0..<E.num_rows do update_syntax(&E.row[r])
                return
            }
        }
    }
}

/*** util ***/

is_cntl :: proc(b: byte) -> bool {
    return b <= 31 || b == 127
}

cntl_key :: proc(b: byte) -> byte {
    return b & 0x1f
}

is_digit :: proc(b: byte) -> bool {
    return b >= '0' && b <= '9'
}

/*** init ***/

init_editor :: proc() {
    E.cx, E.cy, E.num_rows, E.rowoff, E.coloff, E.rx = 0, 0, 0, 0, 0, 0
    E.dirty, E.syntax = 0, nil
    E.filename, E.status_msg, E.status_msg_time = "", "", time.now()
    if get_window_size(&E) == .Err do die("get window size error")
    E.screen_row -= 2
}

main :: proc() {
    defer disable_raw_mode()
    enable_raw_mode()    
    init_editor()
    if len(os.args) >= 2 {
        editor_open(os.args[1])
    }
    set_status_message("HELP: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find")
    for {
        refresh_screen()
        handle_keypress()
    }
}


