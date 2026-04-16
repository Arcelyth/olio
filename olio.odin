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
    size: int,
    rsize: int,
    chars: [dynamic]byte,
    render: [dynamic]byte
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
    status_msg_time: time.Time
}

Buffer :: bytes.Buffer  // append buffer

E: Config

Result :: enum {
    Err,
    Ok,
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

Olio_Version := "0.0.1"
Tab_Stop := 8
Quit_Times := 3

main :: proc() {
    defer disable_raw_mode()
    enable_raw_mode()    
    init_editor()
    if len(os.args) >= 2 {
        editor_open(os.args[1])
    }
    set_status_message("HELP: Ctrl-S = save | Ctrl-Q = quit")
    for {
        refresh_screen()
        handle_keypress()
    }
}

init_editor :: proc() {
    E.cx, E.cy, E.num_rows, E.rowoff, E.coloff, E.rx = 0, 0, 0, 0, 0, 0
    E.dirty = 0
    E.filename, E.status_msg, E.status_msg_time = "", "", time.now()
    if get_window_size(&E) == .Err do die("get window size error")
    E.screen_row -= 2
}

append_row :: proc(line: []byte) {
    e := E_Row { len(line), 0, slice.clone_to_dynamic(line), {}}
    append(&E.row, e)
    editor_update_row(&E.row[E.num_rows])
    E.num_rows = len(E.row)
    E.dirty += 1
}

/*** file IO ***/
editor_open :: proc (path: string) {
    E.filename = path
    content, ok := os.read_entire_file(path)
    defer delete(content)
    if !ok do die("Failed to read file")

    start := 0 
    for i := 0; i < len(content); i += 1 {
        if content[i] == '\n' {
            line := content[start:i]
            if len(line) > 0 && content[len(line)-1] == '\r' do line = content[:len(line)-1]
            append_row(line)
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
    if E.filename == "" do return
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
    }
}

die :: proc(msg: string) {
    disable_raw_mode()
    fmt.println(msg)
    os.exit(1)
}

exit :: proc(code: int) {
    disable_raw_mode()
    os.exit(code)
}

is_cntl :: proc(b: byte) -> bool {
    return b <= 31 || b == 127
}

cntl_key :: proc(b: byte) -> byte {
    return b & 0x1f
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
        case '\r': 
        case cntl_key('h'): del_char()
        case cntl_key('s'): editor_save()
        case cntl_key('l'), '\x1b': 
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
                bytes.buffer_write(buf, E.row[filerow].render[E.coloff:E.coloff+len]) 
            }
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
        if res, err := strconv.parse_int(ss[0]); err != false do conf.screen_row = res
        if res, err := strconv.parse_int(ss[1]); err != false do conf.screen_col = res
    } 

    return .Ok
}

get_window_size :: proc(conf: ^Config) -> Result {
    if _, err := os.write_string(os.stdout, "\x1b[999C\x1b[999B"); err != nil do return .Err
    return get_cursor_pos(conf)
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

    if row.render != nil do clear(&row.render)
    row.render = make([dynamic]byte, row.size + tabs*(Tab_Stop - 1))

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
}

row_cx_to_rx :: proc(row: ^E_Row, cx: int) -> int {
    rx := 0
    for j := 0; j < cx; j += 1 {
        if row.chars[j] == '\t' do rx += Tab_Stop - 1 - rx % Tab_Stop
        rx += 1
    }
    return rx
}

draw_status_bar :: proc(buf: ^Buffer) {
    bytes.buffer_write_string(buf, "\x1b[7m")
    status := fmt.tprintf("%.20s - %d lines %s", E.filename != "" ? E.filename : "[No Name]", E.num_rows, E.dirty != 0 ? "(modified)" : "")
    rstatus := fmt.tprintf("%d/%d", E.cy + 1, E.num_rows)
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

free_row :: proc(row: ^E_Row) {
    delete(row.render)
    delete(row.chars)
} 

del_row :: proc(at: int) {
    if at < 0 || at > E.num_rows do return
    free_row(&E.row[at])
    ordered_remove(&E.row, at)
    E.num_rows = len(E.row)
    E.dirty += 1
}

row_append_string :: proc(row: ^E_Row, s: []byte) {
    append(&row.chars, ..s) 
    row.size += len(s)
    editor_update_row(row)
    E.dirty += 1
}

row_insert_char :: proc(row: ^E_Row, at_:int, c: byte) {
    at := at_ < 0 || at_ > row.size ? row.size : at_
    new_chars := make([dynamic]byte, row.size + 1)
    if at > 0 do mem.copy(&new_chars[0], &row.chars[0], at)
    if at < row.size do mem.copy(&new_chars[at+1], &row.chars[at], row.size - at)
    if row.chars != nil do delete(row.chars)
    new_chars[at] = c
    row.size += 1
    row.chars = new_chars
    editor_update_row(row)
    E.dirty += 1
}

/*** editor operations ***/

insert_char :: proc(c: byte) {
    if E.cy == E.num_rows do append_row([]byte{})
    row_insert_char(&E.row[E.cy], E.cx, c)
    E.cx += 1
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

row_del_char :: proc(row: ^E_Row, at: int) {
    if at < 0 || at > row.size do return 
    ordered_remove(&row.chars, at)
    row.size = len(row.chars)
    editor_update_row(row)
    E.dirty += 1
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


